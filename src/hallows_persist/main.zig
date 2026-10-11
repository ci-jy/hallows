//! hallows-persist keeps a shell alive on a remote host between ssh
//! connections. It is the remote half of `ghostty +ssh --persist` (the
//! `ssh-persist` shell integration feature), which installs it as
//! `~/.local/share/hallows/hallows-persist` and runs `attach` as the remote
//! command of every connection attempt.
//!
//! Unlike tmux, it isn't a terminal of its own. While a client is
//! attached, everything the shell writes reaches the real terminal
//! unchanged, and everything the terminal sends (keys, replies to queries)
//! reaches the shell unchanged, so programs see Ghostty itself. Each
//! session has a daemon that owns the shell's pty and feeds a copy of its
//! output to libghostty-vt. When a client attaches, the daemon brings it up
//! to date with a snapshot of that terminal state.
//!
//! The snapshot approach and much of `snapshot` come from zmx by Eric Bower
//! (https://github.com/neurosnap/zmx, MIT license).
//!
//! Usage:
//!
//!   hallows-persist attach TAG [--reconnect]
//!   hallows-persist cwd TAG
//!   hallows-persist serve NAME ROWS COLS
//!
//! `attach` connects the terminal identified by TAG to a session. TAG is
//! random per `+ssh` invocation and stays the same across its reconnects.
//! A daemon that has had TAG attached before is chosen first, so a
//! reconnect lands on the same session. Otherwise the most recently
//! detached session is reattached, and otherwise a new session is started.
//! If every session is attached somewhere, possibly by a terminal that's
//! gone without the host noticing yet (such as a computer that lost
//! power), the user can choose one to take over instead. `--reconnect`
//! says the terminal still shows the session from before the connection
//! dropped, so only the screen needs redrawing, not the scrollback.
//!
//! `cwd` prints the working directory of the program in the foreground of
//! the session TAG is attached to (Linux only). Hallows' file tree uses it
//! to show the files of a remote terminal.
//!
//! `serve` runs a session daemon. `attach` starts it; it isn't meant to be
//! run by hand.
const std = @import("std");
const builtin = @import("builtin");
const vt = @import("ghostty-vt");

const c = std.c;
const posix = std.posix;
const Allocator = std.mem.Allocator;

/// The highest session number. Sessions are named 1, 2, 3, ... and are
/// found by trying their sockets, so this bounds the search.
const max_sessions = 64;

/// The most a daemon buffers for a client that isn't reading. A client
/// that falls further behind is disconnected; it can attach again.
const max_client_buffer = 32 * 1024 * 1024;

/// Scrollback kept by a session's terminal, for clients that attach to it
/// from a new terminal.
const max_scrollback_bytes = 16 * 1024 * 1024;

/// The longest session label (see `Info`) a daemon sends.
const max_label = 120;

extern "c" fn forkpty(
    amaster: *c_int,
    name: ?[*]u8,
    termp: ?*const anyopaque,
    winp: ?*const Winsize,
) c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn tcgetpgrp(fd: c_int) c.pid_t;

const Winsize = extern struct {
    rows: u16,
    cols: u16,
    xpixel: u16 = 0,
    ypixel: u16 = 0,
};

/// Messages between clients and a daemon are a one-byte tag and a
/// little-endian u32 payload length, followed by the payload.
const Tag = enum(u8) {
    /// Client to daemon: attach. Payload: `Hello`, then the client's tag.
    hello = 0,
    /// Client to daemon: bytes for the shell.
    input = 1,
    /// Client to daemon: the terminal was resized. Payload: `Winsize`.
    resize = 2,
    /// Daemon to client: bytes for the terminal.
    output = 3,
    /// Daemon to client: the shell exited. Payload: its exit status (u8).
    exit = 4,
    /// Client to daemon: describe the session. Payload: the client's tag.
    query = 5,
    /// Daemon to client: reply to `query`. Payload: `Info`, then a label.
    info = 6,
    /// Daemon to client: another terminal took the session over.
    detach = 7,
    /// Client to daemon: where is the session? Payload: the client's tag.
    cwd = 8,
    /// Daemon to client: reply to `cwd`. Payload: `Where`, then the
    /// working directory of the program in the foreground of the session.
    where = 9,
    _,
};

const header_len = 5;

const Hello = extern struct {
    /// Bit 0: the terminal still shows this session (`--reconnect`).
    /// Bit 1: detach every other client (taking the session over).
    flags: u8,
    size: Winsize align(1),
};

const Info = extern struct {
    /// Attached clients.
    clients: u32 align(1),
    /// When the last client detached, in Unix seconds.
    detached_at: i64 align(1),
    /// 1 if the tag in the query has been attached to this session.
    knows_tag: u8,
    /// When the session last had output or input, in Unix seconds.
    active_at: i64 align(1),

    // Followed by a label for the session, to tell sessions apart: its
    // window title, or the shell's working directory.
};

const Where = extern struct {
    /// 2 if a client with the tag in the query is attached to this
    /// session, 1 if it has been attached before, 0 otherwise.
    tag: u8,
};

/// A session's `Info` and label, as `querySession` returns them.
const SessionInfo = struct {
    info: Info,
    label_buf: [max_label]u8 = undefined,
    label_len: usize = 0,

    fn label(self: *const SessionInfo) []const u8 {
        return self.label_buf[0..self.label_len];
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = init.minimal.args.iterate();
    defer args.deinit();
    const self_path = args.next() orelse "hallows-persist";

    const cmd = args.next() orelse return usage();
    if (std.mem.eql(u8, cmd, "attach")) {
        const tag = args.next() orelse return usage();
        if (!validTag(tag)) return usage();
        var reconnect = false;
        if (args.next()) |flag| {
            if (!std.mem.eql(u8, flag, "--reconnect")) return usage();
            reconnect = true;
        }
        std.process.exit(try attach(gpa, init.environ_map, self_path, tag, reconnect));
    } else if (std.mem.eql(u8, cmd, "cwd")) {
        const tag = args.next() orelse return usage();
        if (!validTag(tag)) return usage();
        std.process.exit(try printCwd(gpa, init.environ_map, tag));
    } else if (std.mem.eql(u8, cmd, "serve")) {
        const name = args.next() orelse return usage();
        const rows = std.fmt.parseInt(u16, args.next() orelse return usage(), 10) catch return usage();
        const cols = std.fmt.parseInt(u16, args.next() orelse return usage(), 10) catch return usage();
        try serve(gpa, init.io, init.environ_map, name, .{ .rows = rows, .cols = cols });
    } else return usage();
}

fn usage() void {
    std.debug.print("usage: hallows-persist attach TAG [--reconnect] | cwd TAG\n", .{});
    std.process.exit(2);
}

fn validTag(tag: []const u8) bool {
    if (tag.len == 0 or tag.len > 64) return false;
    for (tag) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    return true;
}

//---------------------------------------------------------------------
// Sessions

/// Where session sockets live: `$XDG_STATE_HOME/hallows/sessions`, or
/// `~/.local/state/hallows/sessions`. In the home directory rather than
/// /tmp, so other users can't get in the way.
fn stateDir(alloc: Allocator, env: *const std.process.Environ.Map) ![:0]u8 {
    if (env.get("XDG_STATE_HOME")) |state| if (state.len > 0 and state[0] == '/') {
        return std.fmt.allocPrintSentinel(alloc, "{s}/hallows/sessions", .{state}, 0);
    };
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fmt.allocPrintSentinel(alloc, "{s}/.local/state/hallows/sessions", .{home}, 0);
}

fn makeDirs(path: [:0]const u8) void {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i < path.len and path[i] != '/') continue;
        buf[i] = 0;
        _ = c.mkdir(&buf, 0o700);
        if (i < path.len) buf[i] = '/';
    }
}

fn socketAddr(dir: []const u8, name: []const u8) !c.sockaddr.un {
    var addr: c.sockaddr.un = .{ .path = @splat(0) };
    const path = std.fmt.bufPrint(&addr.path, "{s}/{s}.sock", .{ dir, name }) catch
        return error.NameTooLong;
    if (path.len >= addr.path.len) return error.NameTooLong;
    return addr;
}

/// Connect to the session NAME, or return null if it isn't running.
fn connectSession(dir: []const u8, name: []const u8) !?c.fd_t {
    const addr = try socketAddr(dir, name);
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) != 0) {
        _ = c.close(fd);
        return null;
    }
    setCloexec(fd);
    return fd;
}

/// Ask the session NAME about itself.
fn querySession(dir: []const u8, name: []const u8, tag: []const u8) ?SessionInfo {
    const fd = (connectSession(dir, name) catch return null) orelse return null;
    defer _ = c.close(fd);
    sendFrame(fd, .query, tag) catch return null;

    var header: [header_len]u8 = undefined;
    readFull(fd, &header) catch return null;
    const len = std.mem.readInt(u32, header[1..5], .little);
    if (@as(Tag, @enumFromInt(header[0])) != .info or
        len < @sizeOf(Info) or len > @sizeOf(Info) + max_label) return null;

    var buf: [@sizeOf(Info) + max_label]u8 = undefined;
    readFull(fd, buf[0..len]) catch return null;
    var result: SessionInfo = .{
        .info = std.mem.bytesToValue(Info, buf[0..@sizeOf(Info)]),
        .label_len = len - @sizeOf(Info),
    };
    @memcpy(result.label_buf[0..result.label_len], buf[@sizeOf(Info)..len]);
    return result;
}

/// Ask the session NAME where it is for the client TAG. Returns its
/// `Where` and writes the directory to `buf`, or returns null if the
/// session isn't running or doesn't answer (it may be an older daemon).
fn whereSession(dir: []const u8, name: []const u8, tag: []const u8, buf: []u8) ?struct { Where, []const u8 } {
    const fd = (connectSession(dir, name) catch return null) orelse return null;
    defer _ = c.close(fd);
    sendFrame(fd, .cwd, tag) catch return null;

    var pfd = [_]c.pollfd{.{ .fd = fd, .events = c.POLL.IN, .revents = 0 }};
    if (c.poll(&pfd, 1, 200) <= 0) return null;
    var header: [header_len]u8 = undefined;
    readFull(fd, &header) catch return null;
    const len = std.mem.readInt(u32, header[1..5], .little);
    if (@as(Tag, @enumFromInt(header[0])) != .where or
        len < @sizeOf(Where) or len > @sizeOf(Where) + buf.len) return null;

    var where: [@sizeOf(Where)]u8 = undefined;
    readFull(fd, &where) catch return null;
    const path = buf[0 .. len - @sizeOf(Where)];
    readFull(fd, path) catch return null;
    return .{ std.mem.bytesToValue(Where, &where), path };
}

/// `cwd`: print the working directory of the session TAG is attached to,
/// or, if it isn't attached anywhere, of the last session it was.
fn printCwd(alloc: Allocator, env: *const std.process.Environ.Map, tag: []const u8) !u8 {
    const dir = try stateDir(alloc, env);
    var best: [std.fs.max_path_bytes]u8 = undefined;
    var best_len: usize = 0;
    var best_tag: u8 = 0;
    for (1..max_sessions + 1) |n| {
        var name_buf: [8]u8 = undefined;
        const name = sessionName(&name_buf, n);
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const where: Where, const path = whereSession(dir, name, tag, &path_buf) orelse where: {
            // A daemon from before `cwd` existed doesn't answer, but it does
            // say whether it knows the tag, and its shell is in /proc.
            const session = querySession(dir, name, tag) orelse continue;
            if (session.info.knows_tag == 0) continue;
            const t: u8 = if (session.info.clients > 0) 2 else 1;
            if (t <= best_tag) continue;
            break :where .{ .{ .tag = t }, procCwd(dir, name, &path_buf) orelse continue };
        };
        if (where.tag <= best_tag or path.len == 0) continue;
        best_tag = where.tag;
        @memcpy(best[0..path.len], path);
        best_len = path.len;
        if (best_tag == 2) break;
    }
    if (best_len == 0) return 1;
    writeAll(posix.STDOUT_FILENO, best[0..best_len]) catch return 1;
    return 0;
}

/// The working directory of the program in the foreground of session
/// NAME, found from the outside: the daemon's pid from its socket, its
/// child the shell, and the shell's terminal's foreground process group.
fn procCwd(dir: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    return switch (builtin.os.tag) {
        .linux => linuxProcCwd(dir, name, buf),
        else => null,
    };
}

extern "c" fn getsockopt(fd: c_int, level: c_int, name: c_int, value: ?*anyopaque, len: *u32) c_int;

fn linuxProcCwd(dir: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    const daemon: c.pid_t = daemon: {
        const fd = (connectSession(dir, name) catch return null) orelse return null;
        defer _ = c.close(fd);
        const Ucred = extern struct { pid: c.pid_t, uid: u32, gid: u32 };
        var cred: Ucred = undefined;
        var len: u32 = @sizeOf(Ucred);
        const SOL_SOCKET = 1;
        const SO_PEERCRED = 17;
        if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0) return null;
        break :daemon cred.pid;
    };
    if (daemon <= 0) return null;

    var path_buf: [64]u8 = undefined;
    var file_buf: [1024]u8 = undefined;

    // The daemon's only child is the shell.
    const children = readProcFile(
        std.fmt.bufPrintZ(&path_buf, "/proc/{d}/task/{d}/children", .{ daemon, daemon }) catch return null,
        &file_buf,
    ) orelse return null;
    var it = std.mem.tokenizeScalar(u8, children, ' ');
    const shell = std.fmt.parseInt(c.pid_t, it.next() orelse return null, 10) catch return null;

    // Field 8 of stat is the terminal's foreground process group. The
    // command name before it is in parentheses and may contain anything.
    var foreground: c.pid_t = 0;
    if (readProcFile(
        std.fmt.bufPrintZ(&path_buf, "/proc/{d}/stat", .{shell}) catch return null,
        &file_buf,
    )) |stat| if (std.mem.lastIndexOfScalar(u8, stat, ')')) |paren| {
        var fields = std.mem.tokenizeScalar(u8, stat[paren + 1 ..], ' ');
        for (0..5) |_| _ = fields.next();
        foreground = std.fmt.parseInt(c.pid_t, fields.next() orelse "0", 10) catch 0;
    };

    for ([_]c.pid_t{ foreground, shell }) |pid| {
        if (pid <= 0) continue;
        const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/cwd", .{pid}) catch continue;
        const n = c.readlink(path, buf.ptr, buf.len);
        if (n > 0) return buf[0..@intCast(n)];
    }
    return null;
}

fn readProcFile(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    const fd = c.open(path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return null;
    defer _ = c.close(fd);
    const n = c.read(fd, buf.ptr, buf.len);
    return if (n > 0) buf[0..@intCast(n)] else null;
}

fn sessionName(buf: *[8]u8, n: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{n}) catch unreachable;
}

const Pick = struct {
    n: usize,
    /// TAG has been attached to the session before.
    known: bool = false,
    /// The session isn't running yet.
    new: bool = false,
};

/// A session that's attached somewhere else.
const Busy = struct { n: usize, session: SessionInfo };

/// Pick the session for TAG; see the file comment. When that's a new
/// session, `busy` gets every running session, all attached elsewhere.
fn pickSession(
    alloc: Allocator,
    dir: []const u8,
    tag: []const u8,
    busy: *std.ArrayList(Busy),
) Pick {
    var best: ?usize = null;
    var best_detached_at: i64 = std.math.minInt(i64);
    var free: ?usize = null;
    var buf: [8]u8 = undefined;
    for (1..max_sessions + 1) |n| {
        const session = querySession(dir, sessionName(&buf, n), tag) orelse {
            if (free == null) free = n;
            continue;
        };
        const info = session.info;
        if (info.knows_tag != 0) return .{ .n = n, .known = true };
        if (info.clients == 0 and info.detached_at > best_detached_at) {
            best = n;
            best_detached_at = info.detached_at;
        }
        if (info.clients > 0) busy.append(alloc, .{ .n = n, .session = session }) catch {};
    }
    if (best) |n| return .{ .n = n };
    return .{ .n = free orelse max_sessions + 1, .new = true };
}

/// Every session is attached somewhere. Some may be attached by terminals
/// that are gone, such as a computer that lost power, which the host only
/// notices once the connection times out. Let the user take one of them
/// over. Returns its number, or null for a new session.
fn chooseSession(alloc: Allocator, busy: []const Busy) ?usize {
    const stdin = posix.STDIN_FILENO;
    const stdout = posix.STDOUT_FILENO;
    if (c.isatty(stdin) == 0) return null;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;
    w.writeAll(
        \\Every session here is open in another terminal. If one of them is
        \\from a terminal that's gone, such as a computer that lost power, you
        \\can take it over.
        \\
        \\
    ) catch return null;
    const timestamp = now();
    for (busy) |entry| {
        var ago_buf: [32]u8 = undefined;
        w.print("  {d: >2}  active {s: <13} ", .{
            entry.n,
            formatAgo(&ago_buf, timestamp - entry.session.info.active_at),
        }) catch return null;
        writePrintable(w, entry.session.label());
        w.writeAll("\n") catch return null;
    }
    w.writeAll("\nSession to take over (Enter for a new one): ") catch return null;
    writeAll(stdout, out.written()) catch return null;

    var buf: [64]u8 = undefined;
    while (true) {
        const n = c.read(stdin, &buf, buf.len);
        if (n <= 0) return null;
        const answer = std.mem.trim(u8, buf[0..@intCast(n)], " \t\r\n");
        if (answer.len == 0) return null;
        const choice = std.fmt.parseInt(usize, answer, 10) catch 0;
        for (busy) |entry| if (entry.n == choice) return choice;
        writeAll(stdout, "Type one of the numbers above, or press Enter: ") catch return null;
    }
}

/// "just now", "5m ago", "3h ago", "2d ago".
fn formatAgo(buf: []u8, seconds: i64) []const u8 {
    if (seconds < 60) return "just now";
    if (seconds < 3600) return std.fmt.bufPrint(buf, "{d}m ago", .{@divTrunc(seconds, 60)}) catch "";
    if (seconds < 86400) return std.fmt.bufPrint(buf, "{d}h ago", .{@divTrunc(seconds, 3600)}) catch "";
    return std.fmt.bufPrint(buf, "{d}d ago", .{@divTrunc(seconds, 86400)}) catch "";
}

/// Write text that came from a program, without its control characters.
fn writePrintable(w: *std.Io.Writer, text: []const u8) void {
    for (text) |ch| if (ch >= 0x20 and ch != 0x7f) w.writeByte(ch) catch return;
}

//---------------------------------------------------------------------
// Client

fn attach(
    alloc: Allocator,
    env: *const std.process.Environ.Map,
    self_path: []const u8,
    tag: []const u8,
    reconnect: bool,
) !u8 {
    ignoreSigpipe();
    const dir = try stateDir(alloc, env);
    makeDirs(dir);

    const size = terminalSize(posix.STDIN_FILENO);
    var busy: std.ArrayList(Busy) = .empty;
    defer busy.deinit(alloc);
    var pick = pickSession(alloc, dir, tag, &busy);
    var take_over = false;
    if (pick.new and busy.items.len > 0) {
        if (chooseSession(alloc, busy.items)) |n| {
            pick = .{ .n = n };
            take_over = true;
        }
    }
    if (pick.n > max_sessions) {
        std.debug.print("hallows-persist: too many sessions\n", .{});
        return 1;
    }
    var name_buf: [8]u8 = undefined;
    const name = sessionName(&name_buf, pick.n);
    if (pick.new) try startDaemon(alloc, env, self_path, name, size);

    // A new daemon takes a moment to listen.
    const fd = fd: for (0..100) |_| {
        if (try connectSession(dir, name)) |fd| break :fd fd;
        sleepMs(20);
    } else {
        std.debug.print("hallows-persist: could not start a session\n", .{});
        return 1;
    };
    defer _ = c.close(fd);

    // Reset the window title in case +ssh set "reconnecting" in it. The
    // snapshot sets the session's own title, if it has one.
    var host_buf: [256]u8 = undefined;
    if (c.gethostname(&host_buf, host_buf.len) == 0) {
        const host = std.mem.sliceTo(&host_buf, 0);
        var title_buf: [300]u8 = undefined;
        writeAll(posix.STDOUT_FILENO, std.fmt.bufPrint(
            &title_buf,
            "\x1b]2;{s}\x07",
            .{host},
        ) catch "") catch {};
    }

    var hello_buf: [@sizeOf(Hello) + 64]u8 = undefined;
    const hello: Hello = .{
        .flags = @as(u8, @intFromBool(reconnect and pick.known)) |
            @as(u8, @intFromBool(take_over)) << 1,
        .size = size,
    };
    @memcpy(hello_buf[0..@sizeOf(Hello)], std.mem.asBytes(&hello));
    @memcpy(hello_buf[@sizeOf(Hello)..][0..tag.len], tag);
    try sendFrame(fd, .hello, hello_buf[0 .. @sizeOf(Hello) + tag.len]);

    return proxy(alloc, fd);
}

/// Start a daemon for session NAME, detached from this process and, where
/// systemd is available, in a user scope of its own: otherwise it would
/// share the ssh session's cgroup and could be killed along with it, e.g.
/// when sshd or tailscaled restarts.
fn startDaemon(
    alloc: Allocator,
    env: *const std.process.Environ.Map,
    self_path: []const u8,
    name: []const u8,
    size: Winsize,
) !void {
    const self_z = try alloc.dupeZ(u8, self_path);
    const name_z = try alloc.dupeZ(u8, name);
    const rows_z = try std.fmt.allocPrintSentinel(alloc, "{d}", .{size.rows}, 0);
    const cols_z = try std.fmt.allocPrintSentinel(alloc, "{d}", .{size.cols}, 0);
    const runtime_dir = try std.fmt.allocPrintSentinel(alloc, "/run/user/{d}", .{c.getuid()}, 0);
    const has_runtime_dir = env.get("XDG_RUNTIME_DIR") != null;

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = c.setsid();
        if (c.fork() != 0) c._exit(0);

        // Detach from the client's terminal.
        const null_fd = c.open("/dev/null", .{ .ACCMODE = .RDWR });
        if (null_fd >= 0) {
            _ = c.dup2(null_fd, 0);
            _ = c.dup2(null_fd, 1);
            _ = c.dup2(null_fd, 2);
        }

        // systemd-run --user needs this to find the user's manager.
        if (!has_runtime_dir and c.access(runtime_dir, 0) == 0)
            _ = setenv("XDG_RUNTIME_DIR", runtime_dir, 1);

        const scope_check = [_:null]?[*:0]const u8{ "systemd-run", "--user", "--scope", "--quiet", "true" };
        if (runWait(&scope_check) == 0) {
            const argv = [_:null]?[*:0]const u8{
                "systemd-run", "--user", "--scope", "--quiet", "--collect",
                self_z,        "serve",  name_z,    rows_z,    cols_z,
            };
            _ = execvp("systemd-run", &argv);
        }
        const argv = [_:null]?[*:0]const u8{ self_z, "serve", name_z, rows_z, cols_z };
        _ = execvp(self_z, &argv);
        c._exit(127);
    }

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
}

/// Run a command to completion and return its exit status, or -1.
fn runWait(argv: [*:null]const ?[*:0]const u8) c_int {
    const pid = c.fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        _ = execvp(argv[0].?, argv);
        c._exit(127);
    }
    var status: c_int = 0;
    if (c.waitpid(pid, &status, 0) < 0) return -1;
    return exitStatus(status);
}

var winch_pipe: [2]c.fd_t = .{ -1, -1 };

fn onWinch(_: posix.SIG) callconv(.c) void {
    _ = c.write(winch_pipe[1], "w", 1);
}

/// Shuttle bytes between this terminal and the daemon until the session
/// ends or either side goes away. Returns the exit status to use.
fn proxy(alloc: Allocator, fd: c.fd_t) !u8 {
    const stdin = posix.STDIN_FILENO;
    const stdout = posix.STDOUT_FILENO;

    var saved: c.termios = undefined;
    const raw = c.tcgetattr(stdin, &saved) == 0;
    if (raw) {
        var mode = saved;
        makeRaw(&mode);
        _ = c.tcsetattr(stdin, .NOW, &mode);
    }
    defer if (raw) {
        _ = c.tcsetattr(stdin, .NOW, &saved);
    };

    if (c.pipe(&winch_pipe) == 0) {
        setNonblock(winch_pipe[0]);
        setNonblock(winch_pipe[1]);
        var sa: posix.Sigaction = .{
            .handler = .{ .handler = onWinch },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESTART,
        };
        posix.sigaction(posix.SIG.WINCH, &sa, null);
    }

    var inbox: std.ArrayList(u8) = .empty;
    defer inbox.deinit(alloc);
    var buf: [64 * 1024]u8 = undefined;

    while (true) {
        var fds = [_]c.pollfd{
            .{ .fd = stdin, .events = c.POLL.IN, .revents = 0 },
            .{ .fd = fd, .events = c.POLL.IN, .revents = 0 },
            .{ .fd = winch_pipe[0], .events = c.POLL.IN, .revents = 0 },
        };
        if (c.poll(&fds, fds.len, -1) < 0) {
            if (c.errno(-1) == .INTR) continue;
            return error.PollFailed;
        }

        if (fds[2].revents != 0) {
            while (c.read(winch_pipe[0], &buf, buf.len) > 0) {}
            const size = terminalSize(stdin);
            try sendFrame(fd, .resize, std.mem.asBytes(&size));
        }

        if (fds[0].revents != 0) {
            const n = c.read(stdin, &buf, buf.len);
            // The terminal is gone, e.g. the ssh connection dropped.
            if (n <= 0) return 0;
            try sendFrame(fd, .input, buf[0..@intCast(n)]);
        }

        if (fds[1].revents != 0) {
            const n = c.read(fd, &buf, buf.len);
            if (n <= 0) {
                if (raw) _ = c.tcsetattr(stdin, .NOW, &saved);
                std.debug.print("\r\nhallows-persist: lost the session\r\n", .{});
                return 1;
            }
            try inbox.appendSlice(alloc, buf[0..@intCast(n)]);
            while (nextFrame(inbox.items)) |frame| {
                switch (frame.tag) {
                    .output => try writeAll(stdout, frame.payload),
                    .exit => return if (frame.payload.len > 0) frame.payload[0] else 0,
                    .detach => {
                        if (raw) _ = c.tcsetattr(stdin, .NOW, &saved);
                        std.debug.print("\r\nThis session was taken over by another terminal.\r\n", .{});
                        return 0;
                    },
                    else => {},
                }
                inbox.replaceRangeAssumeCapacity(0, frame.len, &.{});
            }
        }
    }
}

//---------------------------------------------------------------------
// Daemon

const Client = struct {
    fd: c.fd_t,
    attached: bool = false,
    /// The tag the client attached with.
    tag: ?[]u8 = null,
    /// Close once everything queued has been sent.
    closing: bool = false,
    inbox: std.ArrayList(u8) = .empty,
    outbox: std.ArrayList(u8) = .empty,
    closed: bool = false,
};

const Daemon = struct {
    alloc: Allocator,
    term: vt.Terminal,
    stream: vt.TerminalStream,
    pty: c.fd_t,
    child: c.pid_t,
    clients: std.ArrayList(*Client) = .empty,
    /// Bytes for the shell that the pty hasn't taken yet.
    pty_outbox: std.ArrayList(u8) = .empty,
    /// Tags of every client that has attached to this session.
    tags: std.StringHashMapUnmanaged(void) = .empty,
    detached_at: i64,
    /// When the session last had output or input.
    active_at: i64,
    size: Winsize,

    fn queue(self: *Daemon, client: *Client, tag: Tag, payload: []const u8) void {
        if (client.closed) return;
        if (client.outbox.items.len + header_len + payload.len > max_client_buffer) {
            client.closed = true;
            return;
        }
        var header: [header_len]u8 = undefined;
        encodeHeader(&header, tag, payload.len);
        client.outbox.appendSlice(self.alloc, &header) catch {
            client.closed = true;
            return;
        };
        client.outbox.appendSlice(self.alloc, payload) catch {
            client.closed = true;
        };
    }

    fn resize(self: *Daemon, size: Winsize) void {
        if (size.rows == 0 or size.cols == 0) return;
        self.size = size;
        _ = c.ioctl(self.pty, @bitCast(@as(u32, c.T.IOCSWINSZ)), &size);
        self.term.resize(self.alloc, .{ .cols = size.cols, .rows = size.rows }) catch {};
    }

    /// A label to tell this session apart from others: its window title
    /// if a program set one, otherwise the shell's working directory.
    fn label(self: *Daemon, buf: []u8) []const u8 {
        if (self.term.getTitle()) |title| if (title.len > 0) {
            const len = @min(title.len, buf.len);
            @memcpy(buf[0..len], title[0..len]);
            return buf[0..len];
        };
        if (builtin.os.tag != .linux) return buf[0..0];
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/cwd", .{self.child}) catch
            return buf[0..0];
        const n = c.readlink(path, buf.ptr, buf.len);
        return if (n > 0) buf[0..@intCast(n)] else buf[0..0];
    }

    /// The working directory of the program in the foreground of the
    /// session, or of the shell if that can't be found.
    fn cwd(self: *Daemon, buf: []u8) []const u8 {
        if (builtin.os.tag != .linux) return buf[0..0];
        const pgrp = tcgetpgrp(self.pty);
        for ([_]c.pid_t{ pgrp, self.child }) |pid| {
            if (pid <= 0) continue;
            var path_buf: [32]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/cwd", .{pid}) catch continue;
            const n = c.readlink(path, buf.ptr, buf.len);
            if (n > 0) return buf[0..@intCast(n)];
        }
        return buf[0..0];
    }

    fn handle(self: *Daemon, client: *Client, frame: Frame) void {
        switch (frame.tag) {
            .hello => {
                if (frame.payload.len < @sizeOf(Hello)) return;
                const hello = std.mem.bytesToValue(Hello, frame.payload[0..@sizeOf(Hello)]);
                const tag = frame.payload[@sizeOf(Hello)..];
                if (!validTag(tag)) return;
                if (!self.tags.contains(tag)) {
                    if (self.alloc.dupe(u8, tag)) |owned| {
                        self.tags.put(self.alloc, owned, {}) catch self.alloc.free(owned);
                    } else |_| {}
                }

                // Detach everyone else when taking over. A client with the
                // same tag is this terminal's connection from before it
                // dropped, which the host may not have noticed is gone.
                const take_over = hello.flags & 2 != 0;
                for (self.clients.items) |other| {
                    if (other == client or !other.attached) continue;
                    const same_tag = if (other.tag) |t| std.mem.eql(u8, t, tag) else false;
                    if (!take_over and !same_tag) continue;
                    self.queue(other, .detach, &.{});
                    other.attached = false;
                    other.closing = true;
                }
                client.tag = self.alloc.dupe(u8, tag) catch null;

                // Take the snapshot at the size the screen was drawn at,
                // then resize, which makes the shell redraw if it can.
                if (snapshot(self.alloc, &self.term, hello.flags & 1 == 0)) |data| {
                    defer self.alloc.free(data);
                    self.queue(client, .output, data);
                } else |_| {}
                client.attached = true;
                self.resize(hello.size);
            },
            .input => if (client.attached) {
                self.pty_outbox.appendSlice(self.alloc, frame.payload) catch {};
                self.active_at = now();
            },
            .resize => if (client.attached and frame.payload.len >= @sizeOf(Winsize)) {
                self.resize(std.mem.bytesToValue(Winsize, frame.payload[0..@sizeOf(Winsize)]));
            },
            .query => {
                var attached: u32 = 0;
                for (self.clients.items) |other| attached += @intFromBool(other.attached and !other.closed);
                const info: Info = .{
                    .clients = attached,
                    .detached_at = self.detached_at,
                    .knows_tag = @intFromBool(self.tags.contains(frame.payload)),
                    .active_at = self.active_at,
                };
                var reply: [@sizeOf(Info) + max_label]u8 = undefined;
                @memcpy(reply[0..@sizeOf(Info)], std.mem.asBytes(&info));
                const label_len = self.label(reply[@sizeOf(Info)..]).len;
                self.queue(client, .info, reply[0 .. @sizeOf(Info) + label_len]);
            },
            .cwd => {
                var where: Where = .{ .tag = @intFromBool(self.tags.contains(frame.payload)) };
                for (self.clients.items) |other| {
                    if (!other.attached or other.closed) continue;
                    const t = other.tag orelse continue;
                    if (std.mem.eql(u8, t, frame.payload)) where.tag = 2;
                }
                var reply: [@sizeOf(Where) + std.fs.max_path_bytes]u8 = undefined;
                @memcpy(reply[0..@sizeOf(Where)], std.mem.asBytes(&where));
                const len = self.cwd(reply[@sizeOf(Where)..]).len;
                self.queue(client, .where, reply[0 .. @sizeOf(Where) + len]);
            },
            else => {},
        }
    }
};

fn serve(
    alloc: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    name: []const u8,
    size: Winsize,
) !void {
    ignoreSigpipe();
    const dir = try stateDir(alloc, env);
    makeDirs(dir);

    // Listen before starting the shell so a failure leaves nothing behind.
    const addr = try socketAddr(dir, name);
    if (try connectSession(dir, name)) |fd| {
        // Someone else got here first.
        _ = c.close(fd);
        return;
    }
    _ = c.unlink(@ptrCast(&addr.path));
    const listener = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (listener < 0) return error.SocketFailed;
    if (c.bind(listener, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) != 0) return error.BindFailed;
    defer _ = c.unlink(@ptrCast(&addr.path));
    if (c.listen(listener, 16) != 0) return error.ListenFailed;
    setCloexec(listener);
    setNonblock(listener);

    const shell = env.get("SHELL") orelse "/bin/sh";
    const shell_z = try alloc.dupeZ(u8, shell);
    const login_name = try std.fmt.allocPrintSentinel(alloc, "-{s}", .{std.fs.path.basename(shell)}, 0);

    var pty: c_int = -1;
    const child = forkpty(&pty, null, null, &size);
    if (child < 0) return error.ForkptyFailed;
    if (child == 0) {
        // Ignored signals stay ignored across exec.
        var sa: posix.Sigaction = .{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.PIPE, &sa, null);
        const argv = [_:null]?[*:0]const u8{login_name};
        _ = execvp(shell_z, &argv);
        c._exit(127);
    }
    setCloexec(pty);
    setNonblock(pty);

    var term = try vt.Terminal.init(io, alloc, .{
        .cols = size.cols,
        .rows = size.rows,
        .max_scrollback_bytes = max_scrollback_bytes,
    });
    var daemon: Daemon = .{
        .alloc = alloc,
        .term = term,
        .stream = undefined,
        .pty = pty,
        .child = child,
        .detached_at = now(),
        .active_at = now(),
        .size = size,
    };
    daemon.stream = daemon.term.vtStream();
    _ = &term;

    const status = run(&daemon, listener);

    // Tell attached clients the session is over.
    for (daemon.clients.items) |client| {
        if (client.closed) continue;
        daemon.queue(client, .exit, &.{status});
        setBlocking(client.fd);
        writeAll(client.fd, client.outbox.items) catch {};
    }
}

/// Run the daemon until the shell exits. Returns its exit status.
fn run(daemon: *Daemon, listener: c.fd_t) u8 {
    const alloc = daemon.alloc;
    var fds: std.ArrayList(c.pollfd) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    var exit_status: ?u8 = null;

    while (true) {
        fds.clearRetainingCapacity();
        fds.append(alloc, .{ .fd = listener, .events = c.POLL.IN, .revents = 0 }) catch return 1;
        fds.append(alloc, .{
            .fd = daemon.pty,
            .events = c.POLL.IN | @as(i16, if (daemon.pty_outbox.items.len > 0) c.POLL.OUT else 0),
            .revents = 0,
        }) catch return 1;
        for (daemon.clients.items) |client| fds.append(alloc, .{
            .fd = client.fd,
            .events = c.POLL.IN | @as(i16, if (client.outbox.items.len > 0) c.POLL.OUT else 0),
            .revents = 0,
        }) catch return 1;

        // Wake up now and then to notice the shell exiting even if
        // something it started keeps the pty open.
        if (c.poll(fds.items.ptr, @intCast(fds.items.len), 1000) < 0 and c.errno(-1) != .INTR)
            return 1;

        if (exit_status == null) {
            var status: c_int = 0;
            if (c.waitpid(daemon.child, &status, c.W.NOHANG) == daemon.child)
                exit_status = exitStatus(status);
        }

        // Output from the shell.
        const pty_events = fds.items[1].revents;
        if (pty_events & c.POLL.IN != 0) {
            const n = c.read(daemon.pty, &buf, buf.len);
            if (n > 0) {
                const data = buf[0..@intCast(n)];
                daemon.stream.nextSlice(data);
                daemon.active_at = now();
                for (daemon.clients.items) |client| {
                    if (client.attached) daemon.queue(client, .output, data);
                }
            } else if (n == 0 or c.errno(n) != .AGAIN) {
                return exit_status orelse waitStatus(daemon.child);
            }
        } else if (pty_events & (c.POLL.HUP | c.POLL.ERR) != 0) {
            return exit_status orelse waitStatus(daemon.child);
        } else if (exit_status) |status| {
            // The shell is gone and the pty has nothing more to say.
            return status;
        }

        // Input for the shell.
        if (pty_events & c.POLL.OUT != 0) {
            const n = c.write(daemon.pty, daemon.pty_outbox.items.ptr, daemon.pty_outbox.items.len);
            if (n > 0) daemon.pty_outbox.replaceRangeAssumeCapacity(0, @intCast(n), &.{});
        }

        // Clients. New ones are appended, so look at the existing ones
        // through their poll entries first.
        for (daemon.clients.items, fds.items[2..]) |client, pfd| {
            if (pfd.revents & (c.POLL.IN | c.POLL.HUP | c.POLL.ERR) != 0) {
                const n = c.read(client.fd, &buf, buf.len);
                if (n <= 0) {
                    if (n == 0 or c.errno(n) != .AGAIN) client.closed = true;
                } else {
                    client.inbox.appendSlice(alloc, buf[0..@intCast(n)]) catch {
                        client.closed = true;
                    };
                    while (nextFrame(client.inbox.items)) |frame| {
                        daemon.handle(client, frame);
                        client.inbox.replaceRangeAssumeCapacity(0, frame.len, &.{});
                    }
                }
            }
            if (pfd.revents & c.POLL.OUT != 0 and client.outbox.items.len > 0) {
                const n = c.write(client.fd, client.outbox.items.ptr, client.outbox.items.len);
                if (n > 0) {
                    client.outbox.replaceRangeAssumeCapacity(0, @intCast(n), &.{});
                } else if (c.errno(n) != .AGAIN) {
                    client.closed = true;
                }
            }
            if (client.closing and client.outbox.items.len == 0) client.closed = true;
        }

        // Drop clients that went away.
        var i: usize = 0;
        while (i < daemon.clients.items.len) {
            const client = daemon.clients.items[i];
            if (!client.closed) {
                i += 1;
                continue;
            }
            if (client.attached) daemon.detached_at = now();
            _ = c.close(client.fd);
            if (client.tag) |tag| alloc.free(tag);
            client.inbox.deinit(alloc);
            client.outbox.deinit(alloc);
            alloc.destroy(client);
            _ = daemon.clients.swapRemove(i);
        }

        // New clients.
        if (fds.items[0].revents & c.POLL.IN != 0) {
            const fd = c.accept(listener, null, null);
            if (fd >= 0) {
                setCloexec(fd);
                setNonblock(fd);
                const client = alloc.create(Client) catch {
                    _ = c.close(fd);
                    continue;
                };
                client.* = .{ .fd = fd };
                daemon.clients.append(alloc, client) catch {
                    _ = c.close(fd);
                    alloc.destroy(client);
                };
            }
        }
    }
}

/// Escape sequences that bring a terminal to the state of `term`.
///
/// The terminal may still show this session from before its connection
/// dropped, with modes the program has since changed, so first undo
/// whatever programs commonly set. With `scrollback`, the session's
/// scrollback is replayed too, for a terminal that hasn't shown this
/// session before.
fn snapshot(alloc: Allocator, term: *vt.Terminal, scrollback: bool) ![]u8 {
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    const w = &builder.writer;

    try w.writeAll(
        // Leave the alternate screen, then soft reset (DECSTR).
        "\x1b[?1049l\x1b[!p" ++
            // Mouse reporting, focus events, bracketed paste and
            // synchronized output off.
            "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?1016l" ++
            "\x1b[?1004l\x1b[?2004l\x1b[?2026l" ++
            // Normal cursor keys and keypad, default cursor, keyboard
            // protocols off.
            "\x1b[?1l\x1b>\x1b[0 q\x1b[?25h\x1b[<99u\x1b[>4;0m",
    );

    // Synchronized output is a handshake between a program and the
    // terminal it's drawing on at the time. Replaying it would leave the
    // terminal waiting for an end that never comes.
    const had_synchronized_output = term.modes.get(.synchronized_output);
    term.modes.set(.synchronized_output, false);
    defer term.modes.set(.synchronized_output, had_synchronized_output);

    writeDynamicColor(w, .foreground, term.colors.foreground);
    writeDynamicColor(w, .background, term.colors.background);
    writeDynamicColor(w, .cursor, term.colors.cursor);

    const pages = &term.screens.active.pages;
    const primary = term.screens.active_key == .primary;

    // The scrollback goes first, as plain styled text, so it scrolls into
    // the terminal's own scrollback.
    if (scrollback and primary) {
        const screen_top = pages.getTopLeft(.screen);
        const active_top = pages.getTopLeft(.active);
        if (!screen_top.eql(active_top)) if (active_top.up(1)) |last| {
            var bottom = last;
            bottom.x = @intCast(pages.cols - 1);
            var fmt = vt.formatter.TerminalFormatter.init(term, .vt);
            fmt.content = .{ .selection = vt.Selection.init(screen_top, bottom, false) };
            fmt.extra = .none;
            try fmt.format(w);
            try w.writeAll("\r\n\x1b[0m");
        };
    }

    // Then the screen. On the alternate screen, the formatter's modes
    // switch the terminal to it, which clears it.
    if (primary) try w.writeAll("\x1b[H\x1b[2J");
    var fmt = vt.formatter.TerminalFormatter.init(term, .vt);
    const top_left = pages.pin(.{ .active = .{ .x = 0, .y = 0 } });
    const bottom_right = pages.pin(.{ .active = .{
        .x = @intCast(pages.cols - 1),
        .y = @intCast(pages.rows - 1),
    } });
    if (top_left != null and bottom_right != null) {
        fmt.content = .{ .selection = vt.Selection.init(top_left.?, bottom_right.?, false) };
    }
    fmt.extra = .{
        .palette = false,
        .modes = true,
        .scrolling_region = true,
        // Restoring tab stops moves the cursor after it has been placed.
        .tabstops = false,
        // Written below; the formatter's includes a stray NUL.
        .pwd = false,
        .keyboard = true,
        .screen = .all,
    };
    try fmt.format(w);

    if (term.getPwd()) |pwd| if (pwd.len > 0) try w.print("\x1b]7;{s}\x1b\\", .{pwd});
    // The formatter doesn't restore the title.
    if (term.getTitle()) |title| try w.print("\x1b]2;{s}\x07", .{title});

    return builder.toOwnedSlice();
}

fn writeDynamicColor(
    w: *std.Io.Writer,
    kind: vt.color.Dynamic,
    dynamic: vt.color.DynamicRGB,
) void {
    const rgb = dynamic.override orelse return;
    w.print("\x1b]{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\", .{
        @intFromEnum(kind), rgb.r, rgb.g, rgb.b,
    }) catch {};
}

//---------------------------------------------------------------------
// Helpers

const Frame = struct { tag: Tag, payload: []const u8, len: usize };

fn encodeHeader(buf: *[header_len]u8, tag: Tag, len: usize) void {
    buf[0] = @intFromEnum(tag);
    std.mem.writeInt(u32, buf[1..5], @intCast(len), .little);
}

/// The first complete frame in `data`, if there is one.
fn nextFrame(data: []const u8) ?Frame {
    if (data.len < header_len) return null;
    const len = std.mem.readInt(u32, data[1..5], .little);
    if (data.len < header_len + len) return null;
    return .{
        .tag = @enumFromInt(data[0]),
        .payload = data[header_len..][0..len],
        .len = header_len + len,
    };
}

fn sendFrame(fd: c.fd_t, tag: Tag, payload: []const u8) !void {
    var header: [header_len]u8 = undefined;
    encodeHeader(&header, tag, payload.len);
    try writeAll(fd, &header);
    try writeAll(fd, payload);
}

fn writeAll(fd: c.fd_t, data: []const u8) !void {
    var rest = data;
    while (rest.len > 0) {
        const n = c.write(fd, rest.ptr, rest.len);
        if (n < 0) {
            if (c.errno(n) == .INTR) continue;
            return error.WriteFailed;
        }
        rest = rest[@intCast(n)..];
    }
}

fn readFull(fd: c.fd_t, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = c.read(fd, buf[got..].ptr, buf.len - got);
        if (n < 0 and c.errno(n) == .INTR) continue;
        if (n <= 0) return error.ReadFailed;
        got += @intCast(n);
    }
}

fn terminalSize(fd: c.fd_t) Winsize {
    var size: Winsize = .{ .rows = 24, .cols = 80 };
    if (c.ioctl(fd, @bitCast(@as(u32, c.T.IOCGWINSZ)), &size) != 0 or size.rows == 0 or size.cols == 0)
        return .{ .rows = 24, .cols = 80 };
    return size;
}

fn makeRaw(t: *c.termios) void {
    t.iflag.IGNBRK = false;
    t.iflag.BRKINT = false;
    t.iflag.PARMRK = false;
    t.iflag.ISTRIP = false;
    t.iflag.INLCR = false;
    t.iflag.IGNCR = false;
    t.iflag.ICRNL = false;
    t.iflag.IXON = false;
    t.oflag.OPOST = false;
    t.lflag.ECHO = false;
    t.lflag.ECHONL = false;
    t.lflag.ICANON = false;
    t.lflag.ISIG = false;
    t.lflag.IEXTEN = false;
    t.cflag.CSIZE = .CS8;
    t.cflag.PARENB = false;
    t.cc[@intFromEnum(c.V.MIN)] = 1;
    t.cc[@intFromEnum(c.V.TIME)] = 0;
}

fn setFlag(fd: c.fd_t, get: c_int, set: c_int, flag: c_int, on: bool) void {
    const flags = c.fcntl(fd, get);
    if (flags < 0) return;
    _ = c.fcntl(fd, set, if (on) flags | flag else flags & ~flag);
}

fn setNonblock(fd: c.fd_t) void {
    setFlag(fd, c.F.GETFL, c.F.SETFL, @bitCast(c.O{ .NONBLOCK = true }), true);
}

fn setBlocking(fd: c.fd_t) void {
    setFlag(fd, c.F.GETFL, c.F.SETFL, @bitCast(c.O{ .NONBLOCK = true }), false);
}

fn setCloexec(fd: c.fd_t) void {
    setFlag(fd, c.F.GETFD, c.F.SETFD, c.FD_CLOEXEC, true);
}

fn ignoreSigpipe() void {
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &sa, null);
}

/// The shell convention for a wait status: the exit code, or 128 plus the
/// signal number.
fn exitStatus(status: c_int) u8 {
    const s: u32 = @bitCast(status);
    if (s & 0x7f == 0) return @truncate(s >> 8);
    return @truncate(128 + (s & 0x7f));
}

fn waitStatus(pid: c.pid_t) u8 {
    var status: c_int = 0;
    if (c.waitpid(pid, &status, 0) != pid) return 1;
    return exitStatus(status);
}

fn now() i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

fn sleepMs(ms: u32) void {
    var ts: c.timespec = .{ .sec = 0, .nsec = @as(isize, ms) * std.time.ns_per_ms };
    _ = c.nanosleep(&ts, &ts);
}

test "frames" {
    const testing = std.testing;
    var buf: [header_len + 3]u8 = undefined;
    encodeHeader(buf[0..header_len], .input, 3);
    @memcpy(buf[header_len..], "abc");
    try testing.expect(nextFrame(buf[0..4]) == null);
    try testing.expect(nextFrame(buf[0 .. buf.len - 1]) == null);
    const frame = nextFrame(&buf).?;
    try testing.expectEqual(Tag.input, frame.tag);
    try testing.expectEqualStrings("abc", frame.payload);
    try testing.expectEqual(buf.len, frame.len);
}

test "validTag" {
    const testing = std.testing;
    try testing.expect(validTag("0a1b2c3d4e5f"));
    try testing.expect(validTag("a_b-c"));
    try testing.expect(!validTag(""));
    try testing.expect(!validTag("../x"));
    try testing.expect(!validTag("a b"));
}

test "formatAgo" {
    const testing = std.testing;
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("just now", formatAgo(&buf, 5));
    try testing.expectEqualStrings("5m ago", formatAgo(&buf, 5 * 60 + 10));
    try testing.expectEqualStrings("3h ago", formatAgo(&buf, 3 * 3600 + 59));
    try testing.expectEqualStrings("2d ago", formatAgo(&buf, 2 * 86400));
}

test "writePrintable" {
    const testing = std.testing;
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writePrintable(&w, "a\x1b[31mb\x07c ~/d");
    try testing.expectEqualStrings("a[31mbc ~/d", w.buffered());
}

test "exitStatus" {
    const testing = std.testing;
    try testing.expectEqual(@as(u8, 0), exitStatus(0));
    try testing.expectEqual(@as(u8, 3), exitStatus(3 << 8));
    try testing.expectEqual(@as(u8, 128 + 9), exitStatus(9));
}

test "snapshot" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try vt.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 3 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("one\r\ntwo\r\nthree\r\nfour\x1b]2;my title\x07");

    // Replaying the snapshot into a fresh terminal reproduces the screen,
    // scrollback and title.
    const full = try snapshot(alloc, &term, true);
    defer alloc.free(full);
    var copy = try vt.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 3 });
    defer copy.deinit(alloc);
    var copy_stream = copy.vtStream();
    defer copy_stream.deinit();
    copy_stream.nextSlice(full);

    const screen = try copy.plainString(alloc);
    defer alloc.free(screen);
    const original = try term.plainString(alloc);
    defer alloc.free(original);
    try testing.expectEqualStrings(original, screen);
    try testing.expectEqualStrings("my title", copy.getTitle().?);
    try testing.expectEqual(term.screens.active.cursor.x, copy.screens.active.cursor.x);
    try testing.expectEqual(term.screens.active.cursor.y, copy.screens.active.cursor.y);

    // Without scrollback, only the screen is redrawn, over whatever the
    // terminal showed before.
    const screen_only = try snapshot(alloc, &term, false);
    defer alloc.free(screen_only);
    try testing.expect(std.mem.indexOf(u8, screen_only, "one") == null);
    try testing.expect(std.mem.indexOf(u8, screen_only, "four") != null);
}

test "snapshot: alternate screen" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try vt.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 3 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("shell\r\n\x1b[?1049h\x1b[?2004h\x1b[Hfull screen app");

    const data = try snapshot(alloc, &term, false);
    defer alloc.free(data);

    // A terminal that was left on the alternate screen with other modes
    // set ends up matching.
    var copy = try vt.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 3 });
    defer copy.deinit(alloc);
    var copy_stream = copy.vtStream();
    defer copy_stream.deinit();
    copy_stream.nextSlice("\x1b[?1049h\x1b[?1000hstale");
    copy_stream.nextSlice(data);

    try testing.expectEqual(term.screens.active_key, copy.screens.active_key);
    try testing.expect(copy.modes.get(.bracketed_paste));
    try testing.expect(!copy.modes.get(.mouse_event_normal));
    const screen = try copy.plainString(alloc);
    defer alloc.free(screen);
    try testing.expectEqualStrings("full screen app", screen);
}

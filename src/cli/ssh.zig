const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const cli_args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const Action = @import("ghostty.zig").Action;
const DiskCache = @import("ssh_cache.zig").DiskCache;
const internal_os = @import("../os/main.zig");
const terminfopkg = @import("../terminfo/main.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.ssh);

const usage =
    \\Usage: ghostty +ssh [flags] [--] <ssh args...>
    \\
    \\Flags:
    \\  --forward-env[=bool]  Enable TERM / SendEnv forwarding. Default: true.
    \\  --terminfo[=bool]     Install Ghostty terminfo on first connect. Default: true.
    \\  --cache[=bool]        Use the terminfo install cache. Default: true.
    \\  --persist[=bool]      Run interactive logins in tmux and reconnect
    \\                        automatically. Default: false.
    \\  --ssh=<path>          Path to the ssh binary. Default: first `ssh` on PATH.
    \\  --verbose             Print +ssh status lines to stderr.
    \\  --help                Show full help.
    \\
    \\ssh flags and the destination go after +ssh's own flags (or after `--`).
    \\
;

pub const Options = struct {
    /// Set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// Maps to the `ssh-env` shell integration feature.
    @"forward-env": bool = true,

    /// Maps to the `ssh-terminfo` shell integration feature.
    terminfo: bool = true,

    /// When false, both cache read and write are bypassed.
    cache: bool = true,

    /// Maps to the `ssh-persist` shell integration feature.
    persist: bool = false,

    /// The wrapped `ssh` binary.
    /// `/`-containing values are treated as paths; otherwise resolved via PATH.
    ssh: []const u8 = "ssh",

    /// When true, print verbose output to stderr.
    verbose: bool = false,

    /// Arguments passed through to `ssh` verbatim. Populated by
    /// `parseManuallyHook` when we reach the first non-flag argument (or
    /// an explicit `--`).
    _ssh_args: std.ArrayList([]const u8) = .empty,

    /// Enables arg parsing diagnostics so unknown flags become
    /// diagnostics rather than fatal errors.
    _diagnostics: diagnostics.DiagnosticList = .{},

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(_: Options) !void {
        return Action.help_error;
    }

    /// Manual parse hook. For each argument:
    ///   - If it's a literal `--`, consume everything after it as ssh
    ///     args and stop parsing.
    ///   - If it doesn't start with `--`, this is the start of the ssh
    ///     argv. Consume this arg and everything after as ssh args and
    ///     stop parsing.
    ///   - Otherwise (a `--foo` arg), return true so the generic parser
    ///     handles it as one of our own flags.
    pub fn parseManuallyHook(
        self: *Options,
        alloc: Allocator,
        arg: []const u8,
        iter: anytype,
    ) Allocator.Error!bool {
        if (std.mem.eql(u8, arg, "--")) {
            while (iter.next()) |rest| {
                try self._ssh_args.append(alloc, try alloc.dupe(u8, rest));
            }
            return false;
        }

        if (!std.mem.startsWith(u8, arg, "--")) {
            try self._ssh_args.append(alloc, try alloc.dupe(u8, arg));
            while (iter.next()) |rest| {
                try self._ssh_args.append(alloc, try alloc.dupe(u8, rest));
            }
            return false;
        }

        return true;
    }
};

/// Wrap `ssh` to automatically configure Ghostty terminal integration on
/// remote hosts.
///
/// Any arguments that aren't recognized as `+ssh` flags are passed to
/// the real `ssh` binary unchanged. You can use `--` as an explicit
/// disambiguator if needed, though it's almost never required: `ssh`
/// has no long flags, and `+ssh` defines no short flags, so there's
/// nothing to collide.
///
/// This is typically called via Ghostty's shell integration. When
/// `shell-integration-features` includes `ssh-env` or `ssh-terminfo`,
/// each shell defines an `ssh` function that runs:
///
///     ghostty +ssh <flags> -- "$@"
///
/// You can also run `ghostty +ssh` directly, or alias it yourself (e.g.
/// `alias ssh='ghostty +ssh --'`) if you prefer not to use the shell
/// integration.
///
/// `+ssh` performs up to two pieces of setup before launching `ssh`:
///
///   1. **Environment forwarding** (`--forward-env`). Sets `TERM` to
///      `xterm-256color` and requests `SendEnv` forwarding of
///      `COLORTERM`, `TERM_PROGRAM`, and `TERM_PROGRAM_VERSION` so the
///      remote shell can still detect that it's running inside Ghostty.
///      The remote `sshd_config` must list these in `AcceptEnv` for
///      forwarding to succeed.
///
///   2. **Terminfo install** (`--terminfo`). On the first connection to a
///      given destination, installs Ghostty's embedded terminfo entry on the
///      remote host using `ssh tic -x -` over a shared `ControlMaster`
///      connection. Successful installs are cached
///      (see `ghostty +ssh-cache`) so subsequent connections skip this
///      step. When terminfo is successfully installed or already cached,
///      `TERM` is set to `xterm-ghostty` instead of `xterm-256color`.
///
/// If `--terminfo` install fails (e.g. `tic` not available on the
/// remote, filesystem permissions), a warning is logged and the
/// connection continues with `TERM=xterm-256color`.
///
/// With `--persist`, an interactive login (a destination with no remote
/// command, run from a terminal) is made to survive dropped connections,
/// such as when the computer sleeps, the network changes, or the remote
/// `sshd`/`tailscaled` restarts:
///
///   * On the first connection to a destination, a small helper script is
///     installed as `~/.local/share/ghostty/ssh-persist` on the remote
///     host (cached like the terminfo install). The remote host needs
///     `tmux`; without it, `+ssh` falls back to a normal login.
///
///   * The login attaches to tmux. The tmux server is started in a systemd
///     user scope when available, so it outlives the ssh session's cgroup,
///     and Ghostty's terminal features are enabled in tmux.
///
///   * When the connection drops, `+ssh` reconnects on its own and lands
///     on the tmux session this terminal was last showing, even after
///     switching sessions inside tmux. Reconnect progress is shown in the
///     window title only. Detaching or exiting tmux ends `+ssh` as usual.
///
/// Remembering session switches across reconnects needs a Linux remote;
/// elsewhere, reconnects attach to the most recently used session.
///
/// Flags:
///
///   * `--forward-env=<bool>`: Enable `TERM` / `SendEnv` environment
///     forwarding. Default: `true`.
///
///   * `--terminfo=<bool>`: Enable automatic terminfo install on first
///     connection. Default: `true`.
///
///   * `--persist=<bool>`: Run interactive logins inside tmux and
///     reconnect automatically when the connection drops (see above).
///     Default: `false`.
///
///   * `--cache=<bool>`: Use the terminfo install cache. Default: `true`.
///     When `false`, both the cache read (skip-if-installed) and the
///     cache write (record-on-success) are bypassed, and every
///     connection performs the install. To one-shot reinstall a single
///     host while keeping the cache in use, prefer `ghostty +ssh-cache
///     --remove=<host>` followed by a normal connection.
///
///   * `--ssh=<path>`: Path to the `ssh` binary to execute. Default: the
///     first `ssh` found on `PATH`.
///
///   * `--verbose`: Print +ssh status lines to stderr, and surface
///     remote stderr during the terminfo install.
///
/// Examples:
///
///     # Basic invocation using defaults:
///     ghostty +ssh user@example.com
///
///     # Forward Ghostty env vars but skip the terminfo install:
///     ghostty +ssh --terminfo=false user@example.com
///
///     # `ssh` flags (short-form `-p`, etc.) pass through unchanged:
///     ghostty +ssh -p 2222 -i ~/.ssh/id_ed25519 user@example.com
///
///     # Use `--` explicitly if your ssh args might collide with our flags:
///     ghostty +ssh -- --some-rare-ssh-arg user@example.com
///
/// Pass `--verbose` to see what `+ssh` is doing. For cache inspection
/// and management, see `ghostty +ssh-cache`.
///
/// Available since: 1.4.0
pub fn run(alloc_gpa: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try cli_args.argsIterator(alloc_gpa, global.args());
        defer iter.deinit();
        try cli_args.parse(Options, alloc_gpa, &opts, &iter);
    }

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file: std.Io.File = .stderr();
    var stderr_writer = stderr_file.writer(global.io(), &stderr_buffer);
    const stderr = &stderr_writer.interface;

    // Any diagnostic from the arg parser is an unknown flag or bad
    // value. Reject loudly — silently forwarding `--typo` to ssh would
    // produce confusing downstream errors.
    if (!opts._diagnostics.empty()) {
        for (opts._diagnostics.items()) |diag| {
            if (diag.key.len > 0) {
                stderr.print(
                    "Error: unknown flag `--{s}`.\n",
                    .{diag.key},
                ) catch {};
            } else {
                stderr.print("Error: {s}\n", .{diag.message}) catch {};
            }
        }
        stderr.print("\n{s}", .{usage}) catch {};
        stderr.flush() catch {};
        return 2;
    }

    const result = runInner(alloc_gpa, &opts, stderr);

    stderr.flush() catch {};
    return result;
}

fn runInner(
    gpa: Allocator,
    opts: *const Options,
    stderr: *std.Io.Writer,
) !u8 {
    var arena = ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    if (opts._ssh_args.items.len == 0) {
        try stderr.print("Error: no ssh arguments provided.\n\n{s}", .{usage});
        return 2;
    }

    // `ssh -G` output, for resolving the destination and its settings.
    const ssh_config: ?[]const u8 = if (opts.terminfo or opts.persist)
        sshConfig(alloc, opts.ssh, opts._ssh_args.items)
    else
        null;

    const session: struct {
        term: []const u8,
        to_cache: ?struct { cache: DiskCache, dest: []const u8 } = null,
    } = session: {
        if (!opts.terminfo) break :session .{ .term = "xterm-256color" };

        const dest = (if (ssh_config) |c| parseDestination(alloc, c) else null) orelse {
            warnPrint(stderr, "could not resolve ssh destination; skipping terminfo install", .{});
            break :session .{ .term = "xterm-256color" };
        };

        const cache: ?DiskCache = if (opts.cache) cache: {
            const path = DiskCache.defaultPath(alloc, "ghostty") catch |err| {
                warnPrint(stderr, "ghostty terminfo cache unavailable: {t}", .{err});
                break :session .{ .term = "xterm-256color" };
            };
            break :cache .{ .path = path };
        } else null;

        if (cache) |c| {
            const cached = c.contains(
                alloc,
                dest,
                terminfopkg.version,
            ) catch |err| cached: {
                if (DiskCache.isFailure(err)) warnPrint(
                    stderr,
                    "unable to read the cache '{s}': {t}",
                    .{ c.path, err },
                );
                break :cached false;
            };

            if (cached) {
                verbosePrint(opts, stderr, "dest: {s} (cached, skipping install)", .{dest});
                break :session .{ .term = "xterm-ghostty" };
            } else {
                verbosePrint(opts, stderr, "dest: {s} (not cached, will install)", .{dest});
            }
        } else {
            verbosePrint(opts, stderr, "dest: {s} (cache disabled, will install)", .{dest});
        }

        stderr.print("Setting up xterm-ghostty terminfo on {s}...\n", .{dest}) catch {};
        stderr.flush() catch {};

        installRemoteTerminfo(alloc, opts, stderr) catch |err| {
            warnPrint(stderr, "failed to install terminfo: {t}", .{err});
            break :session .{ .term = "xterm-256color" };
        };
        break :session .{
            .term = "xterm-ghostty",
            .to_cache = if (cache) |c| .{ .cache = c, .dest = dest } else null,
        };
    };

    // Build the full argv: [ssh, ...our opts, ...user args]
    const env_opts: []const []const u8 = if (opts.@"forward-env") env_opts: {
        const set_term = try std.fmt.allocPrint(
            alloc,
            "SetEnv=TERM={s}",
            .{session.term},
        );
        break :env_opts &.{
            "-o", set_term,
            "-o", "SendEnv=COLORTERM",
            "-o", "SendEnv=TERM_PROGRAM",
            "-o", "SendEnv=TERM_PROGRAM_VERSION",
        };
    } else &.{};
    const prefix = try std.mem.concat(alloc, []const u8, &.{ &.{opts.ssh}, env_opts });

    const persist_dest: ?[]const u8 = if (opts.persist)
        setupPersist(alloc, opts, stderr, ssh_config)
    else
        null;

    const exit_code = if (persist_dest) |dest| exit_code: {
        break :exit_code runPersistent(alloc, opts, stderr, prefix, dest) catch |err| {
            try stderr.print("Error: failed to run {s}: {t}\n", .{ opts.ssh, err });
            return 1;
        };
    } else exit_code: {
        const argv = try std.mem.concat(alloc, []const u8, &.{
            prefix,
            opts._ssh_args.items,
        });
        verbosePrint(opts, stderr, "exec: {f}", .{Joined{ .items = argv }});

        break :exit_code childExec(argv) catch |err| {
            try stderr.print("Error: failed to run {s}: {t}\n", .{ argv[0], err });
            return 1;
        };
    };
    verbosePrint(opts, stderr, "exit: {d}", .{exit_code});

    // Attempt to cache (if needed) on a successful ssh execution.
    if (exit_code == 0) if (session.to_cache) |entry| {
        if (entry.cache.add(
            alloc,
            entry.dest,
            terminfopkg.version,
            std.Io.Timestamp.now(global.io(), .real).toSeconds(),
        )) |_| {
            verbosePrint(opts, stderr, "cache: wrote {s}", .{entry.dest});
        } else |err| {
            if (DiskCache.isFailure(err)) {
                warnPrint(
                    stderr,
                    "unable to add '{s}' to the cache '{s}': {t}",
                    .{ entry.dest, entry.cache.path, err },
                );
            } else {
                verbosePrint(
                    opts,
                    stderr,
                    "cache: skipped {s}: {t}",
                    .{ entry.dest, err },
                );
            }
        }
    };

    return exit_code;
}

/// Log to `.ssh` and, if `--verbose`, also print to stderr.
fn verbosePrint(
    opts: *const Options,
    stderr: *std.Io.Writer,
    comptime fmt: []const u8,
    args: anytype,
) void {
    log.debug(fmt, args);
    if (!opts.verbose) return;
    stderr.print("+ssh: " ++ fmt ++ "\n", args) catch return;
    stderr.flush() catch return;
}

/// Log a warning and also print a `Warning: <msg>` line to stderr.
fn warnPrint(
    stderr: *std.Io.Writer,
    comptime fmt: []const u8,
    args: anytype,
) void {
    log.warn(fmt, args);
    stderr.print("Warning: " ++ fmt ++ "\n", args) catch return;
    stderr.flush() catch return;
}

/// Space-joined items, formattable as `{f}`.
const Joined = struct {
    items: []const []const u8,

    pub fn format(self: Joined, writer: *std.Io.Writer) !void {
        for (self.items, 0..) |a, i| {
            if (i > 0) try writer.writeByte(' ');
            try writer.writeAll(a);
        }
    }

    test {
        const testing = std.testing;
        var buf: [128]u8 = undefined;
        {
            var w: std.Io.Writer = .fixed(&buf);
            try w.print("{f}", .{Joined{ .items = &.{} }});
            try testing.expectEqualStrings("", buf[0..w.end]);
        }
        {
            var w: std.Io.Writer = .fixed(&buf);
            try w.print("{f}", .{Joined{ .items = &.{"only"} }});
            try testing.expectEqualStrings("only", buf[0..w.end]);
        }
        {
            var w: std.Io.Writer = .fixed(&buf);
            try w.print("{f}", .{Joined{ .items = &.{ "a", "b", "c" } }});
            try testing.expectEqualStrings("a b c", buf[0..w.end]);
        }
    }
};

fn checkExit(term: std.process.Child.Term, label: []const u8) error{ChildFailed}!void {
    switch (term) {
        .exited => |rc| if (rc != 0) {
            log.warn("{s} exited with non-zero status: {d}", .{ label, rc });
            return error.ChildFailed;
        },
        else => {
            log.warn("{s} terminated abnormally: {}", .{ label, term });
            return error.ChildFailed;
        },
    }
}

/// Run `ssh -G <args>` and return its output: the effective ssh
/// configuration for this invocation, one lowercase `key value` per line.
/// Returns null if ssh couldn't evaluate it.
fn sshConfig(
    alloc: Allocator,
    ssh: []const u8,
    args: []const []const u8,
) ?[]const u8 {
    const argv = std.mem.concat(alloc, []const u8, &.{
        &.{ ssh, "-G" },
        args,
    }) catch return null;
    const result = std.process.run(
        alloc,
        global.io(),
        .{ .argv = argv },
    ) catch |err| {
        log.warn("ssh -G spawn failed: {}", .{err});
        return null;
    };
    checkExit(result.term, "ssh -G") catch return null;
    return result.stdout;
}

/// Parse `ssh -G` output for `user`, `hostname` and `port` and return the
/// formatted `user@hostname`, or `user@hostname:port` when the port isn't
/// the default 22 (`user@[hostname]:port` for an IPv6 address), so that
/// different sshd instances behind one address are cached separately.
/// Returns null if user or hostname is missing or formatting fails.
fn parseDestination(alloc: Allocator, stdout: []const u8) ?[]const u8 {
    var user: []const u8 = "";
    var host: []const u8 = "";
    var port: []const u8 = "";
    var it = std.mem.tokenizeScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const key = line[0..space];
        const value = line[space + 1 ..];
        if (std.mem.eql(u8, key, "user")) {
            user = value;
        } else if (std.mem.eql(u8, key, "hostname")) {
            host = value;
        } else if (std.mem.eql(u8, key, "port")) {
            port = value;
        }
        if (user.len > 0 and host.len > 0 and port.len > 0) break;
    }

    if (user.len == 0) {
        log.warn("ssh -G output missing user", .{});
        return null;
    }
    if (host.len == 0) {
        log.warn("ssh -G output missing hostname", .{});
        return null;
    }

    if (port.len == 0 or std.mem.eql(u8, port, "22")) {
        return std.fmt.allocPrint(alloc, "{s}@{s}", .{ user, host }) catch null;
    }

    if (std.mem.indexOfScalar(u8, host, ':') != null) {
        return std.fmt.allocPrint(alloc, "{s}@[{s}]:{s}", .{ user, host, port }) catch null;
    }
    return std.fmt.allocPrint(alloc, "{s}@{s}:{s}", .{ user, host, port }) catch null;
}

/// Install Ghostty's terminfo on the remote host over a short-lived SSH
/// ControlMaster connection. The master tears down with the client
/// (`ControlPersist=no`) so no socket lingers.
fn installRemoteTerminfo(
    alloc: Allocator,
    opts: *const Options,
    stderr: *std.Io.Writer,
) !void {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try terminfopkg.ghostty.encode(&buf.writer);
    const terminfo = buf.written();

    // ControlPath is in TMPDIR with a short, random basename. ssh uses
    // ControlPath as the bind address for a Unix domain socket; macOS
    // limits sockaddr_un.sun_path to ~104 bytes, so keeping the path
    // short leaves margin.
    const control_path = try internal_os.randomTmpPath(alloc, "ghostty-ssh-");
    const control_path_opt = try std.fmt.allocPrint(
        alloc,
        "ControlPath={s}",
        .{control_path},
    );

    // Under --verbose, let remote stderr through (the `tic` step is
    // the most common failure source) and inherit ssh's stderr so it
    // reaches the user's terminal. Other steps stay quiet either way.
    const remote_script = if (opts.verbose)
        \\command -v tic >/dev/null 2>&1 || exit 1
        \\mkdir -p ~/.terminfo 2>/dev/null && tic -x - && exit 0
        \\exit 1
    else
        \\command -v tic >/dev/null 2>&1 || exit 1
        \\mkdir -p ~/.terminfo 2>/dev/null && tic -x - 2>/dev/null && exit 0
        \\exit 1
    ;

    // Set up an SSH ControlMaster scoped to this single install:
    //   - ControlMaster=yes makes our client also act as the master.
    //   - ControlPersist=no tears the master down when our client
    //     exits; no socket lingers on the remote side.
    const argv = try std.mem.concat(alloc, []const u8, &.{
        &.{opts.ssh},
        &.{
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=no",
            "-o", control_path_opt,
        },
        opts._ssh_args.items,
        &.{remote_script},
    });
    verbosePrint(opts, stderr, "exec: {f}", .{Joined{ .items = argv }});

    var child = std.process.spawn(global.io(), .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = if (opts.verbose) .inherit else .ignore,
    }) catch |err| {
        log.warn("terminfo install spawn failed: {}", .{err});
        return error.InstallFailed;
    };

    if (child.stdin) |stdin| {
        stdin.writeStreamingAll(global.io(), terminfo) catch {};
        stdin.close(global.io());
        child.stdin = null;
    }

    const term = child.wait(global.io()) catch |err| {
        log.warn("terminfo install wait failed: {}", .{err});
        return error.InstallFailed;
    };
    checkExit(term, "terminfo install") catch return error.InstallFailed;
}

/// The remote half of `--persist`, installed on each destination.
const persist_script = @embedFile("ssh_persist.sh");

/// Identifies `persist_script` in the persist cache, so hosts get the new
/// script when it changes.
const persist_version = version: {
    @setEvalBranchQuota(100_000);
    break :version std.fmt.comptimePrint(
        "{x}",
        .{std.hash.Wyhash.hash(0, persist_script)},
    );
};

/// Where `persist_script` lives on the remote, relative to `$HOME`.
const persist_remote_path = ".local/share/ghostty/ssh-persist";

/// Fed to `sh -s` on the remote to install `persist_script`. Exits with 3
/// if the remote doesn't have tmux.
const persist_install_script =
    \\set -e
    \\command -v tmux >/dev/null 2>&1 || exit 3
    \\f="$HOME/
++ persist_remote_path ++
    \\"
    \\mkdir -p "$(dirname "$f")"
    \\cat >"$f.tmp" <<'__GHOSTTY_SSH_PERSIST__'
    \\
++ persist_script ++
    \\__GHOSTTY_SSH_PERSIST__
    \\chmod 755 "$f.tmp"
    \\mv -f "$f.tmp" "$f"
    \\
;

/// Decide whether this invocation runs persistently and, if so, make sure
/// the remote helper is installed. Returns the destination when the
/// session should run persistently, or null to run plain ssh.
fn setupPersist(
    alloc: Allocator,
    opts: *const Options,
    stderr: *std.Io.Writer,
    ssh_config: ?[]const u8,
) ?[]const u8 {
    if (!isInteractiveLogin(opts._ssh_args.items)) {
        verbosePrint(opts, stderr, "persist: not an interactive login", .{});
        return null;
    }

    const io = global.io();
    const stdin_tty = std.Io.File.stdin().isTty(io) catch false;
    const stdout_tty = std.Io.File.stdout().isTty(io) catch false;
    if (!stdin_tty or !stdout_tty) {
        verbosePrint(opts, stderr, "persist: not running in a terminal", .{});
        return null;
    }

    const config = ssh_config orelse {
        warnPrint(stderr, "could not read the ssh configuration; not persisting the session", .{});
        return null;
    };
    if (!configAllowsPersist(config)) {
        verbosePrint(opts, stderr, "persist: ssh config sets a remote command or disables the tty", .{});
        return null;
    }
    const dest = parseDestination(alloc, config) orelse {
        warnPrint(stderr, "could not resolve ssh destination; not persisting the session", .{});
        return null;
    };

    const cache: ?DiskCache = if (opts.cache) cache: {
        const path = persistCachePath(alloc) catch |err| {
            warnPrint(stderr, "ghostty persist cache unavailable: {t}", .{err});
            break :cache null;
        };
        break :cache .{ .path = path };
    } else null;

    if (cache) |c| {
        const cached = c.contains(alloc, dest, persist_version) catch |err| cached: {
            if (DiskCache.isFailure(err)) warnPrint(
                stderr,
                "unable to read the cache '{s}': {t}",
                .{ c.path, err },
            );
            break :cached false;
        };
        if (cached) {
            verbosePrint(opts, stderr, "persist: {s} (cached, skipping install)", .{dest});
            return dest;
        }
    }

    stderr.print("Setting up persistent sessions on {s}...\n", .{dest}) catch {};
    stderr.flush() catch {};

    installPersistScript(alloc, opts, stderr) catch |err| {
        switch (err) {
            error.NoTmux => warnPrint(
                stderr,
                "tmux is not installed on {s}; connecting without a persistent session",
                .{dest},
            ),
            else => warnPrint(
                stderr,
                "failed to set up persistent sessions: {t}",
                .{err},
            ),
        }
        return null;
    };

    if (cache) |c| c.add(
        alloc,
        dest,
        persist_version,
        std.Io.Timestamp.now(io, .real).toSeconds(),
    ) catch |err| {
        if (DiskCache.isFailure(err)) warnPrint(
            stderr,
            "unable to add '{s}' to the cache '{s}': {t}",
            .{ dest, c.path, err },
        );
    };

    return dest;
}

/// The persist cache sits next to the terminfo cache. It records which
/// version of `persist_script` each destination has.
fn persistCachePath(alloc: Allocator) ![]const u8 {
    const terminfo_cache = try DiskCache.defaultPath(alloc, "ghostty");
    const dir = std.fs.path.dirname(terminfo_cache) orelse return error.XdgLookupFailed;
    return std.fs.path.join(alloc, &.{ dir, "ssh_persist_cache" });
}

fn installPersistScript(
    alloc: Allocator,
    opts: *const Options,
    stderr: *std.Io.Writer,
) !void {
    const argv = try std.mem.concat(alloc, []const u8, &.{
        &.{opts.ssh},
        opts._ssh_args.items,
        &.{"sh -s"},
    });
    verbosePrint(opts, stderr, "exec: {f}", .{Joined{ .items = argv }});

    var child = std.process.spawn(global.io(), .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = if (opts.verbose) .inherit else .ignore,
    }) catch |err| {
        log.warn("persist install spawn failed: {}", .{err});
        return error.InstallFailed;
    };

    if (child.stdin) |stdin| {
        stdin.writeStreamingAll(global.io(), persist_install_script) catch {};
        stdin.close(global.io());
        child.stdin = null;
    }

    const term = child.wait(global.io()) catch |err| {
        log.warn("persist install wait failed: {}", .{err});
        return error.InstallFailed;
    };
    switch (term) {
        .exited => |rc| if (rc == 3) return error.NoTmux,
        else => {},
    }
    checkExit(term, "persist install") catch return error.InstallFailed;
}

/// Run the session in tmux on the remote, reconnecting to the same tmux
/// session whenever the connection drops, until tmux exits or detaches.
fn runPersistent(
    alloc: Allocator,
    opts: *const Options,
    stderr: *std.Io.Writer,
    prefix: []const []const u8,
    dest: []const u8,
) !u8 {
    const io = global.io();

    // Identifies this terminal to the remote across reconnects.
    var tag_bytes: [12]u8 = undefined;
    io.random(&tag_bytes);
    const tag = std.fmt.bytesToHex(tag_bytes, .lower);

    // ssh runs LocalCommand only once the connection is up, so this marker
    // tells a dropped session apart from one that never connected (unknown
    // host, failed auth, ...), which we must not retry.
    const marker = try internal_os.randomTmpPath(alloc, "ghostty-ssh-");
    defer std.Io.Dir.cwd().deleteFile(io, marker) catch {};
    const local_command = try std.fmt.allocPrint(
        alloc,
        "LocalCommand=touch '{s}'",
        .{marker},
    );

    // Run via `sh -c` so it works whatever the remote login shell is.
    const remote_command = try std.fmt.allocPrint(
        alloc,
        "sh -c 'exec \"$HOME/{s}\" attach {s}'",
        .{ persist_remote_path, &tag },
    );

    // The keepalives notice a dead connection within seconds (e.g. after
    // waking from sleep) rather than waiting on TCP timeouts.
    const argv = try std.mem.concat(alloc, []const u8, &.{
        prefix,
        &.{"-t"},
        &.{
            "-o", "ServerAliveInterval=2",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=5",
            "-o", "PermitLocalCommand=yes",
            "-o", local_command,
        },
        opts._ssh_args.items,
        &.{remote_command},
    });
    verbosePrint(opts, stderr, "exec: {f}", .{Joined{ .items = argv }});

    var stdout_buffer: [256]u8 = undefined;
    var stdout_file: std.Io.File = .stdout();
    var stdout_writer = stdout_file.writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var connected = false;
    var dropped_at: i64 = 0;
    while (true) {
        std.Io.Dir.cwd().deleteFile(io, marker) catch {};
        const exit_code = try childExecFiltered(argv, stderr, connected);
        if (std.Io.Dir.cwd().access(io, marker, .{})) |_| {
            connected = true;
            dropped_at = std.Io.Timestamp.now(io, .real).toSeconds();
        } else |_| {}

        // ssh exits with 255 when the connection fails or drops. Anything
        // else means tmux exited or was detached, so we're done.
        if (exit_code != 255 or !connected) return exit_code;

        const elapsed = std.Io.Timestamp.now(io, .real).toSeconds() - dropped_at;
        verbosePrint(opts, stderr, "persist: connection lost, reconnecting ({d}s)", .{elapsed});

        // Keep the screen untouched; tmux redraws it once we're back.
        stdout.print("\x1b]2;{s} (reconnecting, {d}s)\x07", .{ dest, elapsed }) catch {};
        stdout.flush() catch {};
        try std.Io.sleep(io, .fromSeconds(1), .awake);
    }
}

/// Like `childExec`, but with ssh's stderr passed through `isSshNoise`.
fn childExecFiltered(
    argv: []const []const u8,
    stderr: *std.Io.Writer,
    reconnecting: bool,
) !u8 {
    const io = global.io();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .pipe,
    });

    if (child.stderr) |pipe| {
        var buffer: [4096]u8 = undefined;
        var reader = pipe.reader(io, &buffer);
        const r = &reader.interface;
        while (true) {
            const line = r.takeDelimiter('\n') catch |err| switch (err) {
                // A line longer than our buffer can't be noise; pass it on.
                error.StreamTooLong => {
                    stderr.writeAll(r.buffered()) catch {};
                    r.toss(r.buffered().len);
                    continue;
                },
                error.ReadFailed => break,
            } orelse break;
            if (isSshNoise(line, reconnecting)) continue;
            stderr.writeAll(line) catch {};
            stderr.writeByte('\n') catch {};
            stderr.flush() catch {};
        }
        pipe.close(io);
        child.stderr = null;
    }

    const term = try child.wait(io);
    return switch (term) {
        .exited => |rc| rc,
        .signal => |sig| @as(u8, 128) + @as(u8, @intCast(@min(@intFromEnum(sig), 127))),
        .stopped, .unknown => 1,
    };
}

/// Whether a line ssh printed to stderr is noise in a persistent session.
/// Messages about the connection dropping always are: tmux redraws the
/// screen once we reconnect, so they'd only flash over it. While
/// `reconnecting`, so are the errors from attempts that fail while the
/// network comes back. Anything else (banners, auth errors, ...) is shown.
fn isSshNoise(line: []const u8, reconnecting: bool) bool {
    const l = std.mem.trimEnd(u8, line, "\r");
    if (std.mem.startsWith(u8, l, "Connection to ") and
        std.mem.indexOf(u8, l, " closed") != null) return true;

    const dropped = [_][]const u8{
        "client_loop: ",
        "Timeout, server ",
        "Shared connection to ",
    };
    for (dropped) |prefix| {
        if (std.mem.startsWith(u8, l, prefix)) return true;
    }
    if (!reconnecting) return false;

    const failed = [_][]const u8{
        "ssh: connect to host ",
        "ssh: Could not resolve hostname ",
        "kex_exchange_identification: ",
        "Connection closed by ",
        "Connection reset by ",
        "Connection timed out during banner exchange",
    };
    for (failed) |prefix| {
        if (std.mem.startsWith(u8, l, prefix)) return true;
    }
    return false;
}

/// Whether ssh `args` (everything after `ssh`) ask for an interactive login:
/// a destination and no remote command, without flags that make the session
/// non-interactive (`-N`, `-T`, `-n`, `-f`, `-s`, `-W`) or that don't
/// connect at all (`-G`, `-V`, `-O`, `-Q`).
fn isInteractiveLogin(args: []const []const u8) bool {
    // ssh flags that take a value, either attached (`-p22`) or as the next
    // argument (`-p 22`).
    const with_value = "BbcDEeFIiJLlmOoPpQRSWw";
    const not_interactive = "fGNnsTVWOQ";

    var dest = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            const rest = args.len - i - 1;
            return if (dest) rest == 0 else rest == 1;
        }

        // ssh keeps parsing options after the destination; the first
        // non-option after it starts the remote command.
        if (arg.len < 2 or arg[0] != '-') {
            if (dest) return false;
            dest = true;
            continue;
        }

        for (arg[1..], 1..) |c, j| {
            if (std.mem.indexOfScalar(u8, not_interactive, c) != null) return false;
            if (std.mem.indexOfScalar(u8, with_value, c) != null) {
                if (j == arg.len - 1) i += 1;
                break;
            }
        }
    }
    return dest;
}

/// Whether the effective ssh configuration (`ssh -G` output) leaves us free
/// to run our own remote command in a tty.
fn configAllowsPersist(config: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, config, '\n');
    while (it.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const key = line[0..space];
        const value = std.mem.trimEnd(u8, line[space + 1 ..], "\r");
        const conflicts = (std.mem.eql(u8, key, "remotecommand") and
            !std.mem.eql(u8, value, "none")) or
            (std.mem.eql(u8, key, "requesttty") and std.mem.eql(u8, value, "no")) or
            (std.mem.eql(u8, key, "sessiontype") and !std.mem.eql(u8, value, "default")) or
            (std.mem.eql(u8, key, "stdinnull") and std.mem.eql(u8, value, "yes")) or
            (std.mem.eql(u8, key, "forkafterauthentication") and std.mem.eql(u8, value, "yes"));
        if (conflicts) return false;
    }
    return true;
}

/// Returns `128 + signum` for signal-killed children, matching shell convention.
fn childExec(argv: []const []const u8) !u8 {
    var child = try std.process.spawn(global.io(), .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });

    const term = try child.wait(global.io());
    return switch (term) {
        .exited => |rc| rc,
        .signal => |sig| @as(u8, 128) + @as(u8, @intCast(@min(@intFromEnum(sig), 127))),
        .stopped, .unknown => 1,
    };
}

fn parseTestArgs(alloc: Allocator, opts: *Options, line: []const u8) !void {
    var iter = try std.process.Args.IteratorGeneral(.{}).init(alloc, line);
    defer iter.deinit();
    try cli_args.parse(Options, alloc, opts, &iter);
}

test "parseManuallyHook: bare destination starts ssh args" {
    const testing = std.testing;
    var opts: Options = .{};
    defer opts.deinit();
    try parseTestArgs(testing.allocator, &opts, "--terminfo=false user@example.com");
    try testing.expectEqual(false, opts.terminfo);
    try testing.expectEqual(true, opts.@"forward-env");
    try testing.expectEqual(@as(usize, 1), opts._ssh_args.items.len);
    try testing.expectEqualStrings("user@example.com", opts._ssh_args.items[0]);
}

test "parseManuallyHook: short ssh flags pass through verbatim" {
    const testing = std.testing;
    var opts: Options = .{};
    defer opts.deinit();
    try parseTestArgs(testing.allocator, &opts, "-p 2222 user@example.com");
    try testing.expectEqual(@as(usize, 3), opts._ssh_args.items.len);
    try testing.expectEqualStrings("-p", opts._ssh_args.items[0]);
    try testing.expectEqualStrings("2222", opts._ssh_args.items[1]);
    try testing.expectEqualStrings("user@example.com", opts._ssh_args.items[2]);
}

test "parseManuallyHook: explicit -- separator" {
    const testing = std.testing;
    var opts: Options = .{};
    defer opts.deinit();
    try parseTestArgs(
        testing.allocator,
        &opts,
        "--verbose -- --some-rare-ssh-arg user@example.com",
    );
    try testing.expectEqual(true, opts.verbose);
    try testing.expectEqual(@as(usize, 2), opts._ssh_args.items.len);
    try testing.expectEqualStrings("--some-rare-ssh-arg", opts._ssh_args.items[0]);
    try testing.expectEqualStrings("user@example.com", opts._ssh_args.items[1]);
}

test "parseDestination: typical ssh -G output" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout =
        \\user alice
        \\hostname example.com
        \\port 22
        \\identityfile ~/.ssh/id_ed25519
        \\
    ;
    const result = parseDestination(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@example.com", result.?);
}

test "parseDestination: hostname before user" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout =
        \\hostname example.com
        \\port 22
        \\user alice
        \\
    ;
    const result = parseDestination(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@example.com", result.?);
}

test "parseDestination: missing hostname returns null" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "user alice\nport 22\n";
    try testing.expectEqual(@as(?[]const u8, null), parseDestination(arena.allocator(), stdout));
}

test "parseDestination: missing user returns null" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "hostname example.com\nport 22\n";
    try testing.expectEqual(@as(?[]const u8, null), parseDestination(arena.allocator(), stdout));
}

test "parseDestination: empty input returns null" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(?[]const u8, null), parseDestination(arena.allocator(), ""));
}

test "parseDestination: IPv6 hostname" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "user alice\nhostname ::1\n";
    const result = parseDestination(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@::1", result.?);
}

test "parseDestination: non-default port" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout =
        \\user alice
        \\hostname example.com
        \\port 2222
        \\
    ;
    const result = parseDestination(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@example.com:2222", result.?);
}

test "parseDestination: port before hostname" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "port 2222\nuser alice\nhostname example.com\n";
    const result = parseDestination(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@example.com:2222", result.?);
}

test "parseDestination: IPv6 hostname with non-default port" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "user alice\nhostname ::1\nport 2222\n";
    const result = parseDestination(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@[::1]:2222", result.?);
}

test "parseDestination: result is a valid cache key" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const outputs = [_][]const u8{
        "user alice\nhostname example.com\nport 22\n",
        "user alice\nhostname example.com\nport 2222\n",
        "user alice\nhostname 2001:db8::1\nport 22\n",
        "user alice\nhostname 2001:db8::1\nport 2222\n",
    };
    for (outputs) |stdout| {
        const result = parseDestination(arena.allocator(), stdout).?;
        try testing.expect(DiskCache.isValidCacheKey(result));
    }
}

test "isInteractiveLogin" {
    const testing = std.testing;
    const yes = [_][]const []const u8{
        &.{"host"},
        &.{ "user@host", "-t" },
        &.{ "-p", "2222", "host" },
        &.{ "-p2222", "-i", "~/.ssh/id", "host" },
        &.{ "-v", "-A", "host" },
        &.{ "host", "-p", "22" },
        &.{ "-o", "ServerAliveInterval=5", "host" },
        &.{ "--", "host" },
        &.{ "-tt", "host" },
    };
    for (yes) |args| try testing.expect(isInteractiveLogin(args));

    const no = [_][]const []const u8{
        &.{},
        &.{"-v"},
        &.{ "host", "ls" },
        &.{ "host", "-p", "22", "ls", "-la" },
        &.{ "-p", "2222" },
        &.{ "-N", "-L", "8080:localhost:80", "host" },
        &.{ "-T", "host" },
        &.{ "-n", "host" },
        &.{ "-fN", "host" },
        &.{ "-G", "host" },
        &.{ "-W", "localhost:22", "host" },
        &.{ "-O", "check", "host" },
        &.{ "-s", "host", "sftp" },
        &.{ "--", "host", "ls" },
        &.{ "host", "--", "ls" },
    };
    for (no) |args| try testing.expect(!isInteractiveLogin(args));
}

test "configAllowsPersist" {
    const testing = std.testing;
    try testing.expect(configAllowsPersist(
        "user alice\nhostname example.com\nrequesttty auto\nsessiontype default\n",
    ));
    try testing.expect(configAllowsPersist("remotecommand none\n"));
    try testing.expect(configAllowsPersist("requesttty force\n"));
    try testing.expect(!configAllowsPersist("remotecommand tmux attach\n"));
    try testing.expect(!configAllowsPersist("requesttty no\n"));
    try testing.expect(!configAllowsPersist("sessiontype none\n"));
    try testing.expect(!configAllowsPersist("stdinnull yes\n"));
    try testing.expect(!configAllowsPersist("forkafterauthentication yes\n"));
}

test "isSshNoise" {
    const testing = std.testing;
    try testing.expect(isSshNoise("Connection to example.com closed.\r", false));
    try testing.expect(isSshNoise("Connection to example.com closed by remote host.", false));
    try testing.expect(isSshNoise("client_loop: send disconnect: Broken pipe", false));
    try testing.expect(isSshNoise("Timeout, server example.com not responding.", false));

    // Connection errors only count once we're reconnecting.
    const refused = "ssh: connect to host example.com port 22: Connection refused";
    try testing.expect(!isSshNoise(refused, false));
    try testing.expect(isSshNoise(refused, true));
    const unresolved = "ssh: Could not resolve hostname example.com: Name or service not known";
    try testing.expect(!isSshNoise(unresolved, false));
    try testing.expect(isSshNoise(unresolved, true));

    // Banners and auth failures always show.
    try testing.expect(!isSshNoise("To authenticate, visit: https://example.com/a/1", true));
    try testing.expect(!isSshNoise("alice@example.com: Permission denied (publickey).", true));
}

test "persist_install_script embeds the helper" {
    const testing = std.testing;
    try testing.expect(std.mem.indexOf(u8, persist_install_script, persist_script) != null);
    try testing.expect(std.mem.indexOf(u8, persist_script, "__GHOSTTY_SSH_PERSIST__") == null);
    try testing.expect(std.mem.endsWith(u8, persist_script, "\n"));
}

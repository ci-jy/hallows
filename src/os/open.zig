const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.@"os-open");

/// Open a URL in the default handling application.
///
/// Any output on stderr is logged as a warning in the application logs.
/// Output on stdout is ignored.
///
/// This function is purposely simple for the sake of providing some portable
/// way to open URLs. If you are implementing an apprt for Ghostty, you should
/// consider doing something special-cased for your platform.
pub fn open(
    kind: apprt.action.OpenUrl.Kind,
    url: []const u8,
) !void {
    // The apprt handles OSC 8 targets before this fallback. Ghostty's
    // native apprt applies its allowlist, confirmation, and file safety policy.
    // If a macOS embedder declines the action, fail closed rather than bypassing
    // that policy by handing producer-controlled terminal output to `open`.
    if (kind == .osc8) return error.UnsafeOSC8Link;

    var spawn_opts: std.process.SpawnOptions = switch (kind) {
        .text => .{ .argv = &.{ "open", "-t", url } },
        .html, .unknown => .{ .argv = &.{ "open", url } },
        .osc8 => unreachable,
    };
    // Ignore anything from stdout. This must be set before spawning the
    // process.
    spawn_opts.stdout = .ignore;
    // Pipe stderr so we can log the stderr from the command. This must be set
    // before spawning the process.
    spawn_opts.stderr = .pipe;

    const exe = try std.process.spawn(global.io(), spawn_opts);

    const thread = try std.Thread.spawn(.{}, openThread, .{ global.io(), exe });
    thread.detach();
}

test "macOS OSC 8 links have no generic opener fallback" {
    try std.testing.expectError(
        error.UnsafeOSC8Link,
        open(.osc8, "file:///tmp/payload.command"),
    );
}

fn openThread(io: std.Io, exe_: std.process.Child) void {
    // Copy the exe so it is non-const. This is necessary because wait()
    // requires a mutable reference and we can't have one as a thread
    // param.
    var exe = exe_;
    if (exe.stderr) |stderr| {
        var buffer: [256]u8 = undefined;
        var stream = stderr.readerStreaming(io, &buffer);
        const reader = &stream.interface;
        while (true) {
            // Read inclusively so the delimiter is consumed:
            // takeDelimiterExclusive leaves the '\n' buffered, so once the
            // child writes a line this loop would receive an empty slice
            // forever, pinning a core and spamming empty warnings.
            const line = reader.takeDelimiterInclusive('\n') catch |outer| switch (outer) {
                error.EndOfStream => break,
                error.ReadFailed => break,
                error.StreamTooLong => reader.take(buffer.len) catch |inner| switch (inner) {
                    error.ReadFailed => break,
                    error.EndOfStream => break,
                },
            };
            log.warn("open stderr={s}", .{std.mem.trimEnd(u8, line, "\n")});
        }
    }
    _ = exe.wait(io) catch {};
}

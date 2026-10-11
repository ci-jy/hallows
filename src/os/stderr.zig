//! Raw, best-effort stderr writing that bypasses `std.Io` entirely.
//!
//! `std.debug.lockStderr` (and everything layered on top of it) routes
//! through `std.Options.debug_io`, whose default implementation is
//! `std.Io.Threaded`. This keeps ~70KB of unreachable code in binaries.

const std = @import("std");

/// Write bytes to stderr with a raw write syscall. This is best-effort:
/// errors are ignored, since this is only used for diagnostics (logging
/// and panic messages).
pub fn write(bytes: []const u8) void {
    const posix = std.posix;
    var i: usize = 0;
    while (i < bytes.len) {
        const rc = posix.system.write(
            posix.STDERR_FILENO,
            bytes[i..].ptr,
            bytes.len - i,
        );
        switch (posix.errno(rc)) {
            .SUCCESS => i += @as(usize, @intCast(rc)),
            .INTR => continue,
            else => return,
        }
    }
}

test write {
    // Smoke test: must not crash. We can't assert on the output without
    // capturing stderr, which isn't worth the complexity here.
    write("");
}

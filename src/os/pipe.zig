const posix = @import("std").posix;
const compat_fd = @import("../lib/compat/fd.zig");

/// pipe() that sets CLOEXEC on the file descriptors.
pub fn pipe() ![2]posix.fd_t {
    return compat_fd.pipe2(.{ .CLOEXEC = true });
}

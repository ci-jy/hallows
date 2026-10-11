const std = @import("std");
const objc = @import("objc");

const Error = error{
    /// The buffer used for output is not large enough to store the value.
    BufferTooSmall,
};

/// Determine the home directory for the currently executing user. This
/// is generally an expensive process so the value should be cached.
pub inline fn home(io: std.Io, environ_map: *const std.process.Environ.Map, buf: []u8) !?[]const u8 {
    _ = io;
    return try homeMacOS(environ_map, buf);
}

fn homeMacOS(environ_map: *const std.process.Environ.Map, buf: []u8) !?[]const u8 {
    // First: if we have a HOME env var, then we use that.
    if (environ_map.get("HOME")) |result| {
        if (buf.len < result.len) return Error.BufferTooSmall;
        @memcpy(buf[0..result.len], result);
        return buf[0..result.len];
    }

    // [NSFileManager defaultManager].homeDirectoryForCurrentUser.path
    const NSFileManager = objc.getClass("NSFileManager").?;
    const manager = NSFileManager.msgSend(objc.Object, objc.sel("defaultManager"), .{});
    const homeURL = manager.getProperty(objc.Object, "homeDirectoryForCurrentUser");
    const homePath = homeURL.getProperty(objc.Object, "path");

    const c_str = homePath.getProperty([*:0]const u8, "UTF8String");
    const result = std.mem.sliceTo(c_str, 0);

    if (buf.len < result.len) return Error.BufferTooSmall;
    @memcpy(buf[0..result.len], result);
    return buf[0..result.len];
}

pub const ExpandError = error{
    HomeDetectionFailed,
    BufferTooSmall,
};

/// Expands a path that starts with a tilde (~) to the home directory of
/// the current user.
///
/// Errors if `home` fails or if the size of the expanded path is larger
/// than `buf.len`.
pub fn expandHome(
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    buf: []u8,
) ExpandError![]const u8 {
    return try expandHomeUnix(io, environ_map, path, buf);
}

fn expandHomeUnix(
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    path: []const u8,
    buf: []u8,
) ExpandError![]const u8 {
    if (!std.mem.startsWith(u8, path, "~/")) return path;
    const home_dir: []const u8 = if (home(io, environ_map, buf)) |home_|
        home_ orelse return error.HomeDetectionFailed
    else |_|
        return error.HomeDetectionFailed;
    const rest = path[1..]; // Skip the ~
    const expanded_len = home_dir.len + rest.len;

    if (expanded_len > buf.len) return Error.BufferTooSmall;
    @memcpy(buf[home_dir.len..expanded_len], rest);

    return buf[0..expanded_len];
}

test "expandHomeUnix" {
    const testing = std.testing;
    const io = testing.io;
    const allocator = testing.allocator;
    var environ_map = try testing.environ.createMap(testing.allocator);
    defer environ_map.deinit();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_dir = try expandHomeUnix(io, &environ_map, "~/", &buf);
    // Joining the home directory `~` with the path `/`
    // the result should end with a separator here. (e.g. `/home/user/`)
    try testing.expect(home_dir[home_dir.len - 1] == std.fs.path.sep);

    const downloads = try expandHomeUnix(io, &environ_map, "~/Downloads/shader.glsl", &buf);
    const expected_downloads = try std.mem.concat(allocator, u8, &[_][]const u8{ home_dir, "Downloads/shader.glsl" });
    defer allocator.free(expected_downloads);
    try testing.expectEqualStrings(expected_downloads, downloads);

    try testing.expectEqualStrings("~", try expandHomeUnix(io, &environ_map, "~", &buf));
    try testing.expectEqualStrings("~abc/", try expandHomeUnix(io, &environ_map, "~abc/", &buf));
    try testing.expectEqualStrings("/home/user", try expandHomeUnix(io, &environ_map, "/home/user", &buf));
    try testing.expectEqualStrings("", try expandHomeUnix(io, &environ_map, "", &buf));

    // Expect an error if the buffer is large enough to hold the home directory,
    // but not the expanded path
    var small_buf = try allocator.alloc(u8, home_dir.len);
    defer allocator.free(small_buf);
    try testing.expectError(error.BufferTooSmall, expandHomeUnix(
        io,
        &environ_map,
        "~/Downloads",
        small_buf[0..],
    ));
}

test {
    const testing = std.testing;
    const io = testing.io;
    var environ_map = try testing.environ.createMap(testing.allocator);
    defer environ_map.deinit();

    var buf: [1024]u8 = undefined;
    const result = try home(io, &environ_map, &buf);
    try testing.expect(result != null);
    try testing.expect(result.?.len > 0);
}

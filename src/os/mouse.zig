const std = @import("std");
const objc = @import("objc");

const log = std.log.scoped(.os);

/// The system-configured double-click interval if its available.
pub fn clickInterval() ?u32 {
    const NSEvent = objc.getClass("NSEvent") orelse {
        log.err("NSEvent class not found. Can't get click interval.", .{});
        return null;
    };

    // Get the interval and convert to ms
    const interval = NSEvent.msgSend(f64, objc.sel("doubleClickInterval"), .{});
    return @as(u32, @intFromFloat(@ceil(interval * 1000)));
}

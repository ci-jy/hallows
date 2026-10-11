const GhosttyXCFramework = @This();

const std = @import("std");
const SharedDeps = @import("SharedDeps.zig");
const GhosttyLib = @import("GhosttyLib.zig");
const XCFrameworkStep = @import("XCFrameworkStep.zig");

xcframework: *XCFrameworkStep,

pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
) !GhosttyXCFramework {
    const macos_lib = try GhosttyLib.initStatic(b, deps);

    // Generate a headers directory with only ghostty.h and the module map.
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(b.path("include/ghostty.h"), "ghostty.h");
    _ = wf.addCopyFile(b.path("include/module.modulemap"), "module.modulemap");
    const headers = wf.getDirectory();

    // The xcframework wraps our ghostty library so that we can link
    // it to the final app built with Swift.
    const xcframework = XCFrameworkStep.create(b, .{
        .name = "GhosttyKit",
        .out_path = "macos/GhosttyKit.xcframework",
        .libraries = &.{.{
            .library = macos_lib.output,
            .headers = headers,
            .dsym = null,
        }},
    });

    return .{
        .xcframework = xcframework,
    };
}

pub fn install(self: *const GhosttyXCFramework) void {
    const b = self.xcframework.step.owner;
    self.addStepDependencies(b.getInstallStep());
}

pub fn addStepDependencies(
    self: *const GhosttyXCFramework,
    other_step: *std.Build.Step,
) void {
    other_step.dependOn(self.xcframework.step);
}

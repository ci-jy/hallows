//! GhosttyFrameData generates a compressed file and zig module which contains (and exposes) the
//! Ghostty animation frames for use in `ghostty +boo`
const GhosttyFrameData = @This();

const std = @import("std");

/// The output path for the compressed framedata zig file
output: std.Build.LazyPath,

pub fn init(b: *std.Build) !GhosttyFrameData {
    // Generate the Zig source file that embeds the compressed data
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(framedata(b), "framedata.compressed");
    const zig_file = wf.add("framedata.zig",
        \\//! This file is auto-generated. Do not edit.
        \\
        \\pub const compressed = @embedFile("framedata.compressed");
        \\
    );

    return .{ .output = zig_file };
}

/// Add the "framedata" import.
pub fn addImport(self: *const GhosttyFrameData, step: *std.Build.Step.Compile) void {
    self.output.addStepDependencies(&step.step);
    step.root_module.addAnonymousImport("framedata", .{
        .root_source_file = self.output,
    });
}

/// Compresses the animation frames.
fn framedata(b: *std.Build) std.Build.LazyPath {
    const exe = b.addExecutable(.{
        .name = "framegen",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .link_libc = true,
        }),
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/build/framegen/main.c"),
        .flags = &.{},
    });

    if (b.lazyDependency("zlib", .{
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    })) |zlib_dep| {
        exe.root_module.linkLibrary(zlib_dep.artifact("z"));
    }

    const run = b.addRunArtifact(exe);
    run.addDirectoryArg(b.path("src/build/framegen/frames"));
    return run.addOutputFileArg("framedata.compressed");
}

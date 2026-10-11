const GhosttyLib = @This();

const std = @import("std");
const LibsystemOverrideStep = @import("LibsystemOverrideStep.zig");
const LibtoolStep = @import("LibtoolStep.zig");
const SharedDeps = @import("SharedDeps.zig");

/// The step that generates the file.
step: *std.Build.Step,

/// The final static library file
output: std.Build.LazyPath,

/// The static library linked into the macOS app via the xcframework. This
/// is the glue between the Swift app and the Zig core.
pub fn initStatic(
    b: *std.Build,
    deps: *const SharedDeps,
) !GhosttyLib {
    const lib = b.addLibrary(.{
        .name = "ghostty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_c.zig"),
            .target = deps.config.target,
            .optimize = deps.config.optimize,
            .strip = deps.config.strip,
            .omit_frame_pointer = deps.config.omitFramePointer(),
            .unwind_tables = if (deps.config.strip) .none else .sync,
            .link_libc = true,
        }),
        .use_llvm = true,
    });

    // These must be bundled since we're compiling into a static lib.
    // Otherwise, you get undefined symbol errors.
    lib.bundle_compiler_rt = true;
    lib.bundle_ubsan_rt = true;

    // Add our dependencies. Get the list of all static deps so we can
    // build a combined archive.
    var lib_list = try deps.add(lib);
    try lib_list.append(b.allocator, lib.getEmittedBin());

    // Combine all archives into a single fat static library so
    // the app only needs to link one file.
    const combined = LibtoolStep.create(b, .{
        .name = "ghostty-internal",
        .out_name = "libghostty-internal-fat.a",
        .sources = lib_list.items,
    });
    combined.step.dependOn(&lib.step);

    // Prefer libSystem's libc/libm over the bundled compiler-rt for
    // consumers of this archive. See libsystem_override.sh for details.
    const override = LibsystemOverrideStep.create(
        b,
        deps.config.target,
        combined.output,
        "libghostty-internal.a",
    );

    return .{
        .step = override.step orelse combined.step,
        .output = override.output,
    };
}

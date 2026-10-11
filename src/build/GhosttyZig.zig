//! GhosttyZig generates the `ghostty-vt` Zig module: the terminal emulator
//! core without the app around it. hallows-persist is built on it.
const GhosttyZig = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");

vt: *std.Build.Module,

pub fn init(
    b: *std.Build,
    cfg: *const Config,
    deps: *const SharedDeps,
) !GhosttyZig {
    return initInner(b, cfg, deps, "ghostty-vt");
}

/// Create a new GhosttyZig with modules for another operating system, for
/// programs we ship that run elsewhere, such as `hallows-persist` (the
/// remote half of `+ssh --persist`). The module name includes the target,
/// so building for another target doesn't collide with `init`'s module.
pub fn initForOs(
    b: *std.Build,
    cfg: *const Config,
    deps: *const SharedDeps,
    target: std.Build.ResolvedTarget,
) !GhosttyZig {
    const retargeted_config = try b.allocator.create(Config);
    retargeted_config.* = cfg.*;
    retargeted_config.target = target;

    const retargeted_deps = try b.allocator.create(SharedDeps);
    retargeted_deps.* = try deps.retarget(b, target);

    return initInner(
        b,
        retargeted_config,
        retargeted_deps,
        b.fmt("ghostty-vt-{s}-{s}", .{
            @tagName(target.result.cpu.arch),
            @tagName(target.result.os.tag),
        }),
    );
}

fn initInner(
    b: *std.Build,
    cfg: *const Config,
    deps: *const SharedDeps,
    name: []const u8,
) !GhosttyZig {
    // Terminal module build options
    var vt_options = cfg.terminalOptions(.lib, cfg.optimize);
    vt_options.artifact = .lib;
    // We presently don't allow Oniguruma in our Zig module at all.
    vt_options.oniguruma = false;

    // General build options
    const general_options = b.addOptions();
    try cfg.addOptions(general_options);

    const vt = b.addModule(name, .{
        .root_source_file = b.path("src/lib_vt.zig"),
        .target = cfg.target,
        .optimize = cfg.optimize,

        // SIMD requires libc. Vendored C++ dependencies are built with
        // no-libcxx mode (HWY_NO_LIBCXX / SIMDUTF_NO_LIBCXX) so we
        // don't need libcpp.
        .link_libc = if (cfg.simd) true else null,
    });
    vt.addOptions("build_options", general_options);
    vt_options.add(b, vt);

    // We always need unicode tables
    deps.unicode_tables.addModuleImport(vt);

    // We need uucode for grapheme break support
    vt.addImport("uucode", deps.uucode_mod);

    // We need wuffs for Kitty graphics pixel operations (format
    // conversion and alpha blending). Unlike pure Zig dependencies
    // its C code is compiled whenever the module is in the build
    // graph regardless of analysis, so only wire it in when Kitty
    // graphics is actually enabled.
    if (vt_options.features.kitty_graphics) {
        if (b.lazyDependency("wuffs", .{
            .target = cfg.target,
            .optimize = cfg.optimize,
        })) |dep| {
            vt.addImport("wuffs", dep.module("wuffs"));
        }
    }

    // If SIMD is enabled, add all our SIMD dependencies.
    if (cfg.simd) {
        try SharedDeps.addSimd(b, vt, null);
    }

    return .{ .vt = vt };
}

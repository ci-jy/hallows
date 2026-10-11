//! `hallows-persist`, the remote half of `ghostty +ssh --persist` (see
//! src/hallows_persist/main.zig). It runs on the hosts Ghostty connects to, so it's
//! built for each remote platform we support and installed with the other
//! resources as `share/hallows/hallows-persist/<arch>-<os>/hallows-persist`,
//! where `+ssh` finds it to copy to a host.
const HallowsPersist = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const GhosttyZig = @import("GhosttyZig.zig");

/// The remote platforms we build for. Statically linked against musl so a
/// binary runs on any distribution.
pub const targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
};

steps: []*std.Build.Step,

pub fn init(
    b: *std.Build,
    cfg: *const Config,
    deps: *const SharedDeps,
) !HallowsPersist {
    var steps: std.ArrayList(*std.Build.Step) = .empty;
    errdefer steps.deinit(b.allocator);

    // Small binaries copy to hosts faster, and our SIMD dependencies are
    // C++ we'd rather not cross-compile; the daemon doesn't need either.
    const persist_cfg = try b.allocator.create(Config);
    persist_cfg.* = cfg.*;
    persist_cfg.optimize = .ReleaseSmall;
    persist_cfg.simd = false;

    for (targets) |query| {
        const target = b.resolveTargetQuery(query);
        const mod = try GhosttyZig.initForOs(b, persist_cfg, deps, target);
        const exe = b.addExecutable(.{
            .name = "hallows-persist",
            .root_module = createModule(b, target, .ReleaseSmall, mod.vt),
        });
        const install = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt(
                "share/hallows/hallows-persist/{s}-{s}",
                .{ @tagName(query.cpu_arch.?), @tagName(query.os_tag.?) },
            ) } },
        });
        try steps.append(b.allocator, &install.step);
    }

    return .{ .steps = try steps.toOwnedSlice(b.allocator) };
}

/// Unit tests for `hallows-persist`, run on the host.
pub fn addTests(
    b: *std.Build,
    vt: *std.Build.Module,
    test_step: *std.Build.Step,
    filters: []const []const u8,
) void {
    const target = vt.resolved_target orelse b.graph.host;
    const tests = b.addTest(.{
        .name = "hallows-persist-test",
        .filters = filters,
        .root_module = createModule(b, target, .Debug, vt),
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn createModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    vt: *std.Build.Module,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/hallows_persist/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize != .Debug,
    });
    mod.addImport("ghostty-vt", vt);
    return mod;
}

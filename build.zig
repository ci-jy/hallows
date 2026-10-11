const std = @import("std");
const buildpkg = @import("src/build/main.zig");
const translate_c = @import("translate_c");

/// App version from build.zig.zon.
const app_zon_version = @import("build.zig.zon").version;

/// Minimum required zig version.
const minimum_zig_version = @import("build.zig.zon").minimum_zig_version;

comptime {
    buildpkg.requireZig(minimum_zig_version);
}

pub fn build(b: *std.Build) !void {
    // This defines all the available build options (e.g. `-D`). If you
    // want to know what options are available, you can run `--help` or
    // you can read `src/build/Config.zig`.
    const config = try buildpkg.Config.init(b, app_zon_version);
    const test_filters = b.option(
        [][]const u8,
        "test-filter",
        "Filter for test. Only applies to Zig tests.",
    ) orelse &[0][]const u8{};

    // Ghostty dependencies used by many artifacts.
    const deps = try buildpkg.SharedDeps.init(b, &config);

    // The `ghostty-vt` Zig module: the terminal core without the app.
    const mod = try buildpkg.GhosttyZig.init(
        b,
        &config,
        &deps,
    );

    // All our steps which we'll hook up later. The steps are shown
    // up here just so that they are more self-documenting.
    const run_step = b.step("run", "Run the app");
    const test_step = b.step("test", "Run tests");
    const test_vt_step = b.step(
        "test-vt",
        "Run ghostty-vt module tests",
    );

    // Ghostty resources like terminfo, shell integration, etc.
    const resources = try buildpkg.GhosttyResources.init(b, &config, &deps);

    // Ghostty docs
    const docs = try buildpkg.GhosttyDocs.init(b, &deps);
    if (config.emit_docs) {
        docs.install();
    } else {
        // If we aren't emitting docs we need to emit a placeholder so
        // our macOS xcodeproject builds since it expects the `share/man`
        // directory to exist to copy into the app bundle.
        docs.installDummy(b.getInstallStep());
    }

    // Ghostty bench tools
    if (config.emit_bench) {
        const bench = try buildpkg.GhosttyBench.init(b, &deps);
        bench.install();
    }

    // Helpgen
    if (config.emit_helpgen) deps.help_strings.install();

    if (config.emit_xcframework or config.emit_macos_app) {
        // Ghostty xcframework
        const xcframework = try buildpkg.GhosttyXCFramework.init(b, &deps);
        if (config.emit_xcframework) {
            xcframework.install();

            // The xcframework build always installs resources because our
            // macOS xcode project contains references to them.
            resources.install();
        }

        // Ghostty macOS app
        const macos_app = try buildpkg.GhosttyXcodebuild.init(
            b,
            &config,
            .{
                .xcframework = &xcframework,
                .docs = &docs,
                .resources = &resources,
            },
        );
        if (config.emit_macos_app) {
            macos_app.install();
        }

        // Run the macOS app.
        run_step.dependOn(&macos_app.open.step);

        // If we have no test filters, install the tests too
        if (test_filters.len == 0) {
            macos_app.addTestStepDependencies(test_step);
        }
    }

    // ghostty-vt module tests
    {
        const mod_vt_test = b.addTest(.{
            .root_module = mod.vt,
            .filters = test_filters,
        });
        const mod_vt_test_run = b.addRunArtifact(mod_vt_test);
        test_vt_step.dependOn(&mod_vt_test_run.step);
    }

    // hallows-persist (ssh-persist) tests
    buildpkg.HallowsPersist.addTests(
        b,
        mod.vt,
        test_step,
        test_filters,
    );

    // Full unit tests
    {
        const test_exe = b.addTest(.{
            .name = "ghostty-test",
            .filters = test_filters,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = config.baselineTarget(b.graph.io),
                .optimize = .Debug,
                .strip = false,
                .omit_frame_pointer = false,
                .unwind_tables = .sync,
            }),
            .use_llvm = true,
        });
        if (config.emit_test_exe) {
            const test_exe_install = b.addInstallArtifact(test_exe, .{});
            test_step.dependOn(&test_exe_install.step);
        }
        _ = try deps.add(test_exe);

        addGhosttyH(b, test_exe.root_module, config.baselineTarget(b.graph.io), .Debug);

        // Normal test running
        const test_run = b.addRunArtifact(test_exe);
        test_step.dependOn(&test_run.step);
    }
}

fn addGhosttyH(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    translate_c.addImportToModule(b, "ghostty.h", module, .{
        .source = .{ .includes = .{ .files = &.{
            .{ .path = "ghostty.h" },
        } } },
        .target = target,
        .optimize = optimize,
        .system_include_paths = &.{b.path("include")},
    }) catch unreachable;
}

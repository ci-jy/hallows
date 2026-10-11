/// Build configuration. This is the configuration that is populated
/// during `zig build` to control the rest of the build process.
const Config = @This();

const std = @import("std");
const builtin = @import("builtin");

const FontBackend = @import("../font/backend.zig").Backend;
const TerminalBuildOptions = @import("../terminal/build_options.zig").Options;
const expandPath = @import("../os/path.zig").expand;

const GitVersion = @import("GitVersion.zig");

/// Standard build configuration options.
optimize: std.builtin.OptimizeMode,
target: std.Build.ResolvedTarget,

/// Comptime interfaces
font_backend: FontBackend = .coretext,

/// Feature flags
sentry: bool = true,
simd: bool = true,

/// Ghostty exe properties
exe_entrypoint: ExeEntrypoint = .ghostty,
version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },

/// Binary properties
strip: bool = false,

/// Artifacts
emit_bench: bool = false,
emit_docs: bool = false,
emit_helpgen: bool = false,
emit_macos_app: bool = false,
emit_terminfo: bool = false,
emit_termcap: bool = false,
emit_hallows_persist: bool = false,
emit_test_exe: bool = false,
emit_xcframework: bool = false,
emit_unicode_table_gen: bool = false,

/// Environmental properties
env: *const std.process.Environ.Map,

pub fn init(b: *std.Build, appVersion: []const u8) !Config {
    // Setup our standard Zig optimize option, i.e. `-Doptimize`.
    const optimize = b.standardOptimizeOption(.{});

    // Hallows is a macOS app for Apple Silicon and is only built there.
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) {
        std.log.err("Hallows can only be built on an Apple Silicon Mac", .{});
        return error.UnsupportedHost;
    }

    // Grab the environment from build state
    const env = &b.graph.environ_map;

    // We use env vars throughout the build so we grab them immediately here.
    var config: Config = .{
        .optimize = optimize,
        .target = genericMacOSTarget(b),
        .env = env,
    };

    //---------------------------------------------------------------
    // Comptime Interfaces
    config.font_backend = b.option(
        FontBackend,
        "font-backend",
        "The font backend to use for discovery and rasterization.",
    ) orelse .coretext;

    //---------------------------------------------------------------
    // Feature Flags

    config.sentry = b.option(
        bool,
        "sentry",
        "Build with Sentry crash reporting.",
    ) orelse true;

    config.simd = b.option(
        bool,
        "simd",
        "Build with SIMD-accelerated code paths. Results in significant performance improvements.",
    ) orelse true;

    //---------------------------------------------------------------
    // Ghostty Exe Properties

    const version_string = b.option(
        []const u8,
        "version-string",
        "A specific version string to use for the build. " ++
            "If not specified, git will be used. This must be a semantic version.",
    );

    config.version = if (version_string) |v|
        // If an explicit version is given, we always use it.
        try std.SemanticVersion.parse(v)
    else version: {
        const app_version = try std.SemanticVersion.parse(appVersion);

        // If no explicit version is given, we try to detect it from git.
        const vsn = GitVersion.detect(b) catch |err| switch (err) {
            // If Git isn't available we just make an unknown dev version.
            error.GitNotFound,
            error.GitNotRepository,
            => break :version .{
                .major = app_version.major,
                .minor = app_version.minor,
                .patch = app_version.patch,
                .pre = "dev",
                .build = "0000000",
            },

            else => return err,
        };
        if (vsn.tag) |tag| {
            // Tip releases behave just like any other pre-release so we skip.
            if (!std.mem.eql(u8, tag, "tip")) {
                const expected = b.fmt("v{d}.{d}.{d}", .{
                    app_version.major,
                    app_version.minor,
                    app_version.patch,
                });

                if (!std.mem.eql(u8, tag, expected)) {
                    @panic("tagged releases must be in vX.Y.Z format matching build.zig");
                }

                break :version .{
                    .major = app_version.major,
                    .minor = app_version.minor,
                    .patch = app_version.patch,
                };
            }
        }

        break :version .{
            .major = app_version.major,
            .minor = app_version.minor,
            .patch = app_version.patch,
            .pre = vsn.branch,
            .build = vsn.short_hash,
        };
    };

    config.strip = b.option(
        bool,
        "strip",
        "Strip the final executable. Default true for fast and small releases",
    ) orelse switch (optimize) {
        .Debug => false,
        .ReleaseSafe => false,
        .ReleaseFast, .ReleaseSmall => true,
    };

    //---------------------------------------------------------------
    // Artifacts to Emit

    config.emit_test_exe = b.option(
        bool,
        "emit-test-exe",
        "Build and install test executables with 'build'",
    ) orelse false;

    config.emit_unicode_table_gen = b.option(
        bool,
        "emit-unicode-table-gen",
        "Build and install executables that generate unicode tables with 'build'",
    ) orelse false;

    config.emit_bench = b.option(
        bool,
        "emit-bench",
        "Build and install the benchmark executables.",
    ) orelse false;

    config.emit_helpgen = b.option(
        bool,
        "emit-helpgen",
        "Build and install the helpgen executable.",
    ) orelse false;

    config.emit_docs = b.option(
        bool,
        "emit-docs",
        "Build and install auto-generated documentation (requires pandoc)",
    ) orelse emit_docs: {
        // If we are emitting any other artifacts then we default to false.
        if (config.emit_bench or
            config.emit_test_exe or
            config.emit_helpgen) break :emit_docs false;

        // We only default to true if we can find pandoc.
        const path = expandPath(b.graph.io, b.allocator, &b.graph.environ_map, "pandoc") catch
            break :emit_docs false;
        defer if (path) |p| b.allocator.free(p);
        break :emit_docs path != null;
    };

    config.emit_terminfo = b.option(
        bool,
        "emit-terminfo",
        "Install Ghostty terminfo source file",
    ) orelse switch (optimize) {
        .Debug => true,
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => false,
    };

    config.emit_termcap = b.option(
        bool,
        "emit-termcap",
        "Install Ghostty termcap file",
    ) orelse switch (optimize) {
        .Debug => true,
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => false,
    };

    config.emit_hallows_persist = b.option(
        bool,
        "emit-hallows-persist",
        "Build and install hallows-persist, the remote half of the ssh-persist shell integration feature, for the remote platforms it supports",
    ) orelse true;

    config.emit_xcframework = b.option(
        bool,
        "emit-xcframework",
        "Build and install the xcframework for the macOS library.",
    ) orelse (!config.emit_bench and
        !config.emit_test_exe and
        !config.emit_helpgen);

    config.emit_macos_app = b.option(
        bool,
        "emit-macos-app",
        "Build and install the macOS app bundle.",
    ) orelse config.emit_xcframework;

    return config;
}

/// Configure the build options with our values.
pub fn addOptions(self: *const Config, step: *std.Build.Step.Options) !void {
    // We need to break these down individual because addOption doesn't
    // support all types.
    step.addOption(bool, "sentry", self.sentry);
    step.addOption(bool, "simd", self.simd);
    step.addOption(FontBackend, "font_backend", self.font_backend);
    step.addOption(ExeEntrypoint, "exe_entrypoint", self.exe_entrypoint);

    // Our version. We also add the string version so we don't need
    // to do any allocations at runtime. This has to be long enough to
    // accommodate realistic large branch names for dev versions.
    var app_version_buf: [1024]u8 = undefined;
    step.addOption(std.SemanticVersion, "app_version", self.version);
    step.addOption([:0]const u8, "app_version_string", try std.fmt.bufPrintZ(
        &app_version_buf,
        "{f}",
        .{self.version},
    ));
    step.addOption(
        ReleaseChannel,
        "release_channel",
        channel: {
            const pre = self.version.pre orelse break :channel .stable;
            if (pre.len == 0) break :channel .stable;
            break :channel .tip;
        },
    );
}

/// Returns the build options for the terminal module. This assumes a
/// Ghostty executable being built. Callers should modify this as needed.
pub fn terminalOptions(
    self: *const Config,
    artifact: TerminalBuildOptions.Artifact,
    optimize: std.builtin.OptimizeMode,
) TerminalBuildOptions {
    return .{
        .artifact = artifact,
        .simd = self.simd,
        .oniguruma = true,
        .version = self.version,
        .slow_runtime_safety = switch (optimize) {
            .Debug => true,
            .ReleaseSafe,
            .ReleaseSmall,
            .ReleaseFast,
            => false,
        },
    };
}

/// Returns a baseline CPU target retaining all the other CPU configs.
pub fn baselineTarget(self: *const Config, io: std.Io) std.Build.ResolvedTarget {
    // Set our cpu model as baseline. There may need to be other modifications
    // we need to make such as resetting CPU features but for now this works.
    var q = self.target.query;
    q.cpu_model = .baseline;

    // Same logic as build.resolveTargetQuery but we don't need to
    // handle the native case.
    return .{
        .query = q,
        .result = std.zig.system.resolveTargetQuery(io, q) catch
            @panic("unable to resolve baseline query"),
    };
}

/// Rehydrate our Config from the comptime options. Note that not all
/// options are available at comptime, so look closely at this implementation
/// to see what is and isn't available.
pub fn fromOptions() Config {
    const options = @import("build_options");
    return .{
        // Unused at runtime.
        .optimize = undefined,
        .target = undefined,
        .env = undefined,

        .version = options.app_version,
        .font_backend = std.meta.stringToEnum(FontBackend, @tagName(options.font_backend)).?,
        .exe_entrypoint = std.meta.stringToEnum(ExeEntrypoint, @tagName(options.exe_entrypoint)).?,
    };
}

/// Whether release artifacts should omit frame pointers.
///
/// Always false: the Apple arm64 ABI expects x29 to be a valid frame
/// pointer and Apple's profiling and crash reporting tools rely on it
/// for backtraces.
pub fn omitFramePointer(self: *const Config) bool {
    _ = self;
    return false;
}

/// The minimum macOS version. We support back to the earliest officially
/// supported version of macOS by Apple. EOL versions are not supported.
pub const macos_version_min: std.Target.Query.OsVersion = .{ .semver = .{
    .major = 13,
    .minor = 0,
    .patch = 0,
} };

// Returns a ResolvedTarget for an Apple Silicon Mac with a
// `target.result.cpu.model.name` of `generic`. `b.standardTargetOptions()`
// returns a more specific cpu like `apple_a15`.
//
// This is used to workaround compilation issues on macOS.
// (see for example https://github.com/mitchellh/ghostty/issues/1640).
pub fn genericMacOSTarget(b: *std.Build) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .os_version_min = macos_version_min,
    });
}

/// The possible entrypoints for the exe artifact. This has no effect on
/// other artifact types (i.e. lib).
///
/// The whole existence of this enum is to workaround the fact that Zig
/// doesn't allow the main function to be in a file in a subdirctory
/// from the "root" of the module, and I don't want to pollute our root
/// directory with a bunch of individual zig files for each entrypoint.
///
/// Therefore, main.zig uses this to switch between the different entrypoints.
pub const ExeEntrypoint = enum {
    ghostty,
    helpgen,
    mdgen_ghostty_1,
    mdgen_ghostty_5,
};

/// The release channel for the build.
pub const ReleaseChannel = enum {
    /// Unstable builds on every commit.
    tip,

    /// Stable tagged releases.
    stable,
};

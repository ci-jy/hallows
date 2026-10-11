const HwyTargets = @import("targets.zig").Targets;

const aarch64_darwin = @import("detect/aarch64_darwin.zig");

/// Detect Highway targets at runtime using minimal, direct CPU feature
/// probing.
///
/// Previous versions called std.zig.system.resolveTargetQuery which
/// drags in the full Zig target/CPU model tables for every architecture,
/// bloating the binary by ~300 KB and causing code-layout regressions in
/// unrelated hot paths (icache / branch-predictor pressure).
///
/// This version uses only sysctlbyname, so it adds no data tables and no
/// std.Target dependency. Hallows only runs on Apple Silicon Macs.
pub export fn ghostty_hwy_detect_targets() callconv(.c) i64 {
    var t: HwyTargets = .{};

    // All AArch64 implementations have NEON.
    t.neon_without_aes = true;

    return aarch64_darwin.detect(&t);
}

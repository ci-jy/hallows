const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "breakpad",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
        }),
        .linkage = .static,
    });
    lib.root_module.addIncludePath(b.path("vendor"));
    if (target.result.os.tag.isDarwin()) {
        const apple_sdk = @import("apple_sdk");
        try apple_sdk.addPaths(b, lib);
    }

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);

    if (b.lazyDependency("breakpad", .{})) |upstream| {
        lib.root_module.addIncludePath(upstream.path("src"));
        lib.root_module.addCSourceFiles(.{
            .root = upstream.path(""),
            .files = common,
            .flags = flags.items,
        });

        if (target.result.os.tag.isDarwin()) {
            lib.root_module.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = common_apple,
                .flags = flags.items,
            });
            lib.root_module.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = client_apple,
                .flags = flags.items,
            });

            switch (target.result.os.tag) {
                .macos => {
                    lib.root_module.addCSourceFiles(.{
                        .root = upstream.path(""),
                        .files = common_mac,
                        .flags = flags.items,
                    });
                    lib.root_module.addCSourceFiles(.{
                        .root = upstream.path(""),
                        .files = client_mac,
                        .flags = flags.items,
                    });
                },

                else => {},
            }
        }

        lib.installHeadersDirectory(
            upstream.path("src"),
            "",
            .{ .include_extensions = &.{".h"} },
        );
    }

    b.installArtifact(lib);
}

const common: []const []const u8 = &.{
    "src/common/convert_UTF.cc",
    "src/common/md5.cc",
    "src/common/string_conversion.cc",
};

const common_apple: []const []const u8 = &.{
    "src/common/mac/arch_utilities.cc",
    "src/common/mac/file_id.cc",
    "src/common/mac/macho_id.cc",
    "src/common/mac/macho_utilities.cc",
    "src/common/mac/macho_walker.cc",
    "src/common/mac/string_utilities.cc",
};

const common_mac: []const []const u8 = &.{
    "src/common/mac/MachIPC.mm",
    "src/common/mac/bootstrap_compat.cc",
};

const client_apple: []const []const u8 = &.{
    "src/client/minidump_file_writer.cc",
    "src/client/mac/handler/breakpad_nlist_64.cc",
    "src/client/mac/handler/dynamic_images.cc",
    "src/client/mac/handler/minidump_generator.cc",
};

const client_mac: []const []const u8 = &.{
    "src/client/mac/handler/exception_handler.cc",
    "src/client/mac/crash_generation/crash_generation_client.cc",
};

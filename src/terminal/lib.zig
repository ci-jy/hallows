const std = @import("std");
const lib = @import("../lib/main.zig");

/// The target for the terminal lib in particular.
pub const target: lib.Target = .zig;

/// Forwarded decls from lib that are used.
pub const Buffer = lib.Buffer;
pub const Enum = lib.Enum;
pub const parseInt = lib.parseInt;
pub const TaggedUnion = lib.TaggedUnion;
pub const Struct = lib.Struct;
pub const String = lib.String;
pub const checkGhosttyHEnum = lib.checkGhosttyHEnum;
pub const structSizedFieldFits = lib.structSizedFieldFits;

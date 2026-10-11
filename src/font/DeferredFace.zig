//! A deferred face represents a single font face with all the information
//! necessary to load it, but defers loading the full face until it is
//! needed.
//!
//! This allows us to have many fallback fonts to look for glyphs, but
//! only load them if they're really needed.
const DeferredFace = @This();

const std = @import("std");
const macos = @import("macos");
const font = @import("main.zig");
const options = @import("main.zig").options;
const Library = @import("main.zig").Library;
const Face = @import("main.zig").Face;
const Presentation = @import("main.zig").Presentation;

const log = std.log.scoped(.deferred_face);

/// CoreText
ct: ?CoreText = null,

/// CoreText specific data.
pub const CoreText = struct {
    /// The initialized font
    font: *macos.text.Font,

    /// Variations to apply to this font. We apply the variations to the
    /// search descriptor but sometimes when the font collection is
    /// made the variation axes are reset so we have to reapply them.
    variations: []const font.face.Variation,

    pub fn deinit(self: *CoreText) void {
        self.font.release();
        self.* = undefined;
    }
};

pub fn deinit(self: *DeferredFace) void {
    if (self.ct) |*ct| ct.deinit();
    self.* = undefined;
}

/// Returns the family name of the font.
pub fn familyName(self: DeferredFace, buf: []u8) ![]const u8 {
    if (self.ct) |ct| {
        const family_name = ct.font.copyAttribute(.family_name) orelse
            return "unknown";
        return family_name.cstringPtr(.utf8) orelse unsupported: {
            break :unsupported family_name.cstring(buf, .utf8) orelse
                return error.OutOfMemory;
        };
    }

    return "";
}

/// Returns the name of this face. The memory is always owned by the
/// face so it doesn't have to be freed.
pub fn name(self: DeferredFace, buf: []u8) ![]const u8 {
    if (self.ct) |ct| {
        const display_name = ct.font.copyDisplayName() orelse
            return self.familyName(buf);
        return display_name.cstringPtr(.utf8) orelse unsupported: {
            // "NULL if the internal storage of theString does not allow
            // this to be returned efficiently." In this case, we need
            // to allocate. But we can't return an allocated string because
            // we don't have an allocator. Let's use the stack and log it.
            break :unsupported display_name.cstring(buf, .utf8) orelse
                return error.OutOfMemory;
        };
    }

    return "";
}

/// Load the deferred font face. This does nothing if the face is loaded.
pub fn load(
    self: *DeferredFace,
    lib: Library,
    opts: font.face.Options,
) !Face {
    return switch (options.backend) {
        .coretext, .coretext_harfbuzz, .coretext_noshape => try self.loadCoreText(lib, opts),
        .coretext_freetype => try self.loadCoreTextFreetype(lib, opts),
    };
}

fn loadCoreText(
    self: *DeferredFace,
    lib: Library,
    opts: font.face.Options,
) !Face {
    _ = lib;
    const ct = self.ct.?;
    var face = try Face.initFontCopy(ct.font, opts);
    errdefer face.deinit();
    try face.setVariations(ct.variations, opts);
    return face;
}

fn loadCoreTextFreetype(
    self: *DeferredFace,
    lib: Library,
    opts: font.face.Options,
) !Face {
    const ct = self.ct.?;

    // Get the URL for the font so we can get the filepath
    const url = ct.font.copyAttribute(.url) orelse
        return error.FontHasNoFile;
    defer url.release();

    // Get the path from the URL
    const path = url.copyPath() orelse return error.FontHasNoFile;
    defer path.release();

    // URL decode the path
    const blank = try macos.foundation.String.createWithBytes("", .utf8, false);
    defer blank.release();
    const decoded = try macos.foundation.URL.createStringByReplacingPercentEscapes(
        path,
        blank,
    );
    defer decoded.release();

    // Decode into a c string. 1024 bytes should be enough for anybody.
    var buf: [1024]u8 = undefined;
    const path_slice = decoded.cstring(buf[0..1023], .utf8) orelse
        return error.FontPathCantDecode;

    // Freetype requires null-terminated. We always leave space at
    // the end for a zero so we set that up here.
    buf[path_slice.len] = 0;

    // Face index 0 is not always correct. We don't ship this configuration
    // in a release build. Users should use the pure CoreText builds.
    //std.log.warn("path={s}", .{path_slice});
    var face = try Face.initFile(lib, buf[0..path_slice.len :0], 0, opts);
    errdefer face.deinit();
    try face.setVariations(ct.variations, opts);

    return face;
}

/// Returns true if this face can satisfy the given codepoint and
/// presentation. If presentation is null, then it just checks if the
/// codepoint is present at all.
///
/// This doesn't require the face to be loaded.
pub fn hasCodepoint(self: DeferredFace, cp: u32, p: ?Presentation) bool {
    // We check the loaded CT font. Discovery always provides one.
    const ct = self.ct.?;

    // This presentation check isn't as detailed as isColorGlyph
    // because forced presentation modes are only used for emoji and
    // emoji should always have color glyphs set. This can be
    // more correct by using the isColorGlyph logic but I'd want
    // to find a font that actually requires this so we can write
    // a test for it before changing it.
    if (p) |desired_p| {
        const traits = ct.font.getSymbolicTraits();
        const actual_p: Presentation = if (traits.color_glyphs) .emoji else .text;
        if (actual_p != desired_p) return false;
    }

    // Turn UTF-32 into UTF-16 for CT API
    var unichars: [2]u16 = undefined;
    const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(cp, &unichars);
    const len: usize = if (pair) 2 else 1;

    // Get our glyphs
    var glyphs = [2]macos.graphics.Glyph{ 0, 0 };
    return ct.font.getGlyphsForCharacters(unichars[0..len], glyphs[0..len]);
}

test "coretext" {
    if (options.backend != .coretext) return error.SkipZigTest;

    const discovery = @import("main.zig").discovery;
    const testing = std.testing;
    const alloc = testing.allocator;

    // Load freetype
    var lib = try Library.init(alloc);
    defer lib.deinit();

    // Get a deferred face from CoreText
    var def = def: {
        var fc = discovery.CoreText.init(lib);
        var it = try fc.discover(alloc, .{ .family = "Monaco", .size = 12 });
        defer it.deinit();
        break :def (try it.next()).?;
    };
    defer def.deinit();
    try testing.expect(def.hasCodepoint(' ', null));

    // Verify we can get the name
    var buf: [1024]u8 = undefined;
    const n = try def.name(&buf);
    try testing.expect(n.len > 0);

    // Load it and verify it works
    var face = try def.load(lib, .{ .size = .{ .points = 12 } });
    defer face.deinit();
    try testing.expect(face.glyphIndex(' ') != null);
}

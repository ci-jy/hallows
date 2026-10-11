//! Locale helpers backed by libintl. Hallows isn't translated, but macOS
//! reports the user's preferred languages in BCP-47 format and we need
//! POSIX locale names for LANG.
const std = @import("std");

/// Canonicalize a locale name from a platform-specific value to
/// a POSIX-compliant value. This is a thin layer over the unexported
/// gnulib-lib function in gettext that does this already.
///
/// The gnulib-lib function modifies the buffer in place but has
/// zero bounds checking, so we do a bit extra to ensure we don't
/// overflow the buffer. This is likely slightly more expensive but
/// this isn't a hot path so it should be fine.
///
/// The buffer must be at least 16 bytes long. This ensures we can
/// fit the longest possible hardcoded locale name. Additionally,
/// it should be at least as long as locale in case the locale
/// is unchanged.
///
/// Here is the logic for macOS:
///
/// https://github.com/coreutils/gnulib/blob/5b92dd0a45c8d27f13a21076b57095ea5e220870/lib/localename.c#L1171
pub fn canonicalizeLocale(
    buf: []u8,
    locale: []const u8,
) error{NoSpaceLeft}![:0]const u8 {
    // Fix zh locales for macOS
    if (fixZhLocale(locale)) |fixed| {
        if (buf.len < fixed.len + 1) return error.NoSpaceLeft;
        @memcpy(buf[0..fixed.len], fixed);
        buf[fixed.len] = 0;
        return buf[0..fixed.len :0];
    }

    // Buffer must be 16 or at least as long as the locale and null term
    if (buf.len < @max(16, locale.len + 1)) return error.NoSpaceLeft;

    // Copy our locale into the buffer since it modifies in place.
    // This must be null-terminated.
    @memcpy(buf[0..locale.len], locale);
    buf[locale.len] = 0;

    _libintl_locale_name_canonicalize(buf[0..locale.len :0]);

    // Convert the null-terminated result buffer into a slice. We
    // need to search for the null terminator and slice it back.
    // We have to use `buf` since `slice` len will exclude the
    // null.
    const slice = std.mem.sliceTo(buf, 0);
    return buf[0..slice.len :0];
}

/// Handles some zh locales canonicalization because internal libintl
/// canonicalization function doesn't handle correctly in these cases.
fn fixZhLocale(locale: []const u8) ?[:0]const u8 {
    var it = std.mem.splitScalar(u8, locale, '-');
    const name = it.next() orelse return null;
    if (!std.mem.eql(u8, name, "zh")) return null;

    const script = it.next() orelse return null;
    const region = it.next() orelse return null;

    if (std.mem.eql(u8, script, "Hans")) {
        if (std.mem.eql(u8, region, "SG")) return "zh_SG";
        return "zh_CN";
    }

    if (std.mem.eql(u8, script, "Hant")) {
        if (std.mem.eql(u8, region, "MO")) return "zh_MO";
        if (std.mem.eql(u8, region, "HK")) return "zh_HK";
        return "zh_TW";
    }

    return null;
}

// This is only available if we're building libintl from source
// since its otherwise not exported.
extern fn _libintl_locale_name_canonicalize(name: [*:0]u8) void;

test "canonicalizeLocale" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("en_US", try canonicalizeLocale(&buf, "en_US"));
    try testing.expectEqualStrings("zh_CN", try canonicalizeLocale(&buf, "zh-Hans"));
    try testing.expectEqualStrings("zh_TW", try canonicalizeLocale(&buf, "zh-Hant"));

    try testing.expectEqualStrings("zh_CN", try canonicalizeLocale(&buf, "zh-Hans-CN"));
    try testing.expectEqualStrings("zh_SG", try canonicalizeLocale(&buf, "zh-Hans-SG"));
    try testing.expectEqualStrings("zh_TW", try canonicalizeLocale(&buf, "zh-Hant-TW"));
    try testing.expectEqualStrings("zh_HK", try canonicalizeLocale(&buf, "zh-Hant-HK"));
    try testing.expectEqualStrings("zh_MO", try canonicalizeLocale(&buf, "zh-Hant-MO"));

    // This is just an edge case I want to make sure we're aware of:
    // canonicalizeLocale does not handle encodings and will turn them into
    // underscores. We should parse them out before calling this function.
    try testing.expectEqualStrings("en_US.UTF_8", try canonicalizeLocale(&buf, "en_US.UTF-8"));
}

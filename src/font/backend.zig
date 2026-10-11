/// Backend for fonts that determines how fonts are loaded, rendered,
/// and shaped. Discovery always uses CoreText.
pub const Backend = enum {
    /// CoreText for font discovery, rendering, and shaping. The default.
    coretext,

    /// CoreText for font discovery, FreeType for rendering, and
    /// HarfBuzz for shaping. For people who want to self-compile Hallows
    /// and prefer the FreeType aesthetic.
    coretext_freetype,

    /// CoreText for font discovery and rendering, HarfBuzz for shaping
    coretext_harfbuzz,

    /// CoreText for font discovery and rendering, no shaping.
    coretext_noshape,

    // All the functions below can be called at comptime or runtime to
    // determine if we have a certain dependency.

    pub fn hasFreetype(self: Backend) bool {
        return switch (self) {
            .coretext_freetype => true,

            .coretext,
            .coretext_harfbuzz,
            .coretext_noshape,
            => false,
        };
    }

    pub fn hasHarfbuzz(self: Backend) bool {
        return switch (self) {
            .coretext_freetype,
            .coretext_harfbuzz,
            => true,

            .coretext,
            .coretext_noshape,
            => false,
        };
    }
};

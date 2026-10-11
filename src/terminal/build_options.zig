const std = @import("std");

/// Options set by Zig build.zig and exposed via `terminal_options`.
pub const Options = struct {
    pub const Artifact = enum {
        /// Ghostty application
        ghostty,

        /// The `ghostty-vt` Zig module, used by hallows-persist
        lib,
    };

    /// The target artifact to build. This will gate some functionality.
    artifact: Artifact,

    /// Whether Oniguruma regex support is available. If this isn't
    /// available, some features will be disabled. This may be outdated,
    /// but the specific disabled features are:
    ///
    /// - Kitty graphics protocol
    /// - Tmux control mode
    ///
    oniguruma: bool,

    /// Whether to build SIMD-accelerated code paths. This pulls in more
    /// build-time dependencies and adds libc as a runtime dependency,
    /// but results in significant performance improvements.
    simd: bool,

    /// True if we should enable the "slow" runtime safety checks. These
    /// are runtime safety checks that are slower than typical and should
    /// generally be disabled in production builds.
    slow_runtime_safety: bool,

    /// Optional feature gates, all enabled by default. See Features.
    features: Features = .{},

    /// The version of the application.
    version: std.SemanticVersion,

    /// Optional features, all enabled by default. Disabling a feature
    /// removes its stream-integrated handling from the build. Fields are
    /// emitted verbatim as bool options on the `terminal_options` module.
    pub const Features = packed struct {
        /// Terminal state serialization: encode a full terminal (screen
        /// contents, scrollback, cursor, styles, modes, etc.) to a
        /// compact binary format and decode it back into a live
        /// terminal. Used for session persistence, window restoration,
        /// and moving terminal state between processes.
        snapshot: bool = true,

        /// Textual export of terminal contents as plain text, VT
        /// (replayable escape sequences), or HTML, with optional extras
        /// such as cursor position, palette, modes, and tabstops. Used
        /// for copy-to-clipboard, dump-to-file, and debugging.
        formatter: bool = true,

        /// Text selection: select word/line/output/all, selection
        /// ordering, adjustment, and containment math, and the
        /// click/drag gesture state machine (single/double/triple
        /// click behaviors). Selections are expressed in grid
        /// references, so enabling this also keeps the untracked grid
        /// reference constructors even if `grid_introspection` is
        /// disabled.
        selection: bool = true,

        /// Terminal search: find matches for a string in the active
        /// area and scrollback (ASCII case-insensitive), with results
        /// that survive primary/alternate screen switches, resize, and
        /// scrollback pruning, plus match selection with wrap-around
        /// and viewport scrolling. Used to implement find bars.
        search: bool = true,

        /// The render state API: a coherent, update-in-place view of
        /// the visible screen (rows, cells, styles, cursor, colors,
        /// palette) designed to drive a renderer at frame rates. This
        /// is the primary read path for embedders that draw the
        /// terminal.
        render_state: bool = true,

        /// Encoding of host input events into the byte sequences a
        /// terminal application expects: keyboard input (including the
        /// Kitty keyboard protocol), mouse reporting, focus reporting,
        /// and (bracketed) paste. Any interactive embedder needs this;
        /// a read-only viewer does not.
        input_encode: bool = true,

        /// Color utilities: luminance, perceived luminance, and
        /// contrast math (e.g. for minimum-contrast rendering), color
        /// string parsing (`#rrggbb`, X11 color names, XParseColor
        /// `rgb:`/`rgbi:` device specs), the default 256-color palette
        /// and palette generation from configurable bases, and the X11
        /// color name table itself.
        color: bool = true,

        /// Direct inspection of grid contents at a position via grid
        /// references: cell and row data getters (codepoints,
        /// graphemes, style, hyperlink URI, wrap state, ...) plus
        /// tracked grid references that stay valid across terminal
        /// updates. Used for hyperlink hover/open, accessibility, and
        /// tests; deliberately not built for render loops (use
        /// `render_state` for that).
        grid_introspection: bool = true,

        /// The APC glyph protocol: a Ghostty extension that lets
        /// terminal applications register custom font glyphs (glyf
        /// outlines) for private-use-area codepoints. Embedders that
        /// don't render registered glyphs can disable this; the
        /// sequences are still consumed and safely ignored.
        ///
        /// This gates the stream handling and glossary storage.
        glyph_protocol: bool = true,

        /// The Kitty graphics protocol: APC command parsing, image
        /// transmission and storage (PNG decoding via the sys
        /// interface), and placement tracking, plus the read APIs a
        /// renderer uses to draw placed images. Disabled sequences are
        /// still consumed and safely ignored.
        kitty_graphics: bool = true,
    };

    /// Add the required build options for the terminal module.
    ///
    /// The memory referenced by self is expected to stick around (it isn't
    /// copied), since we expect we're in a build environment.
    pub fn add(
        self: Options,
        b: *std.Build,
        m: *std.Build.Module,
    ) void {
        const opts = b.addOptions();
        opts.addOption(Artifact, "artifact", self.artifact);
        opts.addOption(bool, "oniguruma", self.oniguruma);
        opts.addOption(bool, "simd", self.simd);
        opts.addOption(bool, "slow_runtime_safety", self.slow_runtime_safety);

        // These are synthesized based on other options.
        opts.addOption(bool, "tmux_control_mode", self.oniguruma);

        // Feature gates, emitted as flat bools (e.g. `options.snapshot`).
        inline for (@typeInfo(Features).@"struct".fields) |field| {
            opts.addOption(bool, field.name, @field(self.features, field.name));
        }

        // Version information.
        opts.addOption(
            []const u8,
            "version_string",
            b.fmt(
                "{f}",
                .{self.version},
            ),
        );
        opts.addOption(usize, "version_major", self.version.major);
        opts.addOption(usize, "version_minor", self.version.minor);
        opts.addOption(usize, "version_patch", self.version.patch);
        opts.addOption(?[]const u8, "version_pre", self.version.pre);
        opts.addOption(?[]const u8, "version_build", self.version.build);

        m.addOptions("terminal_options", opts);
    }
};


import SwiftUI

/// Metrics shared by the terminal pane cards and everything laid out around them.
enum TerminalPane {
    /// The space between cards, and between the cards and the window edges.
    static let spacing: CGFloat = 7

    static let cornerRadius: CGFloat = 12

    static let headerHeight: CGFloat = 30

    /// Cards narrower than this leave out the header buttons, which wouldn't fit.
    static let minWidthForHeaderButtons: CGFloat = 190

    /// How far the terminal surface sits in from the card's sides and bottom.
    static let contentInset: CGFloat = 6

    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    /// The size of a card holding a surface of the given size.
    static func cardSize(forSurface size: NSSize) -> NSSize {
        NSSize(
            width: size.width + contentInset * 2,
            height: size.height + headerHeight + contentInset)
    }

    /// The size of a window's content holding a single card with a surface of the given size.
    static func windowContentSize(forSurface size: NSSize) -> NSSize {
        let card = cardSize(forSurface: size)
        return NSSize(width: card.width + spacing * 2, height: card.height + spacing * 2)
    }
}

/// A terminal pane drawn as a rounded card with a header: the program's
/// status and title, and buttons to split, zoom and close the pane. The
/// header is also the handle for dragging the pane to another spot.
struct TerminalPaneCard<Content: View>: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView

    /// True if the pane is one of several in a split tree.
    let isSplit: Bool

    /// True if the pane is zoomed to fill the tab.
    let isZoomed: Bool

    /// The card's width.
    let width: CGFloat

    @ViewBuilder let content: Content

    @Environment(\.ghosttyLastFocusedSurface) private var lastFocusedSurface

    @State private var isHovering = false

    private var isFocused: Bool {
        lastFocusedSurface?.value === surfaceView
    }

    /// The same color the surface paints its own background with, so the card
    /// and the terminal inside it read as one.
    private var fill: Color {
        (surfaceView.backgroundColor ?? surfaceView.derivedConfig.backgroundColor)
            .opacity(surfaceView.derivedConfig.backgroundOpacity)
    }

    var body: some View {
        VStack(spacing: 0) {
            TerminalPaneHeader(
                surfaceView: surfaceView,
                isFocused: isFocused,
                showsButtons: (isFocused || isHovering) && width >= TerminalPane.minWidthForHeaderButtons,
                canZoom: isSplit || isZoomed,
                isZoomed: isZoomed)

            content
                .environment(\.ghosttySurfaceHasPaneHeader, true)
                .padding([.horizontal, .bottom], TerminalPane.contentInset)
        }
        .background {
            ZStack {
                TerminalPaneGlass(tint: surfaceView.backgroundColor ?? surfaceView.derivedConfig.backgroundColor)

                // The surface draws its own background, so the card leaves a hole
                // for it. Otherwise a translucent background would be doubled up.
                PaneCardFrameShape()
                    .fill(fill, style: FillStyle(eoFill: true))
            }
        }
        .overlay { TerminalPaneBorder(isFocused: isFocused) }
        .terminalPaneCardBounds()
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }

}

/// The Liquid Glass a card is made of, behind its translucent background.
/// Before macOS 26, a blurred material stands in for it.
struct TerminalPaneGlass: View {
    /// The terminal background, which tints the glass so it keeps its warmth.
    let tint: Color

    var body: some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular.tint(tint.opacity(0.5)), in: TerminalPane.shape)
        } else {
            TerminalPane.shape.fill(.ultraThinMaterial)
        }
#else
        TerminalPane.shape.fill(.ultraThinMaterial)
#endif
    }
}

/// The edge of a card: a dark line outside a light hairline that is brighter
/// at the top, so the card looks lit from above.
struct TerminalPaneBorder: View {
    var isFocused: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        let top = dark ? (isFocused ? 0.2 : 0.13) : 0.8
        let bottom = dark ? 0.04 : 0.3

        ZStack {
            RoundedRectangle(cornerRadius: TerminalPane.cornerRadius + 0.5, style: .continuous)
                .stroke(Color.black.opacity(dark ? 0.55 : (isFocused ? 0.2 : 0.12)), lineWidth: 1)
                .padding(-0.5)

            TerminalPane.shape
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(top), .white.opacity(bottom)],
                        startPoint: .top,
                        endPoint: .bottom),
                    lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// The card's rounded rectangle with the surface's rectangle cut out of it.
private struct PaneCardFrameShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: TerminalPane.cornerRadius, style: .continuous)
        let inset = TerminalPane.contentInset
        path.addRect(CGRect(
            x: rect.minX + inset,
            y: rect.minY + TerminalPane.headerHeight,
            width: max(0, rect.width - inset * 2),
            height: max(0, rect.height - TerminalPane.headerHeight - inset)))
        return path
    }
}

private struct TerminalPaneHeader: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    let isFocused: Bool
    let showsButtons: Bool
    let canZoom: Bool
    let isZoomed: Bool

    @State private var isDragging = false
    @State private var isHoveringHandle = false

    private var title: String {
        surfaceView.title.isEmpty ? "Terminal" : surfaceView.title
    }

    var body: some View {
        HStack(spacing: 7) {
            statusIcon
                .frame(width: 16, height: 16)

            Group {
                Text(verbatim: title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isFocused ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let status = surfaceView.programStatus, status.state != .idle, !status.label.isEmpty {
                    Text(verbatim: status.progress.map { "\(status.label) \($0)%" } ?? status.label)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 160, alignment: .leading)
                }
            }
            .allowsHitTesting(false)

            Spacer(minLength: 8)

            if showsButtons {
                buttons
                    .transition(.opacity)
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 7)
        .frame(height: TerminalPane.headerHeight)
        .background {
            // Clicking the header focuses the pane, double-clicking zooms it, and
            // dragging it moves the pane.
            Ghostty.SurfaceDragSource(
                surfaceView: surfaceView,
                isDragging: $isDragging,
                isHovering: $isHoveringHandle)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: title))
    }

    @ViewBuilder
    private var statusIcon: some View {
        if let status = surfaceView.programStatus, status.state != .idle {
            Group {
                if status.state == .working {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: status.symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(status.color)
                }
            }
            .help(Text(verbatim: status.description))
            .accessibilityLabel(Text(verbatim: status.description))
        } else {
            Image(systemName: TerminalPaneProgram.symbol(for: surfaceView))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isFocused ? .primary : .secondary)
        }
    }

    private var buttons: some View {
        HStack(spacing: 2) {
            TerminalPaneHeaderButton(symbol: "square.split.2x1", help: "Split Right") {
                perform("new_split:right")
            }
            TerminalPaneHeaderButton(symbol: "square.split.1x2", help: "Split Down") {
                perform("new_split:down")
            }
            if canZoom {
                TerminalPaneHeaderButton(
                    symbol: isZoomed
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    help: isZoomed ? "Unzoom Pane" : "Zoom Pane"
                ) {
                    perform("toggle_split_zoom")
                }
            }
            TerminalPaneHeaderButton(symbol: "xmark", help: "Close Pane") {
                perform("close_surface")
            }
        }
    }

    private func perform(_ action: String) {
        _ = surfaceView.surfaceModel?.perform(action: action)
    }
}

/// The kind of program running in a pane, shown as the icon in its header.
enum TerminalPaneProgram {
    /// The SF Symbol for the program in the surface's foreground.
    @MainActor
    static func symbol(for surfaceView: Ghostty.SurfaceView) -> String {
        let name = surfaceView.surfaceModel?.foregroundPID.flatMap(processName(of:)) ?? ""
        return symbol(forProcess: name, title: surfaceView.title)
    }

    static func symbol(forProcess process: String, title: String) -> String {
        let name = (process.hasPrefix("-") ? String(process.dropFirst()) : process).lowercased()
        switch name {
        case "claude", "codex", "gemini", "aider", "opencode", "copilot", "cursor-agent", "amp", "goose":
            return "sparkle"
        case "node", "bun", "deno", "npm", "npx", "pnpm", "yarn", "bunx":
            return "hexagon"
        case "git", "lazygit", "tig", "gitui", "gh":
            return "arrow.triangle.branch"
        case "vim", "nvim", "vi", "nano", "emacs", "hx", "helix", "micro", "kak", "pico":
            return "pencil.line"
        case "ssh", "mosh", "mosh-client", "et":
            return "network"
        case "top", "htop", "btop", "btm", "glances":
            return "gauge.with.dots.needle.33percent"
        case "python", "python3", "ipython", "ruby", "irb", "lua", "ghci", "julia", "r":
            return "curlybraces"
        case "make", "cargo", "go", "swift", "zig", "xcodebuild", "cmake", "ninja", "gradle", "mvn":
            return "hammer"
        case "docker", "podman", "kubectl", "k9s":
            return "shippingbox"
        case "psql", "mysql", "sqlite3", "redis-cli", "mongosh":
            return "cylinder"
        case "man", "less", "more", "bat":
            return "book"
        default:
            break
        }

        // Some programs rename their process, e.g. Claude Code to its version.
        let lowercasedTitle = title.lowercased()
        if lowercasedTitle.contains("claude") || lowercasedTitle.contains("codex") {
            return "sparkle"
        }
        return "apple.terminal"
    }

    private static func processName(of pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(Int32(pid), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}

/// A small icon button for a card's header.
struct TerminalPaneHeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering ? .primary : .secondary)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.1 : 0)))
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The bounds of every card, so the window chrome can leave holes for them.
struct TerminalPaneCardBoundsKey: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] = []

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Marks this view as a card for ``TerminalPaneChrome``.
    func terminalPaneCardBounds() -> some View {
        anchorPreference(key: TerminalPaneCardBoundsKey.self, value: .bounds) { [$0] }
    }
}

/// The window around the panes: a shade darker than the terminal background.
///
/// It leaves holes where the cards are. With a translucent background, the
/// cards would otherwise stack their own translucent background on top of
/// the chrome's and come out nearly opaque, instead of showing the desktop
/// through like the window around them.
struct TerminalPaneChrome: View {
    let surfaceView: Ghostty.SurfaceView?
    let config: Ghostty.Config
    let cards: [CGRect]

    var body: some View {
        if config.backgroundBlur.isGlassStyle {
            // The window's glass is already tinted with the chrome shade.
            Color.clear
        } else if let surfaceView {
            SurfaceChrome(surfaceView: surfaceView, cards: cards)
        } else {
            ChromeShape(cards: cards)
                .fill(
                    Color(nsColor: NSColor(config.backgroundColor)
                        .withAlphaComponent(config.backgroundOpacity).paneChromeColor),
                    style: FillStyle(eoFill: true))
        }
    }

    private struct SurfaceChrome: View {
        @ObservedObject var surfaceView: Ghostty.SurfaceView
        let cards: [CGRect]

        var body: some View {
            let background = surfaceView.backgroundColor ?? surfaceView.derivedConfig.backgroundColor
            ChromeShape(cards: cards)
                .fill(
                    Color(nsColor: NSColor(background)
                        .withAlphaComponent(surfaceView.derivedConfig.backgroundOpacity).paneChromeColor),
                    style: FillStyle(eoFill: true))
        }
    }

    private struct ChromeShape: Shape {
        let cards: [CGRect]

        func path(in rect: CGRect) -> Path {
            var path = Path(rect)
            for card in cards {
                path.addRoundedRect(
                    in: card,
                    cornerSize: CGSize(width: TerminalPane.cornerRadius, height: TerminalPane.cornerRadius),
                    style: .continuous)
            }
            return path
        }
    }
}

extension SplitTree where ViewType == Ghostty.SurfaceView {
    /// The surface whose background color the window around the tree takes: the
    /// focused surface if it borders the top, otherwise the top-left one.
    func backgroundSurface(focused: Ghostty.SurfaceView?) -> Ghostty.SurfaceView? {
        guard let root else { return nil }
        if let focused,
           let focusedNode = root.node(view: focused),
           root.spatial().doesBorder(side: .up, from: focusedNode) {
            return focused
        }
        return root.leftmostLeaf()
    }
}

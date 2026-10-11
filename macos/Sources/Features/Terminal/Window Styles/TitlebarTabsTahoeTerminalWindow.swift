import AppKit
import Combine
import IOKit
import SwiftUI

/// `macos-titlebar-style = tabs` for macOS 26 (Tahoe) and later.
///
/// This inherits from transparent styling so that the titlebar matches the background color
/// of the window.
class TitlebarTabsTahoeTerminalWindow: TransparentTitlebarTerminalWindow, NSToolbarDelegate {
    /// The view model for SwiftUI views
    private var viewModel = ViewModel()

    /// Titlebar tabs can't support the update accessory because of the way we layout
    /// the native tabs back into the menu bar.
    override var supportsUpdateAccessory: Bool { false }

    deinit {
        tabBarObserver = nil
    }

    // MARK: NSWindow

    override var titlebarFont: NSFont? {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.viewModel.titleFont = self.titlebarFont
            }
        }
    }

    override var title: String {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.viewModel.title = self.title
            }
        }
    }

    override func awakeFromNib() {
        super.awakeFromNib()

        // We must hide the title since we're going to be moving tabs into
        // the titlebar which have their own title.
        titleVisibility = .hidden

        // Create a toolbar
        let toolbar = NSToolbar(identifier: "TerminalToolbar")
        toolbar.delegate = self
        toolbar.centeredItemIdentifiers.insert(.title)
        self.toolbar = toolbar
        toolbarStyle = .unifiedCompact
    }
    // Called after new tab finishes adjusting and setupTabBar is called in order to prevent Tab Bar hiding/size bug that occurs with some interactions with Mac UI
    override func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        super.syncAppearance(surfaceConfig)
        DispatchQueue.main.async {
            // HACK: wait a tick before doing anything, to avoid edge cases during startup... :/
            // If we don't do this then on launch windows with restored state with tabs will end
            // up with messed up tab bars that don't show all tabs.
            self.setupTabBar()
            self.installTitlebarAccessories()
        }
    }

    override func becomeMain() {
        super.becomeMain()

        // Check if we have a tab bar and set it up if we have to. See the comment
        // on this function to learn why we need to check this here.
        setupTabBar()
        installTitlebarAccessories()
        machineModel.follow((windowController as? BaseTerminalController)?.focusedSurface)

        viewModel.isMainWindow = true
    }

    override func resignMain() {
        super.resignMain()

        viewModel.isMainWindow = false
    }
    // This is called by macOS for native tabbing in order to add the tab bar. We hook into
    // this, detect the tab bar being added, and override its behavior.
    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        // If this is the tab bar then we need to set it up for the titlebar
        guard isTabBar(childViewController) else {
            // After dragging a tab into a new window, `hasTabBar` needs to be
            // updated to properly review window title
            viewModel.hasTabBar = false

            super.addTitlebarAccessoryViewController(childViewController)
            return
        }

        // When an existing tab is being dragged in to another tab group,
        // system will also try to add tab bar to this window, so we want to reset observer,
        // to put tab bar where we want again
        tabBarObserver = nil

        // Some setup needs to happen BEFORE it is added, such as layout. If
        // we don't do this before the call below, we'll trigger an AppKit
        // assertion.
        childViewController.layoutAttribute = .right

        super.addTitlebarAccessoryViewController(childViewController)

        // Setup the tab bar to go into the titlebar.
        DispatchQueue.main.async {
            // HACK: wait a tick before doing anything, to avoid edge cases during startup... :/
            // If we don't do this then on launch windows with restored state with tabs will end
            // up with messed up tab bars that don't show all tabs.
            self.setupTabBar()
        }
    }

    override func removeTitlebarAccessoryViewController(at index: Int) {
        guard let childViewController = titlebarAccessoryViewControllers[safe: index],
                isTabBar(childViewController) else {
            super.removeTitlebarAccessoryViewController(at: index)
            return
        }

        super.removeTitlebarAccessoryViewController(at: index)

        removeTabBar()
    }

    // MARK: Tab Bar Setup

    private var tabBarObserver: NSObjectProtocol? {
        didSet {
            // When we change this we want to clear our old observer
            guard let oldValue else { return }
            NotificationCenter.default.removeObserver(oldValue)
        }
    }

    /// Take the NSTabBar that is on the window and convert it into titlebar tabs.
    ///
    /// Let me explain more background on what is happening here. When a tab bar is created, only the
    /// main window actually has an NSTabBar. When an NSWindow in the tab group gains main, AppKit
    /// creates/moves (unsure which) the NSTabBar for it and shows it. When it loses main, the tab bar
    /// is removed from the view hierarchy.
    ///
    /// We can't reliably detect this via `addTitlebarAccessoryViewController` because AppKit
    /// creates an accessory view controller for every window in the tab group, but only attaches
    /// the actual NSTabBar to the main window's accessory view.
    ///
    /// The best way I've found to detect this is to search for and setup the tab bar anytime the
    /// window gains focus. There are probably edge cases to check but to resolve all this I made
    /// this function which is idempotent to call.
    ///
    /// There are more scenarios to look out for and they're documented within the method.
    func setupTabBar() {
        // We only want to setup the observer once
        guard tabBarObserver == nil else { return }

        guard
            let titlebarView,
            let tabBarView = self.tabBarView
        else { return }

        // View model updates must happen on their own ticks.
        DispatchQueue.main.async { [weak self] in
            self?.viewModel.hasTabBar = true
        }

        // Find our clip view
        // macOS 26: NSTitlebarAccessoryClipView
        // macOS 27(beta 2): NSTitlebarAccessoryContainerView
        guard let clipView = tabBarView.firstSuperview(withClassName: "NSTitlebarAccessoryClipView") ?? tabBarView.firstSuperview(withClassName: "NSTitlebarAccessoryContainerView") else { return }
        guard let accessoryView = clipView.subviews[safe: 0] else { return }
        guard let toolbarView = titlebarView.firstDescendant(withClassName: "NSToolbarView") else { return }

        // Make sure tabBar's height won't be stretched
        guard let newTabButton = titlebarView.firstDescendant(withClassName: "NSTabBarNewTabButton") else { return }
        tabBarView.frame.size.height = newTabButton.frame.width

        // The container is the view that we'll constrain our tab bar within.
        let container = toolbarView

        // The padding for the tab bar. If we're showing window buttons then
        // we need to offset the window buttons. The machine item sits between
        // the buttons and the tabs, and the command palette button after them.
        let buttonsPadding: CGFloat = switch self.derivedConfig.macosWindowButtons {
        case .hidden: 0
        case .visible: 70
        }
        installTitlebarAccessories()

        // Constrain the accessory clip view (the parent of the accessory view
        // usually that clips the children) to the container view.
        clipView.translatesAutoresizingMaskIntoConstraints = false
        accessoryView.translatesAutoresizingMaskIntoConstraints = false

        // Setup all our constraints
        NSLayoutConstraint.activate([
            // Pinned to the machine item, so the tabs move when its name changes.
            machineView.superview === titlebarView
                ? clipView.leftAnchor.constraint(equalTo: machineView.rightAnchor, constant: 14)
                : clipView.leftAnchor.constraint(equalTo: container.leftAnchor, constant: buttonsPadding),
            commandPaletteButton.superview === titlebarView
                ? clipView.rightAnchor.constraint(equalTo: commandPaletteButton.leftAnchor, constant: -8)
                : clipView.rightAnchor.constraint(equalTo: container.rightAnchor),
            clipView.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            clipView.heightAnchor.constraint(equalTo: container.heightAnchor),
            accessoryView.leftAnchor.constraint(equalTo: clipView.leftAnchor),
            accessoryView.rightAnchor.constraint(equalTo: clipView.rightAnchor),
            accessoryView.topAnchor.constraint(equalTo: clipView.topAnchor),
            accessoryView.heightAnchor.constraint(equalTo: clipView.heightAnchor),
        ])

        clipView.needsLayout = true
        accessoryView.needsLayout = true

        if #available(macOS 27.0, *) {
            // Add some delay to cover the case where:
            // AppKit resets the style after exiting fullscreen
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                self?.reduceTabBarBackgroundGoldenGate()
            }
        }

        // Setup an observer for the NSTabBar frame. When system appearance changes or
        // other events occur, the tab bar can resize and clear our constraints. When this
        // happens, we need to remove our custom constraints and re-apply them once the
        // tab bar has proper dimensions again to avoid constraint conflicts.
        tabBarView.postsFrameChangedNotifications = true
        tabBarObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: tabBarView,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }

            // Remove the observer so we can call setup again.
            self.tabBarObserver = nil

            // Wait a tick to let the new tab bars appear and then set them up.
            DispatchQueue.main.async {
                self.setupTabBar()
            }
        }
    }

    func removeTabBar() {
        // View model needs to be updated on another tick because it
        // triggers view updates.
        DispatchQueue.main.async {
            self.viewModel.hasTabBar = false
        }

        // Clear our observations
        self.tabBarObserver = nil
    }

    // MARK: Titlebar Accessories

    /// The machine the terminals run on, after the window buttons.
    private lazy var machineView: NSView = ClickThroughHostingView(rootView: MachineItem(model: machineModel))

    /// The machine the focused terminal is on.
    private let machineModel = MachineModel()

    override func focusedSurfaceDidChange(_ surface: Ghostty.SurfaceView?) {
        machineModel.follow(surface)
    }

    /// Opens the command palette, at the end of the titlebar.
    private lazy var commandPaletteButton: NSButton = {
        let button = NSButton(
            image: NSImage(systemSymbolName: "command", accessibilityDescription: "Command Palette")!,
            target: nil,
            action: #selector(BaseTerminalController.toggleCommandPalette(_:)))
        button.isBordered = false
        button.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Command Palette"
        return button
    }()

    /// Add the machine item and command palette button to the titlebar. These
    /// aren't toolbar items because the toolbar would move them into its
    /// overflow menu to make room for the title. Safe to call repeatedly.
    private func installTitlebarAccessories() {
        guard let titlebarView,
              let toolbarView = titlebarView.firstDescendant(withClassName: "NSToolbarView")
        else { return }

        // The titlebar view is replaced in fullscreen, so check where we are.
        if machineView.superview === titlebarView { return }
        machineView.removeFromSuperview()
        commandPaletteButton.removeFromSuperview()

        let buttonsPadding: CGFloat = switch derivedConfig.macosWindowButtons {
        case .hidden: 0
        case .visible: 70
        }

        for view in [machineView, commandPaletteButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            titlebarView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            machineView.leftAnchor.constraint(equalTo: titlebarView.leftAnchor, constant: buttonsPadding),
            machineView.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            commandPaletteButton.rightAnchor.constraint(equalTo: titlebarView.rightAnchor, constant: -14),
            commandPaletteButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
        ])
    }

    // MARK: NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.title, .flexibleSpace, .space]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.flexibleSpace, .title, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .title:
            let item = NSToolbarItem(itemIdentifier: .title)
            item.view = ClickThroughHostingView(rootView: TitleItem(viewModel: viewModel))
            // Fix: https://github.com/ghostty-org/ghostty/discussions/9027
            item.view?.setContentCompressionResistancePriority(.required, for: .horizontal)
            item.visibilityPriority = .user
            item.isEnabled = false

            // This is the documented way to avoid the glass view on an item.
            // We don't want glass on our title.
            item.isBordered = false

            return item
        default:
            return NSToolbarItem(itemIdentifier: itemIdentifier)
        }
    }

    // MARK: SwiftUI

    class ViewModel: ObservableObject {
        @Published var titleFont: NSFont?
        @Published var title: String = "👻 Hallows"
        @Published var hasTabBar: Bool = false
        @Published var isMainWindow: Bool = true
    }
}

extension NSToolbarItem.Identifier {
    /// Displays the title of the window
    static let title = NSToolbarItem.Identifier("Title")
}

extension TitlebarTabsTahoeTerminalWindow {
    /// The machine the focused terminal is on: its name over its model.
    struct MachineItem: View {
        @ObservedObject var model: MachineModel

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: model.machine.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: model.machine.name)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(verbatim: model.machine.model)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .frame(maxWidth: 170, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.leading, 6)
            .accessibilityElement(children: .combine)
        }
    }

    /// Tracks which machine the focused terminal is on: this Mac, or the host
    /// it's connected to over ssh.
    @MainActor
    final class MachineModel: ObservableObject {
        @Published private(set) var machine: Machine = .current

        private weak var surface: Ghostty.SurfaceView?
        private var cancellables: Set<AnyCancellable> = []

        func follow(_ surface: Ghostty.SurfaceView?) {
            guard surface !== self.surface else { return }
            self.surface = surface
            cancellables = []
            update()
            guard let surface else { return }

            // Starting or leaving ssh retitles the terminal, which is our cue
            // to look at its foreground process again.
            surface.$title
                .removeDuplicates()
                .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.update() }
                .store(in: &cancellables)
        }

        private func update() {
            let target = surface?.surfaceModel?.foregroundPID
                .flatMap { SSHTarget.find(foregroundProcessGroup: $0) }
            let machine = target.map(Machine.remote) ?? .current
            if machine != self.machine { self.machine = machine }
        }
    }

    /// A machine's name and model.
    struct Machine: Equatable {
        let name: String
        let model: String
        let symbol: String

        /// A host the terminal is connected to over ssh.
        static func remote(_ target: SSHTarget) -> Machine {
            Machine(name: target.displayName, model: "SSH", symbol: "server.rack")
        }

        static let current: Machine = {
            let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            let model = productName() ?? "Mac"
            let symbol = switch model {
            case _ where model.contains("MacBook"): "laptopcomputer"
            case _ where model.contains("Mac mini"): "macmini"
            case _ where model.contains("Mac Studio"): "macstudio"
            case _ where model.contains("Mac Pro"): "macpro.gen3"
            default: "desktopcomputer"
            }
            return Machine(name: name, model: model, symbol: symbol)
        }()

        /// The marketing name of this Mac without the details in parentheses,
        /// e.g. "MacBook Air" for "MacBook Air (15-inch, M3, 2024)".
        private static func productName() -> String? {
            let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
            guard entry != MACH_PORT_NULL else { return nil }
            defer { IOObjectRelease(entry) }
            guard let data = IORegistryEntryCreateCFProperty(
                entry, "product-name" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? Data else { return nil }
            let full = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            let name = full.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) }
            return name?.isEmpty == false ? name : nil
        }
    }
}

extension TitlebarTabsTahoeTerminalWindow {
    /// Displays the window title
    struct TitleItem: View {
        @ObservedObject var viewModel: ViewModel

        var title: String {
            // An empty title makes this view zero-sized and NSToolbar on macOS
            // tahoe just deletes the item when that happens. So we use a space
            // instead to ensure there's always some size.
            return viewModel.title.isEmpty ? " " : viewModel.title
        }

        var body: some View {
            if !viewModel.hasTabBar {
                titleText
            } else {
                // 1x1.gif strikes again! For real: if we render a zero-sized
                // view here then the toolbar just disappears our view. I don't
                // know. On macOS 26.1+ the view no longer disappears, but the
                // toolbar still logs an ambiguous content size warning.
                Color.clear.frame(width: 1, height: 1)
            }
        }

        @ViewBuilder
        var titleText: some View {
            Text(title)
                .font(viewModel.titleFont.flatMap(Font.init(_:)))
                .foregroundStyle(viewModel.isMainWindow ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .greatestFiniteMagnitude, alignment: .center)
                .opacity(viewModel.hasTabBar ? 0 : 1) // hide when in fullscreen mode, where title bar will appear in the leading area under window buttons
        }
    }
}

/// A "Ghosting" Hosting View, that acts like it's not there
private class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The file tree sidebar: a header naming the root (and host), the tree,
/// and a handle on its edge to resize it.
struct FileTreeSidebar: View {
    @ObservedObject var model: FileTreeModel

    /// The card's background color and opacity, the same as the terminal panes'.
    let background: Color
    let backgroundOpacity: Double

    @State private var dragStartWidth: CGFloat?

    private static let widthRange: ClosedRange<CGFloat> = 150...600

    private static let resizeHandleWidth: CGFloat = TerminalPane.spacing + 4

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                // Keep the rows clear of the card's rounded bottom corners.
                .padding(.bottom, TerminalPane.contentInset)
        }
        .frame(width: model.width)
        .background {
            ZStack {
                TerminalPaneGlass(tint: background)
                TerminalPane.shape.fill(background.opacity(backgroundOpacity))
            }
        }
        .clipShape(TerminalPane.shape)
        .overlay { TerminalPaneBorder() }
        .terminalPaneCardBounds()
        // The handle sits over the gap between the sidebar and the panes.
        .overlay(alignment: .trailing) {
            resizeHandle.offset(x: (Self.resizeHandleWidth + TerminalPane.spacing) / 2)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: model.host == nil ? "folder" : "network")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .help(model.host.map { "Files on \($0)" } ?? "")

            VStack(alignment: .leading, spacing: 0) {
                Text(model.root.map { ($0 as NSString).lastPathComponent } ?? "Files")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let host = model.host {
                    Text(host)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .help(model.root.map { root in model.host.map { "\($0):\(root)" } ?? root } ?? "")

            Spacer(minLength: 0)

            TerminalPaneHeaderButton(symbol: "rectangle.compress.vertical", help: "Collapse All") {
                model.collapseAll()
            }

            Menu {
                Toggle("Show Hidden Files", isOn: $model.showHidden)
                Button("Refresh") { model.refresh() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Options")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.leading, 11)
        .padding(.trailing, 7)
        .padding(.vertical, 4)
        .frame(minHeight: TerminalPane.headerHeight)
    }

    @ViewBuilder
    private var content: some View {
        if model.rootNode != nil {
            FileTreeOutline(model: model)
                .overlay(alignment: .bottom) {
                    if let error = model.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .frame(maxWidth: .infinity)
                            .background(.bar)
                    }
                }
        } else if model.isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: model.errorMessage == nil ? "folder" : "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(model.errorMessage ?? "No folder")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if model.errorMessage != nil {
                    Button("Try Again") { model.refresh() }
                        .controlSize(.small)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var resizeHandle: some View {
        Color.clear
            .frame(width: Self.resizeHandleWidth)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? model.width
                        dragStartWidth = start
                        let width = start + value.translation.width
                        model.width = min(max(width, Self.widthRange.lowerBound), Self.widthRange.upperBound)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }
}

// MARK: Outline

/// The tree itself, an NSOutlineView for native keyboard navigation,
/// type-to-select, drag and drop, and context menus.
private struct FileTreeOutline: NSViewRepresentable {
    let model: FileTreeModel

    func makeCoordinator() -> FileTreeOutlineController {
        FileTreeOutlineController(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: FileTreeOutlineController) {
        coordinator.detach()
    }
}

/// An outline view that hands Escape back to the terminal and opens items
/// with Return.
private final class FileTreeOutlineView: NSOutlineView {
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onEscape?()
        case 36, 76: onReturn?()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

@MainActor
private final class FileTreeOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let model: FileTreeModel
    let scrollView = NSScrollView()
    private let outlineView = FileTreeOutlineView()

    /// Set while we expand or collapse items ourselves, so the delegate
    /// callbacks don't echo back into the model.
    private var syncing = false

    init(model: FileTreeModel) {
        self.model = model
        super.init()

        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.backgroundColor = .clear
        outlineView.rowSizeStyle = .small
        outlineView.indentationPerLevel = 12
        outlineView.allowsMultipleSelection = true
        outlineView.autoresizesOutlineColumn = false
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClicked(_:))
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        outlineView.setAccessibilityLabel("File Tree")

        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        outlineView.onEscape = { [weak model] in model?.delegate?.fileTreeFocusTerminal() }
        outlineView.onReturn = { [weak self] in self?.openSelection() }

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        model.onUpdate = { [weak self] update in self?.apply(update) }
        outlineView.reloadData()
        syncExpansion(under: nil)
    }

    func detach() {
        model.onUpdate = nil
    }

    // MARK: Updates

    private func apply(_ update: FileTreeModel.Update) {
        switch update {
        case .reloadAll:
            outlineView.reloadData()
            syncExpansion(under: nil)

        case .reload(let nodes):
            for node in nodes {
                let item: Any? = node === model.rootNode ? nil : node
                guard item == nil || outlineView.row(forItem: item) >= 0 else { continue }
                outlineView.reloadItem(item, reloadChildren: true)
                syncExpansion(under: node === model.rootNode ? nil : node)
            }

        case .redraw:
            let rows = outlineView.rows(in: outlineView.visibleRect)
            guard rows.length > 0 else { return }
            for row in rows.location..<(rows.location + rows.length) {
                guard let view = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileTreeCell,
                      let node = outlineView.item(atRow: row) as? FileTreeNode else { continue }
                view.configure(node, model: model)
            }

        case .collapseAll:
            syncing = true
            outlineView.collapseItem(nil, collapseChildren: true)
            syncing = false

        case .reveal(let node):
            syncExpansion(under: nil)
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return }
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        }
    }

    /// Expand the items the model has expanded.
    private func syncExpansion(under parent: FileTreeNode?) {
        syncing = true
        defer { syncing = false }
        let children = parent?.children ?? (parent == nil ? model.rootNode?.children : nil) ?? []
        for child in children where child.isDirectory && model.isExpanded(child) {
            if !outlineView.isItemExpanded(child) { outlineView.expandItem(child) }
            syncExpansion(under: child)
        }
    }

    // MARK: Data source

    private func node(_ item: Any?) -> FileTreeNode? {
        (item as? FileTreeNode) ?? model.rootNode
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        node(item)?.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        node(item)!.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileTreeNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FileTreeNode else { return nil }

        // Dropped on a terminal, files on this Mac become their escaped
        // path; remote files have no URL here, so they drag as one.
        if model.isRemote { return Ghostty.Shell.escape(node.path) as NSString }
        return URL(fileURLWithPath: node.path) as NSURL
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileTreeNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: FileTreeCell.identifier, owner: nil) as? FileTreeCell
            ?? FileTreeCell()
        cell.configure(node, model: model)
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !syncing, let node = notification.userInfo?["NSObject"] as? FileTreeNode else { return }
        model.didExpand(node)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !syncing, let node = notification.userInfo?["NSObject"] as? FileTreeNode else { return }
        model.didCollapse(node)
    }

    // MARK: Opening

    @objc private func doubleClicked(_ sender: Any?) {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? FileTreeNode else { return }
        open(node)
    }

    private func openSelection() {
        guard outlineView.selectedRowIndexes.count == 1,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? FileTreeNode else { return }
        open(node)
    }

    private func open(_ node: FileTreeNode) {
        if node.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else {
            model.openInEditor(node)
        }
    }

    // MARK: Context menu

    /// The nodes a menu command applies to: the selection if the clicked
    /// row is in it, otherwise the clicked row.
    private var targets: [FileTreeNode] {
        let clicked = outlineView.clickedRow
        let rows: IndexSet
        if clicked < 0 {
            rows = []
        } else if outlineView.selectedRowIndexes.contains(clicked) {
            rows = outlineView.selectedRowIndexes
        } else {
            rows = [clicked]
        }
        return rows.compactMap { outlineView.item(atRow: $0) as? FileTreeNode }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let nodes = targets
        let local = !model.isRemote

        func add(_ title: String, _ symbol: String? = nil, _ action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(FileTreeMenuAction.run), keyEquivalent: "")
            let handler = FileTreeMenuAction(action)
            item.target = handler
            item.representedObject = handler
            if let symbol { item.setImageIfDesired(systemSymbolName: symbol) }
            menu.addItem(item)
        }

        // Clicked below the rows: things to do in the root.
        guard let first = nodes.first, let rootNode = model.rootNode else {
            if let rootNode = model.rootNode {
                add("New File…", "doc.badge.plus") { [weak self] in self?.create(in: rootNode, directory: false) }
                add("New Folder…", "folder.badge.plus") { [weak self] in self?.create(in: rootNode, directory: true) }
                menu.addItem(.separator())
            }
            add("Refresh", "arrow.clockwise") { [weak self] in self?.model.refresh() }
            return
        }

        if nodes.count == 1 {
            if first.isDirectory {
                add("Open in Terminal", "terminal") { [weak self] in self?.model.openTerminal(at: first) }
                add("Open in New Tab", "macwindow.badge.plus") { [weak self] in self?.model.openTerminal(at: first, inNewTab: true) }
            } else {
                add("Open in Editor", "pencil.and.outline") { [weak self] in self?.model.openInEditor(first) }
                add("Open in Editor in New Tab", "macwindow.badge.plus") { [weak self] in self?.model.openInEditor(first, inNewTab: true) }
                if local {
                    add("Open with Default App", "arrow.up.forward.app") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: first.path))
                    }
                }
            }
        }
        if local {
            add("Reveal in Finder", "folder") {
                NSWorkspace.shared.activateFileViewerSelecting(nodes.map { URL(fileURLWithPath: $0.path) })
            }
        }
        menu.addItem(.separator())

        add("Insert Path in Terminal", "text.insert") { [weak self] in
            self?.model.delegate?.fileTreeInsert(nodes.map { Ghostty.Shell.escape($0.path) }.joined(separator: " ") + " ")
        }
        add("Copy Path", "doc.on.doc") {
            Self.copy(nodes.map(\.path).joined(separator: "\n"))
        }
        add("Copy Relative Path") { [weak self] in
            guard let self else { return }
            Self.copy(nodes.map { self.model.relativePath(of: $0.path) }.joined(separator: "\n"))
        }
        menu.addItem(.separator())

        if nodes.count == 1 {
            let parent = first.isDirectory
                ? first
                : (outlineView.parent(forItem: first) as? FileTreeNode ?? rootNode)
            add("New File…", "doc.badge.plus") { [weak self] in self?.create(in: parent, directory: false) }
            add("New Folder…", "folder.badge.plus") { [weak self] in self?.create(in: parent, directory: true) }
            add("Rename…", "pencil") { [weak self] in self?.rename(first) }
        }
        add(local ? "Move to Trash" : "Delete…", "trash") { [weak self] in self?.delete(nodes) }
    }

    private static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    // MARK: File operations

    /// Ask for a name in a sheet.
    private func askName(_ title: String, action: String, initial: String = "", completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        // Select the name without its extension, like Finder.
        if !initial.isEmpty {
            DispatchQueue.main.async {
                guard let editor = field.currentEditor() else { return }
                let stem = (initial as NSString).deletingPathExtension
                editor.selectedRange = NSRange(location: 0, length: (stem.isEmpty ? initial : stem).utf16.count)
            }
        }

        let handle: (NSApplication.ModalResponse) -> Void = { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, !name.isEmpty, name != initial else { return }
            completion(name)
        }
        if let window = outlineView.window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    private func create(in parent: FileTreeNode, directory: Bool) {
        askName(directory ? "New Folder" : "New File", action: "Create") { [weak self] name in
            guard let self, Self.isValidName(name) else { return }
            let path = (parent.path as NSString).appendingPathComponent(name)
            if parent !== self.model.rootNode {
                self.outlineView.expandItem(parent)
            }
            self.model.perform({ backend in
                if directory {
                    try await backend.createDirectory(at: path)
                } else {
                    try await backend.createFile(at: path)
                }
            }, window: self.outlineView.window)
        }
    }

    private func rename(_ node: FileTreeNode) {
        askName("Rename “\(node.name)”", action: "Rename", initial: node.name) { [weak self] name in
            guard let self, Self.isValidName(name) else { return }
            let destination = ((node.path as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent(name)
            self.model.perform({ try await $0.move(node.path, to: destination) }, window: self.outlineView.window)
        }
    }

    private func delete(_ nodes: [FileTreeNode]) {
        let paths = nodes.map(\.path)
        guard model.isRemote else {
            model.perform({ try await $0.delete(paths) }, window: outlineView.window)
            return
        }

        // Remote files can't go to the Trash, so ask first.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = nodes.count == 1
            ? "Delete “\(nodes[0].name)” on \(model.host ?? "the host")?"
            : "Delete \(nodes.count) items on \(model.host ?? "the host")?"
        alert.informativeText = "This can't be undone."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.model.perform({ try await $0.delete(paths) }, window: self.outlineView.window)
        }
        if let window = outlineView.window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    private static func isValidName(_ name: String) -> Bool {
        name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}

/// A menu item action as a closure. The item keeps it alive.
private final class FileTreeMenuAction: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run() {
        action()
    }
}

// MARK: Cell

private final class FileTreeCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FileTreeCell")

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        badge.alignment = .right
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(icon)
        addSubview(label)
        addSubview(badge)
        imageView = icon
        textField = label

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    func configure(_ node: FileTreeNode, model: FileTreeModel) {
        label.stringValue = node.name
        icon.image = Self.icon(for: node)
        icon.alphaValue = 1

        let status = model.gitStatus(of: node)
        let color: NSColor
        switch status {
        case .modified: color = .systemOrange
        case .added, .untracked: color = .systemGreen
        case .conflicted: color = .systemRed
        case .ignored: color = .tertiaryLabelColor
        case nil: color = .labelColor
        }
        label.textColor = color
        if status == .ignored { icon.alphaValue = 0.5 }

        // Folders get a dot for changes inside; files get a letter.
        if node.isDirectory, status != nil, model.git.ownStatus(of: node.path) == nil {
            badge.stringValue = "•"
        } else {
            badge.stringValue = status?.letter ?? ""
        }
        badge.textColor = color

        var tooltip = node.path
        if node.isSymlink { tooltip += " (symbolic link)" }
        toolTip = tooltip
        setAccessibilityLabel(node.name)
    }

    /// Icons come from the file type, so local and remote files look alike
    /// and nothing is read from disk for them.
    private static func icon(for node: FileTreeNode) -> NSImage {
        if node.isDirectory {
            return NSWorkspace.shared.icon(for: .folder)
        }
        let ext = (node.name as NSString).pathExtension
        let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        return NSWorkspace.shared.icon(for: type)
    }
}

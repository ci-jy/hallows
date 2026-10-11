import AppKit
import Combine
import CoreServices

/// What the file tree asks of the window it's in.
@MainActor
protocol FileTreeDelegate: AnyObject {
    /// Open a terminal next to the focused one, or in a new tab.
    func fileTreeOpenTerminal(_ config: Ghostty.SurfaceConfiguration, inNewTab: Bool)

    /// Insert text into the focused terminal, as if pasted.
    func fileTreeInsert(_ text: String)

    /// Give the keyboard back to the focused terminal.
    func fileTreeFocusTerminal()
}

/// A file or directory in the tree. Nodes are kept per path so the outline
/// view keeps its expansion and selection state across refreshes.
final class FileTreeNode {
    let path: String
    let name: String
    fileprivate(set) var isDirectory: Bool
    fileprivate(set) var isSymlink: Bool

    /// The directory's visible children, or nil if it hasn't been listed.
    fileprivate(set) var children: [FileTreeNode]?

    init(path: String, isDirectory: Bool, isSymlink: Bool = false) {
        self.path = path
        self.name = (path as NSString).lastPathComponent
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
    }
}

/// The file tree of one terminal window. It follows the focused terminal:
/// its working directory on this Mac, or on the host it's connected to over
/// ssh, and shows the git repository that directory is in (or the directory).
@MainActor
final class FileTreeModel: ObservableObject {
    /// Changes the outline view has to make.
    enum Update {
        /// The root changed; reload everything.
        case reloadAll
        /// These directories' children changed.
        case reload([FileTreeNode])
        /// Git status changed; redraw rows.
        case redraw
        /// Expand to, select and scroll to this node.
        case reveal(FileTreeNode)
        /// Collapse everything.
        case collapseAll
    }

    @Published var isVisible: Bool {
        didSet {
            guard isVisible != oldValue else { return }
            Self.defaults.set(isVisible, forKey: Self.visibleKey)
            visibilityDidChange()
        }
    }

    @Published var width: CGFloat {
        didSet { Self.defaults.set(Double(width), forKey: Self.widthKey) }
    }

    @Published var showHidden: Bool {
        didSet {
            guard showHidden != oldValue else { return }
            Self.defaults.set(showHidden, forKey: Self.hiddenKey)
            for dir in listings.keys { rebuildChildren(of: dir) }
            onUpdate?(.reloadAll)
        }
    }

    /// The directory the tree shows.
    @Published private(set) var root: String?

    /// The focused terminal's working directory.
    @Published private(set) var cwd: String?

    /// The host the files are on, or nil for this Mac.
    @Published private(set) var host: String?

    /// Why the tree can't be shown, if it can't.
    @Published private(set) var errorMessage: String?

    @Published private(set) var isLoading = false

    private(set) var rootNode: FileTreeNode?
    private(set) var git = FileTreeGitIndex()

    weak var delegate: FileTreeDelegate?

    /// Set by the outline view to hear about changes.
    var onUpdate: ((Update) -> Void)?

    var isRemote: Bool { backend.target != nil }

    /// The ssh connection, for opening files on the host in a terminal.
    var connection: SSHConnection? { (backend as? RemoteFileTreeBackend)?.connection }

    private var backend: FileTreeBackend = LocalFileTreeBackend()
    private var nodes: [String: FileTreeNode] = [:]
    private var listings: [String: [FileTreeEntry]] = [:]
    private var stamps: [String: String] = [:]
    private var expanded: Set<String> = []
    private var pendingReveal: String?

    private weak var surface: Ghostty.SurfaceView?
    private var surfaceCancellables: Set<AnyCancellable> = []

    /// The foreground process group the ssh connection was found in, to
    /// ride out `+ssh` reconnecting, when there's briefly no ssh process.
    private var remoteProcessGroup: Int?

    private var refreshTask: Task<Void, Never>?
    private var needsRefresh = false
    private var pollTimer: Timer?
    private var watcher: FileTreeWatcher?
    private var debounce: DispatchWorkItem?

    private static let defaults = UserDefaults.standard
    private static let visibleKey = "FileTreeVisible"
    private static let widthKey = "FileTreeWidth"
    private static let hiddenKey = "FileTreeShowHidden"

    /// Names never shown.
    private static let alwaysHidden: Set<String> = [".git", ".DS_Store"]

    init() {
        // New windows start the way the last one was left.
        isVisible = Self.defaults.bool(forKey: Self.visibleKey)
        let width = Self.defaults.double(forKey: Self.widthKey)
        self.width = width > 0 ? CGFloat(width) : 240
        showHidden = Self.defaults.object(forKey: Self.hiddenKey) as? Bool ?? true

        // didSet doesn't run for the initial value.
        if isVisible {
            DispatchQueue.main.async { [weak self] in self?.visibilityDidChange() }
        }
    }

    // MARK: Following the terminal

    /// Follow this terminal.
    func follow(_ surface: Ghostty.SurfaceView?) {
        guard surface !== self.surface else { return }
        self.surface = surface
        surfaceCancellables = []
        guard let surface else { return }

        // A new prompt usually retitles the window, which is our cue that
        // a remote shell may have changed directory.
        surface.$pwd
            .removeDuplicates()
            .sink { [weak self] _ in self?.terminalDidChange() }
            .store(in: &surfaceCancellables)
        surface.$title
            .removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.terminalDidChange() }
            .store(in: &surfaceCancellables)
    }

    private func terminalDidChange() {
        guard isVisible else { return }
        updateLocation()
        refresh()
    }

    /// Switch between this Mac and an ssh host to match the terminal.
    private func updateLocation() {
        let pgid = surface?.surfaceModel?.foregroundPID
        var target = pgid.flatMap { SSHTarget.find(foregroundProcessGroup: $0) }
        if target == nil, let current = backend.target, pgid != nil, pgid == remoteProcessGroup {
            target = current
        }
        remoteProcessGroup = target == nil ? nil : pgid
        guard target != backend.target else { return }

        // Moving between terminals connected to the same host, keep the
        // directory in case the new one can't tell us its own.
        let keepCwd = target?.destination == backend.target?.destination
        backend = target.map { RemoteFileTreeBackend(target: $0) } ?? LocalFileTreeBackend()
        host = target?.displayName
        reset(keepCwd: keepCwd)
    }

    private func reset(keepCwd: Bool) {
        refreshTask?.cancel()
        refreshTask = nil
        if !keepCwd { cwd = nil }
        root = nil
        rootNode = nil
        nodes = [:]
        listings = [:]
        stamps = [:]
        expanded = []
        git = FileTreeGitIndex()
        errorMessage = nil
        watcher = nil
        onUpdate?(.reloadAll)
    }

    private func visibilityDidChange() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard isVisible else {
            watcher = nil
            return
        }

        // ssh connections can't be watched, so check on them now and then.
        // This also notices ssh starting or ending in the terminal.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard NSApp.isActive else { return }
                let wasRemote = self.isRemote
                self.updateLocation()
                if self.isRemote || wasRemote { self.refresh() }
            }
        }
        updateLocation()
        refresh()
        if let root { watch(root) }
    }

    // MARK: Loading

    /// Look for changes: the working directory, the root, and every
    /// expanded directory.
    func refresh() {
        guard isVisible else { return }
        if refreshTask != nil {
            needsRefresh = true
            return
        }

        let backend = self.backend
        let localCwd = backend.target == nil ? surface?.pwd.flatMap { $0.isEmpty ? nil : $0 } : nil
        let directories = Array(expanded)
        let stamps = self.stamps
        let fallback = cwd
        if root == nil { isLoading = true }

        refreshTask = Task { [weak self] in
            let result: Result<FileTreeSnapshot, Error>
            do {
                result = .success(try await backend.snapshot(
                    cwd: localCwd,
                    fallbackCwd: fallback,
                    directories: directories,
                    stamps: stamps))
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled, backend === self.backend else { return }
            self.refreshTask = nil
            self.isLoading = false
            switch result {
            case .success(let snapshot):
                self.errorMessage = nil
                self.apply(snapshot)
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
            if self.needsRefresh {
                self.needsRefresh = false
                self.refresh()
            }
        }
    }

    private func apply(_ snapshot: FileTreeSnapshot) {
        guard !snapshot.root.isEmpty else { return }

        if snapshot.root != root {
            let keep = expanded.filter { LocalFileTreeBackend.isInside($0, snapshot.root) }
            nodes = [:]
            listings = [:]
            stamps = [:]
            expanded = keep
            root = snapshot.root
            let node = FileTreeNode(path: snapshot.root, isDirectory: true)
            nodes[snapshot.root] = node
            rootNode = node
            onUpdate?(.reloadAll)
            if !isRemote { watch(snapshot.root) }
        }

        var changed: [FileTreeNode] = []
        for dir in snapshot.missing {
            expanded.remove(dir)
            listings[dir] = nil
            stamps[dir] = nil
        }
        for (dir, entries) in snapshot.listings where listings[dir] != entries {
            listings[dir] = entries
            rebuildChildren(of: dir)
            if let node = nodes[dir] { changed.append(node) }
        }
        stamps.merge(snapshot.stamps) { $1 }

        let newGit = snapshot.git ?? FileTreeGitIndex(root: snapshot.root)
        let gitChanged = newGit != git
        git = newGit

        // Parents before children, so the outline view knows them.
        changed.sort { $0.path.count < $1.path.count }
        if !changed.isEmpty { onUpdate?(.reload(changed)) }
        if gitChanged { onUpdate?(.redraw) }

        if snapshot.cwd != cwd {
            cwd = snapshot.cwd
            reveal(snapshot.cwd)
        } else if let pendingReveal {
            reveal(pendingReveal)
        }

        // Directories that were expanded before (e.g. when the root came
        // back) and still need listing.
        if expanded.contains(where: { listings[$0] == nil }) { needsRefresh = true }
    }

    private func rebuildChildren(of dir: String) {
        guard let entries = listings[dir] else { return }
        let node = nodes[dir] ?? FileTreeNode(path: dir, isDirectory: true)
        nodes[dir] = node

        let visible = entries
            .filter { !Self.alwaysHidden.contains($0.name) && (showHidden || !$0.name.hasPrefix(".")) }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }

        let old = Set(node.children?.map(\.path) ?? [])
        node.children = visible.map { entry in
            let path = (dir as NSString).appendingPathComponent(entry.name)
            if let existing = nodes[path], existing.isDirectory == entry.isDirectory {
                existing.isSymlink = entry.isSymlink
                return existing
            }
            let child = FileTreeNode(path: path, isDirectory: entry.isDirectory, isSymlink: entry.isSymlink)
            nodes[path] = child
            return child
        }

        // Forget what went away.
        for path in old.subtracting(node.children?.map(\.path) ?? []) {
            nodes[path] = nil
        }
    }

    /// Expand the directories down to path, then select it.
    private func reveal(_ path: String) {
        pendingReveal = nil
        guard let root, LocalFileTreeBackend.isInside(path, root), path != root else { return }

        var dirs: [String] = []
        var dir = path
        while dir != root && dir.count > root.count {
            dirs.append(dir)
            dir = (dir as NSString).deletingLastPathComponent
        }
        expanded.formUnion(dirs)

        if dirs.allSatisfy({ listings[$0] != nil }) {
            // It may not be shown, e.g. a hidden directory.
            if let node = nodes[path] { onUpdate?(.reveal(node)) }
        } else {
            pendingReveal = path
            needsRefresh = true
            if refreshTask == nil { refresh() }
        }
    }

    // MARK: Outline view

    func isExpanded(_ node: FileTreeNode) -> Bool {
        expanded.contains(node.path)
    }

    func didExpand(_ node: FileTreeNode) {
        guard !expanded.contains(node.path) else { return }
        expanded.insert(node.path)
        if listings[node.path] == nil { refresh() }
    }

    func didCollapse(_ node: FileTreeNode) {
        // Directories inside stay expanded, as the outline view remembers.
        expanded.remove(node.path)
    }

    func collapseAll() {
        expanded = []
        onUpdate?(.collapseAll)
    }

    func gitStatus(of node: FileTreeNode) -> FileTreeGitStatus? {
        git.status(of: node.path, isDirectory: node.isDirectory)
    }

    // MARK: Watching

    /// Watch the root on this Mac, refreshing when something in it changes
    /// that the tree shows.
    private func watch(_ root: String) {
        guard isVisible, !isRemote else {
            watcher = nil
            return
        }
        watcher = FileTreeWatcher(path: root) { [weak self] paths in
            MainActor.assumeIsolated {
                self?.filesDidChange(paths)
            }
        }
    }

    private func filesDidChange(_ paths: [String]) {
        guard let root else { return }
        let relevant = paths.contains { raw in
            let path = raw.hasSuffix("/") && raw.count > 1 ? String(raw.dropLast()) : raw

            // Listings we show.
            if path == root || expanded.contains(path) { return true }

            // Git's own files: only those that change status matter.
            let gitDir = (root as NSString).appendingPathComponent(".git")
            if LocalFileTreeBackend.isInside(path, gitDir) {
                return path == gitDir || path.hasPrefix(gitDir + "/refs")
            }

            // Changes in ignored directories (build output) don't show.
            return git.status(of: path, isDirectory: true) != .ignored
        }
        guard relevant else { return }

        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: Actions

    func relativePath(of path: String) -> String {
        guard let base = cwd ?? root else { return path }
        let from = base.split(separator: "/")
        let to = path.split(separator: "/")
        var common = 0
        while common < from.count && common < to.count && from[common] == to[common] { common += 1 }
        let parts = Array(repeating: "..", count: from.count - common) + to[common...].map(String.init)
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    /// Run a file operation, then refresh. Errors are shown to the user.
    func perform(_ operation: @escaping (FileTreeBackend) async throws -> Void, window: NSWindow?) {
        let backend = self.backend
        Task { [weak self] in
            do {
                try await operation(backend)
            } catch {
                let alert = NSAlert(error: error)
                if let window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
            }
            self?.refresh()
        }
    }

    /// Open a file in the user's editor, in a terminal next to the focused
    /// one or in a new tab. The editor is $VISUAL or $EDITOR from the user's
    /// login shell (on the host, for remote files), or vi.
    func openInEditor(_ node: FileTreeNode, inNewTab: Bool = false) {
        let dir = root ?? (node.path as NSString).deletingLastPathComponent
        let args = [node.path, dir].map(Ghostty.Shell.quote).joined(separator: " ")
        let script = "sh -c \(Ghostty.Shell.quote(Self.editorScript)) hallows \(args)"
        var config = Ghostty.SurfaceConfiguration()
        if let connection {
            config.command = Self.sshCommand(connection, remoteCommand: script)
        } else {
            config.command = "/bin/" + script
            config.workingDirectory = dir
        }
        delegate?.fileTreeOpenTerminal(config, inNewTab: inNewTab)
    }

    /// Open a shell in a directory, next to the focused terminal or in a new tab.
    func openTerminal(at node: FileTreeNode, inNewTab: Bool = false) {
        var config = Ghostty.SurfaceConfiguration()
        if let connection {
            config.command = Self.sshCommand(
                connection,
                remoteCommand: "cd \(Ghostty.Shell.quote(node.path)) && exec \"$SHELL\" -l")
        } else {
            config.workingDirectory = node.path
        }
        delegate?.fileTreeOpenTerminal(config, inNewTab: inNewTab)
    }

    private static func sshCommand(_ connection: SSHConnection, remoteCommand: String) -> String {
        (["/usr/bin/ssh"] + connection.interactiveArguments(remoteCommand: remoteCommand))
            .map(Ghostty.Shell.quote)
            .joined(separator: " ")
    }

    /// Starts $VISUAL or $EDITOR on $1 in $2 through the user's shell, so
    /// settings from its startup files apply. It contains no backslashes,
    /// so it survives being quoted for fish as well as POSIX shells.
    private static let editorScript = """
    cd "$2" 2>/dev/null
    case "${SHELL:-}" in
    *fish) exec "$SHELL" -l -i -c 'set -l e $VISUAL $EDITOR vi; eval $e[1] (string escape -- $argv[1])' "$1" ;;
    *zsh) exec "$SHELL" -l -i -c 'exec ${=${VISUAL:-${EDITOR:-vi}}} "$0"' "$1" ;;
    *bash|*/sh|*ksh|*dash) exec "$SHELL" -l -i -c 'exec ${VISUAL:-${EDITOR:-vi}} "$0"' "$1" ;;
    *) exec ${VISUAL:-${EDITOR:-vi}} "$1" ;;
    esac
    """
}

/// Watches a directory tree on this Mac with FSEvents.
private final class FileTreeWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init?(path: String, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileTreeWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            watcher.handler((0..<count).compactMap { array[$0] as? String })
        }
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

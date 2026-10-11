import Foundation
import Darwin

/// One entry of a directory listing.
struct FileTreeEntry: Equatable {
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
}

/// What git says about a path.
enum FileTreeGitStatus: Equatable {
    case modified
    case added
    case untracked
    case conflicted
    case ignored

    /// The letter shown next to a file, as in editors.
    var letter: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .untracked: return "U"
        case .conflicted: return "!"
        case .ignored: return ""
        }
    }
}

/// The git status of a repository, indexed for looking up rows.
struct FileTreeGitIndex: Equatable {
    /// Status of files and of whole directories (untracked or ignored ones).
    private var paths: [String: FileTreeGitStatus] = [:]

    /// The most notable change inside each directory, to tint folders.
    private var changedDirectories: [String: FileTreeGitStatus] = [:]

    private let root: String

    init(root: String = "/") {
        self.root = root
    }

    /// Parse `git status --porcelain=v1 -z` output for the repository at root.
    init(root: String, porcelain: Data) {
        self.root = root
        let records = porcelain.split(separator: 0, omittingEmptySubsequences: false)
        var i = 0
        while i < records.count {
            let record = records[i]
            i += 1
            guard record.count > 3 else { continue }
            let bytes = Array(record)
            let x = Character(UnicodeScalar(bytes[0]))
            let y = Character(UnicodeScalar(bytes[1]))
            var relative = String(decoding: bytes[3...], as: UTF8.self)

            // Renames and copies are followed by the original path.
            if x == "R" || x == "C" { i += 1 }

            let status: FileTreeGitStatus?
            switch (x, y) {
            case ("?", "?"): status = .untracked
            case ("!", "!"): status = .ignored
            case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): status = .conflicted
            case ("A", _), ("R", _), ("C", _): status = .added
            case ("D", _), (_, "D"): status = nil // gone from the tree
            default: status = .modified
            }

            if relative.hasSuffix("/") { relative.removeLast() }
            let path = (root as NSString).appendingPathComponent(relative)
            if let status { paths[path] = status }

            // Folders show the most notable change inside them.
            guard status != .ignored else { continue }
            let tint = status ?? .modified
            var dir = (path as NSString).deletingLastPathComponent
            while dir.count >= root.count && dir != "/" {
                if Self.rank(tint) > Self.rank(changedDirectories[dir]) {
                    changedDirectories[dir] = tint
                }
                if dir == root { break }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
    }

    private static func rank(_ status: FileTreeGitStatus?) -> Int {
        switch status {
        case nil, .ignored: return 0
        case .untracked: return 1
        case .added: return 2
        case .modified: return 3
        case .conflicted: return 4
        }
    }

    /// The status of a path: its own, or that of an untracked or ignored
    /// directory it's in, or for a directory the most notable change in it.
    func status(of path: String, isDirectory: Bool) -> FileTreeGitStatus? {
        ownStatus(of: path) ?? (isDirectory ? changedDirectories[path] : nil)
    }

    /// The status of the path itself, or of the untracked or ignored
    /// directory it's in, leaving out changes inside a directory.
    func ownStatus(of path: String) -> FileTreeGitStatus? {
        if let status = paths[path] { return status }
        var dir = (path as NSString).deletingLastPathComponent
        while dir.count > root.count {
            if let status = paths[dir], status == .ignored || status == .untracked { return status }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }
}

/// What a refresh found.
struct FileTreeSnapshot {
    /// The terminal's working directory.
    var cwd: String

    /// The directory the tree shows: the git repository `cwd` is in, or `cwd`.
    var root: String

    /// Listings of the requested directories that changed, by path.
    var listings: [String: [FileTreeEntry]] = [:]

    /// Stamps that tell whether a directory changed since it was listed.
    var stamps: [String: String] = [:]

    /// Requested directories that no longer exist.
    var missing: Set<String> = []

    /// The repository's status, or nil if root isn't a repository.
    var git: FileTreeGitIndex?
}

/// Where the files the tree shows live, and how to get at them.
protocol FileTreeBackend: AnyObject {
    /// The host, or nil for this Mac.
    var target: SSHTarget? { get }

    /// Find the working directory and root and list the given directories
    /// (the root is always listed). `stamps` are those of earlier listings,
    /// so unchanged directories can be skipped; `fallbackCwd` is used when
    /// the working directory can't be found.
    func snapshot(
        cwd: String?,
        fallbackCwd: String?,
        directories: [String],
        stamps: [String: String]
    ) async throws -> FileTreeSnapshot

    func createFile(at path: String) async throws
    func createDirectory(at path: String) async throws
    func move(_ path: String, to destination: String) async throws
    func delete(_ paths: [String]) async throws
}

enum FileTreeError: LocalizedError {
    case exists(String)
    case noWorkingDirectory

    var errorDescription: String? {
        switch self {
        case .exists(let name): return "“\(name)” already exists."
        case .noWorkingDirectory: return "The terminal's working directory isn't known."
        }
    }
}

// MARK: Local

final class LocalFileTreeBackend: FileTreeBackend {
    var target: SSHTarget? { nil }

    func snapshot(
        cwd: String?,
        fallbackCwd: String?,
        directories: [String],
        stamps: [String: String]
    ) async throws -> FileTreeSnapshot {
        guard let cwd = cwd ?? fallbackCwd else { throw FileTreeError.noWorkingDirectory }
        return await Task.detached(priority: .userInitiated) {
            let gitRoot = Self.gitRoot(containing: cwd)
            let root = gitRoot ?? cwd
            var snapshot = FileTreeSnapshot(cwd: cwd, root: root)
            for dir in Set([root] + directories.filter { Self.isInside($0, root) }) {
                if let entries = Self.list(dir) {
                    snapshot.listings[dir] = entries
                } else {
                    snapshot.missing.insert(dir)
                }
            }
            if let gitRoot, let status = Git.status(root: gitRoot) {
                snapshot.git = FileTreeGitIndex(root: gitRoot, porcelain: status)
            }
            return snapshot
        }.value
    }

    static func isInside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// The top of the git work tree containing path, found the way git does
    /// by looking for `.git` in it and its parents.
    private static func gitRoot(containing path: String) -> String? {
        var dir = path
        while true {
            if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
                return dir
            }
            if dir == "/" || dir.isEmpty { return nil }
            dir = (dir as NSString).deletingLastPathComponent
        }
    }

    private static func list(_ dir: String) -> [FileTreeEntry]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        return names.map { name in
            let path = (dir as NSString).appendingPathComponent(name)
            var info = stat()
            let isSymlink = lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
            let isDirectory = stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            return FileTreeEntry(name: name, isDirectory: isDirectory, isSymlink: isSymlink)
        }
    }

    func createFile(at path: String) async throws {
        guard !FileManager.default.fileExists(atPath: path) else {
            throw FileTreeError.exists((path as NSString).lastPathComponent)
        }
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
    }

    func createDirectory(at path: String) async throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    func move(_ path: String, to destination: String) async throws {
        guard !FileManager.default.fileExists(atPath: destination) else {
            throw FileTreeError.exists((destination as NSString).lastPathComponent)
        }
        try FileManager.default.moveItem(atPath: path, toPath: destination)
    }

    /// Local files go to the Trash, so they can be put back.
    func delete(_ paths: [String]) async throws {
        for path in paths {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        }
    }

    private enum Git {
        /// The git to run. /usr/bin/git is a stub that offers to install the
        /// developer tools when they're missing, so only use it when they aren't.
        static let executable: String? = {
            let fm = FileManager.default
            for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fm.isExecutableFile(atPath: path) {
                return path
            }
            let tools = ["/Library/Developer/CommandLineTools/usr/bin/git",
                         "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
            return tools.contains(where: fm.isExecutableFile(atPath:)) ? "/usr/bin/git" : nil
        }()

        static func status(root: String) -> Data? {
            guard let executable else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-C", root, "--no-optional-locks", "status",
                                 "--porcelain=v1", "-z", "--ignored=matching", "--untracked-files=normal"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }

            // Big repositories can take a while; don't hold up the tree.
            let timeout = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            return process.terminationStatus == 0 ? data : nil
        }
    }
}

// MARK: Remote

/// Files on an ssh host, listed with a POSIX shell script run over a shared
/// connection. The working directory comes from `hallows-persist cwd`.
final class RemoteFileTreeBackend: FileTreeBackend {
    let connection: SSHConnection

    var target: SSHTarget? { connection.target }

    init(target: SSHTarget) {
        connection = SSHConnection(target: target)
    }

    /// Arguments: persist tag, fallback cwd, then directory/stamp pairs.
    /// Output is NUL-terminated records: `C` cwd, `R` root, then for each
    /// directory `D` path and `M` stamp followed by `E` entries (type, type
    /// following symlinks, name), or `U` path if unchanged, or `X` path if
    /// gone; and finally `S` followed by the raw `git status` output.
    private static let snapshotScript = #"""
    tag=$1 fallback=$2
    shift 2
    cwd=
    if [ -n "$tag" ]; then
      cwd=$("$HOME/.local/share/hallows/hallows-persist" cwd "$tag" 2>/dev/null)
    fi
    [ -n "$cwd" ] && [ -d "$cwd" ] || cwd=$fallback
    [ -n "$cwd" ] && [ -d "$cwd" ] || cwd=$HOME
    root=$(cd "$cwd" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
    git=1
    [ -n "$root" ] || { root=$cwd; git=0; }
    printf 'C%s\0R%s\0' "$cwd" "$root"

    gnu=0
    find / -maxdepth 0 -printf '' >/dev/null 2>&1 && gnu=1
    list() {
      if [ $gnu = 1 ]; then
        m=$(find "$1" -maxdepth 0 -type d -printf '%T@' 2>/dev/null)
        [ -n "$m" ] || { printf 'X%s\0' "$1"; return; }
        if [ "$m" = "$2" ]; then printf 'U%s\0' "$1"; return; fi
        printf 'D%s\0M%s\0' "$1" "$m"
        find "$1" -mindepth 1 -maxdepth 1 -printf 'E%y%Y%f\0' 2>/dev/null | head -c 4000000
      else
        [ -d "$1" ] || { printf 'X%s\0' "$1"; return; }
        printf 'D%s\0M\0' "$1"
        for f in "$1"/* "$1"/.*; do
          n=${f##*/}
          case $n in .|..) continue ;; esac
          [ -e "$f" ] || [ -L "$f" ] || continue
          if [ -d "$f" ]; then t=d; else t=f; fi
          if [ -L "$f" ]; then l=l; else l=$t; fi
          printf 'E%s%s%s\0' "$l" "$t" "$n"
        done
      fi
    }

    stamp=
    while [ $# -ge 2 ]; do
      [ "$1" = "$root" ] && stamp=$2
      shift 2
    done
    list "$root" "$stamp"
    """#

    /// Lists the directories in the remaining arguments (pairs again) that
    /// are inside root, then prints git status.
    private static let listScript = #"""
    while [ $# -ge 2 ]; do
      case $1 in
        "$root") ;;
        "$root"/*) list "$1" "$2" ;;
      esac
      shift 2
    done
    if [ $git = 1 ]; then
      printf 'S\0'
      git -C "$root" --no-optional-locks status --porcelain=v1 -z --ignored=matching --untracked-files=normal 2>/dev/null | head -c 8000000
    fi
    """#

    func snapshot(
        cwd: String?,
        fallbackCwd: String?,
        directories: [String],
        stamps: [String: String]
    ) async throws -> FileTreeSnapshot {
        var pairs: [String] = []
        for dir in directories {
            pairs.append(dir)
            pairs.append(stamps[dir] ?? "")
        }

        let data = try await connection.run(
            script: Self.combinedScript,
            arguments: [target?.persistTag ?? "", fallbackCwd ?? ""] + pairs)
        return Self.parse(data)
    }

    /// The snapshot and list scripts. Both walk the directory/stamp pairs,
    /// so the arguments are copied into numbered variables first, which
    /// survive the first script's `shift`s, and "$@" is rebuilt from them.
    private static let combinedScript: String = {
        let save = #"""
        argc=$#
        i=0
        for a in "$@"; do
          i=$((i + 1))
          eval "arg_$i=\$a"
        done
        """#
        let restore = #"""
        set --
        i=3
        while [ $i -le $argc ]; do
          eval "set -- \"\$@\" \"\$arg_$i\""
          i=$((i + 1))
        done
        """#
        return save + "\n" + snapshotScript + "\n" + restore + "\n" + listScript
    }()

    static func parse(_ data: Data) -> FileTreeSnapshot {
        var snapshot = FileTreeSnapshot(cwd: "", root: "")
        var current: String?
        var entries: [FileTreeEntry] = []

        func finish() {
            if let current { snapshot.listings[current] = entries }
            current = nil
            entries = []
        }

        var start = data.startIndex
        while start < data.endIndex {
            // Git status is the rest of the output.
            if data[start] == UInt8(ascii: "S"), start + 1 < data.endIndex, data[start + 1] == 0 {
                finish()
                snapshot.git = FileTreeGitIndex(root: snapshot.root, porcelain: data[(start + 2)...])
                return snapshot
            }

            guard let end = data[start...].firstIndex(of: 0) else { break }
            let record = data[start..<end]
            start = end + 1
            guard let kind = record.first else { continue }
            let value = String(decoding: record.dropFirst(), as: UTF8.self)

            switch kind {
            case UInt8(ascii: "C"): snapshot.cwd = value
            case UInt8(ascii: "R"): snapshot.root = value
            case UInt8(ascii: "D"):
                finish()
                current = value
            case UInt8(ascii: "M"):
                if let current { snapshot.stamps[current] = value }
            case UInt8(ascii: "U"):
                finish()
            case UInt8(ascii: "X"):
                finish()
                snapshot.missing.insert(value)
            case UInt8(ascii: "E"):
                let bytes = Array(record.dropFirst())
                guard bytes.count > 2, current != nil else { continue }
                let name = String(decoding: bytes[2...], as: UTF8.self)
                entries.append(FileTreeEntry(
                    name: name,
                    isDirectory: bytes[1] == UInt8(ascii: "d"),
                    isSymlink: bytes[0] == UInt8(ascii: "l")))
            default:
                break
            }
        }
        finish()
        return snapshot
    }

    func createFile(at path: String) async throws {
        _ = try await connection.run(script: #"""
        if [ -e "$1" ] || [ -L "$1" ]; then echo "“${1##*/}” already exists." >&2; exit 3; fi
        : >"$1"
        """#, arguments: [path])
    }

    func createDirectory(at path: String) async throws {
        _ = try await connection.run(script: #"mkdir -- "$1""#, arguments: [path])
    }

    func move(_ path: String, to destination: String) async throws {
        _ = try await connection.run(script: #"""
        if [ -e "$2" ] || [ -L "$2" ]; then echo "“${2##*/}” already exists." >&2; exit 3; fi
        mv -- "$1" "$2"
        """#, arguments: [path, destination])
    }

    func delete(_ paths: [String]) async throws {
        _ = try await connection.run(script: #"rm -rf -- "$@""#, arguments: paths)
    }
}

import Testing
import Foundation
@testable import Ghostty

@Suite
struct FileTreeTests {
    // MARK: - SSHTarget

    @Test func plainSSH() throws {
        let target = try #require(SSHTarget(argv: ["ssh", "example-host"]))
        #expect(target.destination == "example-host")
        #expect(target.options.isEmpty)
        #expect(target.persistTag == nil)
        #expect(target.displayName == "example-host")
    }

    @Test func persistSession() throws {
        // What `hallows +ssh --persist` runs.
        let target = try #require(SSHTarget(argv: [
            "ssh", "-o", "SetEnv=TERM=xterm-hallows", "-o", "SendEnv=COLORTERM", "-t",
            "-o", "ServerAliveInterval=2", "-o", "PermitLocalCommand=yes",
            "-o", "LocalCommand=touch '/tmp/hallows-ssh-x'",
            "-p", "2222", "user@example-host",
            "sh -c 'exec \"$HOME/.local/share/hallows/hallows-persist\" attach 0a1b2c3d4e5f --reconnect'",
        ]))
        #expect(target.destination == "user@example-host")
        #expect(target.options == ["-p", "2222"])
        #expect(target.persistTag == "0a1b2c3d4e5f")
        #expect(target.displayName == "example-host")
    }

    @Test func optionsAfterDestinationAndClusters() throws {
        let target = try #require(SSHTarget(argv: [
            "/usr/bin/ssh", "-4Ati", "~/.ssh/key", "host", "-J", "jump", "-L", "8080:localhost:80",
        ]))
        #expect(target.destination == "host")
        #expect(target.options == ["-4", "-i", "~/.ssh/key", "-J", "jump"])
    }

    @Test func noDestination() {
        #expect(SSHTarget(argv: ["ssh", "-p", "22"]) == nil)
        #expect(SSHTarget(argv: ["ssh", "-p"]) == nil)
    }

    // MARK: - Git status

    @Test func gitIndex() {
        let porcelain = Data(
            (" M src/a.zig\0?? new/\0!! zig-out/\0R  b.swift\0old.swift\0UU c.c\0 D gone.txt\0")
                .utf8)
        let git = FileTreeGitIndex(root: "/repo", porcelain: porcelain)
        #expect(git.status(of: "/repo/src/a.zig", isDirectory: false) == .modified)
        #expect(git.status(of: "/repo/src", isDirectory: true) == .modified)
        #expect(git.status(of: "/repo/new/x/y.txt", isDirectory: false) == .untracked)
        #expect(git.status(of: "/repo/zig-out/bin", isDirectory: true) == .ignored)
        #expect(git.status(of: "/repo/b.swift", isDirectory: false) == .added)
        #expect(git.status(of: "/repo/old.swift", isDirectory: false) == nil)
        #expect(git.status(of: "/repo/c.c", isDirectory: false) == .conflicted)
        #expect(git.status(of: "/repo/gone.txt", isDirectory: false) == nil)
        #expect(git.status(of: "/repo/clean.txt", isDirectory: false) == nil)

        // A folder holding an untracked file isn't untracked itself.
        #expect(git.ownStatus(of: "/repo/new") == .untracked)
        #expect(git.ownStatus(of: "/repo/src") == nil)
    }

    // MARK: - Remote snapshot

    @Test func parseRemoteSnapshot() {
        let output = Data((
            "C/home/u/proj/src\0R/home/u/proj\0" +
            "D/home/u/proj\0M1700000000.5\0Eddsrc\0Efff.txt\0Eldlink\0" +
            "U/home/u/proj/src\0X/home/u/proj/gone\0" +
            "S\0 M f.txt\0"
        ).utf8)
        let snapshot = RemoteFileTreeBackend.parse(output)
        #expect(snapshot.cwd == "/home/u/proj/src")
        #expect(snapshot.root == "/home/u/proj")
        #expect(snapshot.stamps["/home/u/proj"] == "1700000000.5")
        #expect(snapshot.listings["/home/u/proj"] == [
            FileTreeEntry(name: "src", isDirectory: true, isSymlink: false),
            FileTreeEntry(name: "f.txt", isDirectory: false, isSymlink: false),
            FileTreeEntry(name: "link", isDirectory: true, isSymlink: true),
        ])
        #expect(snapshot.listings["/home/u/proj/src"] == nil)
        #expect(snapshot.missing == ["/home/u/proj/gone"])
        #expect(snapshot.git?.status(of: "/home/u/proj/f.txt", isDirectory: false) == .modified)
    }
}

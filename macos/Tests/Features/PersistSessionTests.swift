import Testing
import Foundation
@testable import Ghostty

@Suite
struct PersistSessionTests {
    @Test func shellIntegration() throws {
        // What the shell integration's `ssh` runs.
        let session = try #require(PersistSession(
            argv: ["/Applications/Hallows.app/Contents/MacOS/hallows", "+ssh", "--persist", "--", "example-host"],
            tag: "0a1b2c3d4e5f"))
        #expect(session.arguments == ["--persist", "--", "example-host"])
        #expect(session.resumeCommand(hallows: "/Apps/Hallows.app/Contents/MacOS/hallows")
            == "/Apps/Hallows.app/Contents/MacOS/hallows +ssh --resume=0a1b2c3d4e5f --persist -- example-host")
    }

    @Test func resumedSessionReplacesTag() throws {
        let session = try #require(PersistSession(
            argv: ["hallows", "+ssh", "--resume=old", "--persist", "--", "host"],
            tag: "new"))
        #expect(session.arguments == ["--persist", "--", "host"])
        #expect(session.resumeCommand(hallows: "hallows") == "hallows +ssh --resume=new --persist -- host")
    }

    @Test func sshArgumentsAreKeptAndQuoted() throws {
        // A `--resume=` after `--` belongs to ssh's arguments.
        let session = try #require(PersistSession(
            argv: ["hallows", "+ssh", "--persist", "--", "-i", "~/my key", "host", "--resume=x"],
            tag: "t"))
        #expect(session.arguments == ["--persist", "--", "-i", "~/my key", "host", "--resume=x"])
        #expect(session.resumeCommand(hallows: "/My Apps/hallows")
            == "'/My Apps/hallows' +ssh --resume=t --persist -- -i '~/my key' host --resume=x")
    }

    @Test func notPlusSSH() {
        #expect(PersistSession(argv: ["hallows", "+version", "--persist"], tag: "t") == nil)
        #expect(PersistSession(argv: ["ssh", "host"], tag: "t") == nil)
        #expect(PersistSession(argv: ["hallows", "+ssh"], tag: "t") == nil)
    }

    @Test func invalidTag() {
        let argv = ["hallows", "+ssh", "--persist", "--", "host"]
        #expect(PersistSession(argv: argv, tag: "") == nil)
        #expect(PersistSession(argv: argv, tag: "a'b") == nil)
        #expect(PersistSession(argv: argv, tag: "a b") == nil)
        #expect(PersistSession(argv: argv, tag: String(repeating: "a", count: 65)) == nil)
    }

    @Test func codable() throws {
        let session = try #require(PersistSession(
            argv: ["hallows", "+ssh", "--persist", "--", "host"], tag: "abc"))
        let data = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(PersistSession.self, from: data) == session)
    }
}

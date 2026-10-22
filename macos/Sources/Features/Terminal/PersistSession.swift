import Foundation

/// A session that `hallows +ssh --persist` keeps alive on a remote host, as
/// the terminal running it. It's saved with the terminal so that when Hallows
/// restores the terminal after a restart, even a crash or force quit, the
/// terminal reattaches the session it showed, rather than leaving the user
/// to pick it out from the others on the host.
///
/// It comes from the process table rather than from anything the terminal
/// reports, since anything running in the terminal, a remote host included,
/// can write to it, and the saved session is run on this Mac.
struct PersistSession: Codable, Equatable {
    /// What `+ssh` was run with after `+ssh` itself, without `--resume`.
    let arguments: [String]

    /// The tag `+ssh` gives `hallows-persist` to identify the terminal.
    let tag: String

    /// From the arguments of a `hallows +ssh` process (argv, including
    /// argv[0]) and the tag of the session it's attached to.
    init?(argv: [String], tag: String) {
        guard argv.count > 2, argv[1] == "+ssh", Self.isValidTag(tag) else { return nil }

        // `+ssh`'s own flags come first, up to `--` or the first argument
        // for ssh. Only those may be a `--resume` to replace.
        var arguments: [String] = []
        var ownFlags = true
        for arg in argv.dropFirst(2) {
            if ownFlags && (arg == "--" || !arg.hasPrefix("--")) { ownFlags = false }
            if ownFlags && arg.hasPrefix("--resume=") { continue }
            arguments.append(arg)
        }
        self.arguments = arguments
        self.tag = tag
    }

    /// The command line that reattaches the session, for a shell.
    func resumeCommand(hallows: String) -> String {
        ([hallows, "+ssh", "--resume=\(tag)"] + arguments)
            .map(Ghostty.Shell.quote)
            .joined(separator: " ")
    }

    /// The `hallows` command the shell integration runs `+ssh` with.
    static var hallowsExecutable: String? {
        Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("hallows")
            .path
    }

    /// What `hallows-persist attach` accepts as a tag.
    private static func isValidTag(_ tag: String) -> Bool {
        !tag.isEmpty && tag.count <= 64 && tag.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }

    /// Find the persistent session running in the given foreground process
    /// group, if any.
    static func find(foregroundProcessGroup pgid: Int) -> PersistSession? {
        guard let tag = SSHTarget.find(foregroundProcessGroup: pgid)?.persistTag else { return nil }
        for pid in ProcessTable.pids(inGroup: pid_t(pgid)) {
            guard let argv = ProcessTable.arguments(of: pid),
                  let session = PersistSession(argv: argv, tag: tag) else { continue }
            return session
        }
        return nil
    }
}

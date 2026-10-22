import Foundation
import CryptoKit
import Darwin

/// An ssh connection running in a terminal, found from the terminal's foreground
/// processes, that the file tree can open connections of its own to.
struct SSHTarget: Hashable {
    /// The destination as given to ssh (a host, `user@host`, or an `ssh://` URI).
    let destination: String

    /// The options from the original command line needed to reach the same
    /// host the same way (config file, identity, port, jump hosts, ...).
    let options: [String]

    /// The `hallows-persist` tag of the session the terminal is attached to,
    /// if the connection was made by `hallows +ssh --persist`.
    let persistTag: String?

    /// The name to show for this host.
    var displayName: String {
        var host = destination
        if host.hasPrefix("ssh://") { host.removeFirst("ssh://".count) }
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        return host
    }

    /// ssh options that take an argument.
    private static let optionsWithArgument = Set("BbcDEeFIiJLlmOoPpQRSWw")

    /// Options worth carrying over to our own connections. Forwardings, ttys,
    /// remote commands and the like are left out.
    private static let keptOptions = Set("cFiJlmop")
    private static let keptFlags = Set("46C")

    /// `-o` options we must not carry over because they'd interfere with our
    /// connections or are set by `+ssh` for the interactive session only.
    private static let droppedConfigKeys: Set<String> = [
        "controlmaster", "controlpath", "controlpersist", "localcommand",
        "permitlocalcommand", "remotecommand", "requesttty", "sessiontype",
        "stdinnull", "forkafterauthentication", "setenv", "sendenv",
        "localforward", "remoteforward", "dynamicforward", "exitonforwardfailure",
        "serveraliveinterval", "serveralivecountmax", "connecttimeout", "batchmode",
        "forwardagent", "forwardx11", "forwardx11trusted", "clearallforwardings",
        "loglevel",
    ]

    /// Parse an ssh command line (argv, including argv[0]).
    init?(argv: [String]) {
        var options: [String] = []
        var destination: String?
        var command: [String] = []
        var i = 1
        while i < argv.count {
            let arg = argv[i]
            i += 1

            // OpenSSH takes options after the destination too, until the command.
            if arg.hasPrefix("-") && arg.count > 1 && command.isEmpty {
                if arg == "--" {
                    if destination == nil, i < argv.count {
                        destination = argv[i]
                        i += 1
                    }
                    command.append(contentsOf: argv[i...])
                    break
                }

                let chars = Array(arg.dropFirst())
                for (j, ch) in chars.enumerated() {
                    if Self.optionsWithArgument.contains(ch) {
                        let value: String
                        if j + 1 < chars.count {
                            value = String(chars[(j + 1)...])
                        } else if i < argv.count {
                            value = argv[i]
                            i += 1
                        } else {
                            return nil
                        }
                        if Self.keptOptions.contains(ch) && Self.keepOption(ch, value) {
                            options.append("-\(ch)")
                            options.append(value)
                        }
                        break
                    }
                    if Self.keptFlags.contains(ch) { options.append("-\(ch)") }
                }
                continue
            }

            if destination == nil {
                destination = arg
            } else {
                command.append(arg)
            }
        }

        guard let destination, !destination.isEmpty else { return nil }
        self.destination = destination
        self.options = options
        self.persistTag = Self.persistTag(in: command.joined(separator: " "))
    }

    private static func keepOption(_ option: Character, _ value: String) -> Bool {
        guard option == "o" else { return true }
        let key = value.split(whereSeparator: { $0 == "=" || $0 == " " || $0 == "\t" }).first ?? ""
        return !droppedConfigKeys.contains(key.lowercased())
    }

    /// The tag in `+ssh`'s remote command, `... hallows-persist" attach TAG [--reconnect]`.
    private static func persistTag(in command: String) -> String? {
        guard command.contains("hallows-persist"),
              let range = command.range(of: " attach ") else { return nil }
        let tag = command[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return tag.isEmpty ? nil : String(tag)
    }

    /// Find the ssh connection in the given foreground process group, if any.
    static func find(foregroundProcessGroup pgid: Int) -> SSHTarget? {
        var candidates: [SSHTarget] = []
        for pid in ProcessTable.pids(inGroup: pid_t(pgid)) {
            guard let argv = ProcessTable.arguments(of: pid),
                  let first = argv.first,
                  (first as NSString).lastPathComponent == "ssh",
                  let target = SSHTarget(argv: argv) else { continue }
            candidates.append(target)
        }

        // `+ssh` may run other ssh commands briefly while setting up, but
        // the session itself is the one attached to hallows-persist.
        return candidates.first { $0.persistTag != nil } ?? candidates.last
    }
}

enum ProcessTable {
    /// The processes in the process group.
    static func pids(inGroup pgid: pid_t) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }

        // Leave room for processes started in between.
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 8)
        size = procs.count * stride
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / stride).map { $0.kp_proc.p_pid }
    }

    /// The arguments the process was started with.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }

        // The buffer is argc, the executable path, padding NULs, then argv.
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }
        while index < size && buffer[index] == 0 { index += 1 }

        var args: [String] = []
        while args.count < argc && index < size {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }
}

/// Runs shell scripts on an `SSHTarget` over a connection shared through an
/// ssh ControlMaster, so each one takes a round trip rather than a new login.
///
/// Connections use BatchMode: the file tree can't answer password prompts,
/// so hosts must accept a key, an agent, or something like Tailscale SSH.
final class SSHConnection: @unchecked Sendable {
    let target: SSHTarget

    /// The ControlMaster socket. Unix socket paths are short, so this is a
    /// hash in the (per-user) temporary directory.
    private let controlPath: String

    private let masterLock = NSLock()

    /// When the ControlMaster was last known to be up.
    private var masterCheckedAt: Date?

    /// How to stop each ControlMaster we've used, by control path, so they
    /// can be stopped when Hallows quits rather than outliving it.
    private static var masters: [String: [String]] = [:]
    private static let mastersLock = NSLock()

    /// Stop every ControlMaster we've used. Called when Hallows quits.
    static func closeAll() {
        mastersLock.lock()
        let commands = Array(masters.values)
        masters = [:]
        mastersLock.unlock()
        DispatchQueue.concurrentPerform(iterations: commands.count) { i in
            _ = try? exec(commands[i], timeout: 2, captureStdout: false)
        }
    }

    private func registerMaster() {
        masterCheckedAt = Date()
        Self.mastersLock.lock()
        Self.masters[controlPath] = baseArguments + ["-O", "exit", target.destination]
        Self.mastersLock.unlock()
    }

    enum Failure: LocalizedError {
        case failed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .failed(let message): return message
            case .timedOut: return "The connection timed out."
            }
        }
    }

    init(target: SSHTarget) {
        self.target = target
        var hasher = SHA256()
        hasher.update(data: Data(target.destination.utf8))
        for option in target.options { hasher.update(data: Data(("\0" + option).utf8)) }
        let hash = hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        controlPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("hft-\(hash)")
    }

    private var baseArguments: [String] {
        target.options + [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
        ]
    }

    /// Arguments to run `remoteCommand` on the host from a terminal, sharing
    /// our connection when it's up.
    func interactiveArguments(remoteCommand: String) -> [String] {
        target.options + [
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlMaster=no",
            "-t", target.destination, remoteCommand,
        ]
    }

    /// Run a POSIX shell script on the host with the given arguments and
    /// return its standard output. The script is sent on standard input, so
    /// it doesn't matter what the remote login shell is.
    func run(script: String, arguments: [String], timeout: TimeInterval = 20) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { [self] in
            try ensureMaster()
            let prelude = "set -- " + arguments.map(Ghostty.Shell.quote).joined(separator: " ")
            let input = prelude + "\n{\n" + script + "\n} </dev/null\n"
            let result = try Self.exec(
                baseArguments + ["-o", "ControlMaster=no", "-T", target.destination, "sh -s"],
                input: Data(input.utf8),
                timeout: timeout)
            guard result.status == 0 else {
                // 255 is ssh itself failing, maybe because the master went
                // away; anything else is the script's own status.
                if result.status == 255 { forgetMaster() }
                throw Failure.failed(Self.message(result.stderr) ?? "The command failed on \(target.displayName).")
            }
            return result.stdout
        }.value
    }

    private func forgetMaster() {
        masterLock.lock()
        masterCheckedAt = nil
        masterLock.unlock()
    }

    /// Start the ControlMaster if it isn't running. It stays up for a while
    /// after the last use.
    private func ensureMaster() throws {
        masterLock.lock()
        defer { masterLock.unlock() }

        if let masterCheckedAt, masterCheckedAt.timeIntervalSinceNow > -30 { return }
        let check = try? Self.exec(baseArguments + ["-O", "check", target.destination], timeout: 5)
        if check?.status == 0 {
            registerMaster()
            return
        }

        // -f backgrounds the master once it's connected and logged in; its
        // output goes to /dev/null so nothing holds our pipes open. It
        // stops a minute after its last use, or when Hallows quits.
        let result = try Self.exec(
            baseArguments + [
                "-o", "ControlMaster=yes",
                "-o", "ControlPersist=60",
                "-N", "-f", target.destination,
            ],
            timeout: 30,
            captureStdout: false)
        guard result.status == 0 else {
            throw Failure.failed(
                Self.message(result.stderr) ?? "Couldn't connect to \(target.displayName).")
        }
        registerMaster()
    }

    private static func message(_ stderr: Data) -> String? {
        let text = String(decoding: stderr, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
            .joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private struct ExecResult {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    private static func exec(
        _ arguments: [String],
        input: Data? = nil,
        timeout: TimeInterval,
        captureStdout: Bool = true
    ) throws -> ExecResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        process.standardOutput = captureStdout ? stdout : FileHandle.nullDevice
        process.standardError = captureStdout ? stderr : FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        // Read both pipes concurrently so neither can fill up and block ssh.
        let group = DispatchGroup()
        var out = Data()
        var err = Data()
        if captureStdout {
            group.enter()
            DispatchQueue.global().async {
                out = stdout.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                err = stderr.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        if let input {
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }

        let deadline = DispatchTime.now() + timeout
        if exited.wait(timeout: deadline) == .timedOut {
            process.terminate()
            throw Failure.timedOut
        }
        if group.wait(timeout: deadline) == .timedOut { throw Failure.timedOut }
        process.waitUntilExit()
        return ExecResult(status: process.terminationStatus, stdout: out, stderr: err)
    }
}

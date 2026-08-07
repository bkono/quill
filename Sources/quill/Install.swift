import ArgumentParser
import Darwin
import Foundation

/// Manage quill's LaunchAgent so the daemon starts at login.
///
/// We deliberately do NOT use SMAppService.mainApp here — that requires a full
/// .app bundle. Since quill ships as a single CLI binary, a plain LaunchAgent
/// plist is the simpler, more honest mechanism.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install or remove the launch-at-login LaunchAgent."
    )

    @Flag(name: .long, help: "Register quill to start at login.")
    var launchAtLogin: Bool = false

    @Flag(name: .long, help: "Remove the launch-at-login agent.")
    var uninstall: Bool = false

    func run() throws {
        if launchAtLogin == uninstall {
            FileHandle.standardError.write(Data(
                "specify exactly one of --launch-at-login or --uninstall\n".utf8
            ))
            throw ExitCode(64)
        }

        if uninstall {
            try removeAgent()
        } else {
            try writeAgent()
        }
    }

    // MARK: -

    private static let label = "com.digimata.quill"

    private var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.label).plist")
    }

    private func writeAgent() throws {
        let binary = try resolveBinaryPath()

        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [binary, "run"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false] as [String: Any],
            "ProcessType": "Interactive",
            "StandardOutPath": "/tmp/quill.out.log",
            "StandardErrorPath": "/tmp/quill.err.log",
        ]

        let url = plistURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)

        // Best-effort bootstrap; ignore failure if already loaded.
        _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
        let result = runLaunchctl(["bootstrap", "gui/\(uid())", url.path])
        if result.status != 0 {
            FileHandle.standardError.write(Data(
                "warning: launchctl bootstrap exited \(result.status):\n\(result.stderr)\n".utf8
            ))
        }

        print("✓ launch-at-login installed")
        print("  plist:  \(url.path)")
        print("  binary: \(binary)")
        print("  logs:   /tmp/quill.out.log, /tmp/quill.err.log")
    }

    private func removeAgent() throws {
        let url = plistURL
        if FileManager.default.fileExists(atPath: url.path) {
            _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
            try FileManager.default.removeItem(at: url)
            print("✓ launch-at-login removed")
        } else {
            print("nothing to remove (no agent at \(url.path))")
        }
    }

    private func resolveBinaryPath() throws -> String {
        if let path = Self.currentExecutablePath() {
            return path
        }
        if let path = Self.findExecutableOnPath(named: "quill") {
            return path
        }
        FileHandle.standardError.write(Data(
            "couldn't locate the quill binary. ensure quill is installed and on your PATH.\n".utf8
        ))
        throw ExitCode(1)
    }

    /// Resolved path of the running quill binary.
    private static func currentExecutablePath() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        var size = UInt32(buffer.count)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }

        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        let path: String
        if realpath(buffer, &resolved) != nil {
            path = cString(resolved)
        } else {
            path = cString(buffer)
        }
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private static func cString(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Walk `$PATH` for an executable named `quill`.
    private static func findExecutableOnPath(named name: String) -> String? {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in pathEnv.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(dir))
                .appendingPathComponent(name)
                .resolvingSymlinksInPath()
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }

    private func uid() -> uid_t { getuid() }

    private func runLaunchctl(_ args: [String]) -> (status: Int32, stderr: String) {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = args
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        do {
            try task.run()
        } catch {
            return (-1, "\(error)")
        }
        task.waitUntilExit()
        let err = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (task.terminationStatus, err)
    }
}

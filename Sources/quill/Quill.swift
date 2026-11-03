import AppKit
import ArgumentParser
import Foundation

@main
struct Quill: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quill",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [Run.self, Doctor.self, Install.self, Models.self, ImportMuesli.self, Summarize.self],
        defaultSubcommand: Run.self
    )
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() async throws {
        // Async CLI subcommands may start on a cooperative executor. AppKit's
        // application/run loop must still be created and driven on the main thread.
        try await MainActor.run { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = AppController(root: root)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { controller.shutdown() }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data(
            "quill up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        app.run()
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() async throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        do {
            if let settings = try Config.summarySettings() {
                let client = OllamaClient(settings: settings)
                let models = try await client.availableModels()
                print("Ollama installed models: \(models.joined(separator: ", "))")
                try await client.validateLocalModel()
                print("✓ summaries: \(settings.model) at \(settings.baseURL)")
            } else {
                print("summaries: disabled (opt in with quill import-muesli)")
            }
        } catch {
            print("✗ summaries: \(error)")
            throw ExitCode(1)
        }
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private enum RecordingTrigger: String {
        case menu
        case meetingPrompt = "meeting-prompt"
    }

    private enum RecordingStopTrigger: String {
        case menu
        case meetingPrompt = "meeting-prompt"
        case shutdown
    }

    private let root: URL
    private let menuBar = MenuBarController()
    private let transcription: TranscriptionCoordinator
    private let meetingAwareness = MeetingAwarenessCoordinator()
    private var session: RecordingSession?
    private var ticker: Timer?

    init(root: URL) {
        self.root = root
        let summaries: SummaryCoordinator?
        do {
            summaries = try Config.summarySettings().map { SummaryCoordinator(settings: $0) }
        } catch {
            summaries = nil
            FileHandle.standardError.write(Data("summaries disabled: \(error)\n".utf8))
            notifyUser(title: "quill — summary configuration error", body: "Recording remains available. Run quill doctor.")
        }
        transcription = TranscriptionCoordinator(summaries: summaries)
        if let summaries {
            Task {
                await summaries.setStatusHandler { status in
                    switch status {
                    case .idle: notifyUser(title: "quill — meeting notes ready", body: "summary.md is saved beside your transcript.")
                    case .failed(let session):
                        notifyUser(title: "quill — summary failed", body: "\(session): transcript saved; see summary.log or retry quill summarize.")
                    case .summarizing: break
                    }
                }
                do { try await summaries.resumePending(root: root) }
                catch { FileHandle.standardError.write(Data("cannot resume summaries: \(error)\n".utf8)) }
            }
        }
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.update(recording: false, elapsed: nil)

        meetingAwareness.isRecordingProvider = { [weak self] in self?.session != nil }
        meetingAwareness.onStartRecording = { [weak self] in
            self?.startIfIdle(trigger: .meetingPrompt)
        }
        meetingAwareness.onStopRecording = { [weak self] in
            self?.stopIfRecording(trigger: .meetingPrompt)
        }
        if Config.meetingAwarenessEnabled() {
            meetingAwareness.start()
        }

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        meetingAwareness.stop()
        stopIfRecording(trigger: .shutdown)
        NSApp.terminate(nil)
    }

    private func toggle() {
        if session == nil {
            startIfIdle(trigger: .menu)
        } else {
            stopIfRecording(trigger: .menu)
        }
    }

    /// Start-only boundary used by both the menu and actionable meeting prompt.
    /// Unlike toggle(), repeated or stale prompt actions can never stop a live
    /// session.
    private func startIfIdle(trigger: RecordingTrigger) {
        guard session == nil else { return }
        do {
            let newSession = try RecordingSession(root: root)
            try newSession.start()
            session = newSession
            FileHandle.standardError.write(Data(
                "● recording source=\(trigger.rawValue) → \(newSession.dir.path)\n".utf8
            ))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "quill — recording failed", body: "\(error)")
            return
        }

        meetingAwareness.recordingStateChanged()
        menuBar.update(recording: true, elapsed: "0:00")
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Stop-only boundary used by the menu, shutdown, and the token-guarded
    /// meeting-ended prompt. Repeated or stale actions are harmless.
    private func stopIfRecording(trigger: RecordingStopTrigger) {
        guard let session else { return }
        session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped source=\(trigger.rawValue) · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        meetingAwareness.recordingStateChanged()
        ticker?.invalidate()
        ticker = nil
        menuBar.update(recording: false, elapsed: nil)

        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "transcribing \(name) · \(queued) queued" : "transcribing \(name)"
            )
        case .failed(let name):
            menuBar.updateTranscription("transcription failed · \(name)")
        }
    }

    private func tick() {
        guard let session else { return }
        menuBar.update(
            recording: true,
            elapsed: Self.format(Date().timeIntervalSince(session.startedAt))
        )
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

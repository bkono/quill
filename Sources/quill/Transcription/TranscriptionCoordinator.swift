import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, model: String, queued: Int)
        case failed(session: String)
    }

    private var queue: [URL] = []
    private var draining = false
    private var engine: TranscriptionEngine?
    private var engineSelection: SpeechModel?
    private var activeSession: URL?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?
    private var summaries: SummaryCoordinator?
    private let modelProvider: @Sendable () throws -> SpeechModel
    private let engineFactory: @Sendable (SpeechModel) throws -> any TranscriptionEngine
    private let enabled: @Sendable () -> Bool
    private let hookCommand: @Sendable () -> String?
    private let notify: @Sendable (String, String) -> Void

    init(
        summaries: SummaryCoordinator? = nil,
        modelProvider: @escaping @Sendable () throws -> SpeechModel = { try Config.speechModel() },
        engineFactory: @escaping @Sendable (SpeechModel) throws -> any TranscriptionEngine = { try TranscriptionCoordinator.makeEngine($0) },
        enabled: @escaping @Sendable () -> Bool = { Config.transcriptionEnabled() },
        hookCommand: @escaping @Sendable () -> String? = { Config.onStop() },
        notify: @escaping @Sendable (String, String) -> Void = { notifyUser(title: $0, body: $1) }
    ) {
        self.summaries = summaries
        self.modelProvider = modelProvider
        self.engineFactory = engineFactory
        self.enabled = enabled
        self.hookCommand = hookCommand
        self.notify = notify
    }

    /// A settings change affects jobs that have not started. An active job
    /// retains its original coordinator through durable intent and handoff.
    func updateSummaries(_ summaries: SummaryCoordinator?) {
        self.summaries = summaries
    }

    func waitUntilIdle() async {
        guard draining || !queue.isEmpty else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard enabled() else {
            runHook(for: sessionDir)
            return
        }
        guard !isScheduled(sessionDir) else { return }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        guard enabled() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        let pending = entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    && !fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !isScheduled(dir) {
            queue.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) untranscribed session(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    private func isScheduled(_ dir: URL) -> Bool {
        let path = dir.standardizedFileURL.path
        return activeSession?.standardizedFileURL.path == path
            || queue.contains { $0.standardizedFileURL.path == path }
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            // A toggle never interrupts the job already running. Leave later
            // sessions pending on disk, without firing their completion hooks.
            guard enabled() else {
                queue.removeAll()
                break
            }
            let dir = queue.removeFirst()
            activeSession = dir
            let jobSummaries = summaries
            do {
                let configured = try modelProvider()
                let selection = configured.engine == "parakeet" ? ParakeetEngine.localSelection(configured) : configured
                publish(.transcribing(session: dir.lastPathComponent,
                    model: "\(selection.engine)/\(selection.model)", queued: queue.count))
                try await transcribe(dir, selection: selection, summaries: jobSummaries)
                notify("quill — transcript ready", dir.lastPathComponent)
                runHook(for: dir)
                if let summaries = jobSummaries {
                    do { try await summaries.enqueue(dir) }
                    catch {
                        log(dir, "transcript ready, but summary could not be queued: \(error)")
                        notify("quill — summary failed", "Transcript saved. Retry with quill summarize.")
                    }
                }
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                notify("quill — transcription failed", "\(dir.lastPathComponent) — see transcribe.log")
            }
            activeSession = nil
        }
        await engine?.release()
        engine = nil
        engineSelection = nil
        draining = false
        // An enqueue during release belongs to the next drain, not an idle
        // completion. Explicit retry also never duplicates an active session.
        if !queue.isEmpty { drainIfIdle() }
        else {
            publish(lastFailure.map { .failed(session: $0) } ?? .idle)
            let waiters = idleWaiters
            idleWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    private func transcribe(_ dir: URL, selection: SpeechModel, summaries: SummaryCoordinator?) async throws {
        let meta = try SessionMeta.read(from: dir)
        let engine = try await preparedEngine(selection: selection)

        var merged: [Transcript.Segment] = []
        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            log(dir, "transcribing \(track.file) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                log(dir, "skipping \(track.file): \(error)")
                continue
            }
            let offset = TimeInterval(track.offsetMs) / 1000
            merged += segments.map {
                Transcript.Segment(
                    speaker: track.speaker,
                    start_ms: Int(($0.start + offset) * 1000),
                    end_ms: Int(($0.end + offset) * 1000),
                    text: $0.text
                )
            }
        }
        merged.sort { $0.start_ms < $1.start_ms }

        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged
        )
        // Persist intent first: after transcript.json exists the ASR recovery
        // scan excludes this session, so a later summary marker would leave a
        // crash window in which neither queue could recover the handoff.
        if let summaries {
            do { try await summaries.recordIntent(dir) }
            catch { log(dir, "could not persist summary intent: \(error)") }
        }
        try transcript.write(to: dir)
        log(dir, "done — \(merged.count) segments")
    }

    private func preparedEngine(selection: SpeechModel) async throws -> TranscriptionEngine {
        if let engine, let previous = engineSelection,
           previous.engine == selection.engine, previous.model == selection.model,
           previous.directory?.standardizedFileURL.path == selection.directory?.standardizedFileURL.path {
            return engine
        }
        await engine?.release()
        engine = nil
        engineSelection = nil
        let candidate = try engineFactory(selection)
        do { try await candidate.prepare() }
        catch { await candidate.release(); throw error }
        engine = candidate
        engineSelection = selection
        return candidate
    }

    private nonisolated static func makeEngine(_ selection: SpeechModel) throws -> any TranscriptionEngine {
        do { try selection.validateCache() }
        catch { throw SetupError("\(error) Open Models & Notes to choose a cached model or restore its existing assets.") }
        switch selection.engine {
        case "whisperkit":
            guard let directory = selection.directory else { throw SetupError("Choose a cached model in Models & Notes.") }
            return WhisperEngine(model: selection.model, modelFolder: directory)
        case "parakeet-unified":
            guard let directory = selection.directory else { throw SetupError("Choose a cached model in Models & Notes.") }
            return UnifiedEngine(model: "parakeet-unified-en-0.6b-coreml", modelFolder: directory)
        default:
            return ParakeetEngine(selection: selection)
        }
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = hookCommand() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
private struct SessionMeta {
    struct Track {
        let file: String
        let speaker: String
        let offsetMs: Int
    }

    let tracks: [Track]

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0 —
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(file: mic, speaker: "me", offsetMs: offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append(Track(file: system, speaker: "them", offsetMs: offsets["system"] ?? 0))
        }
        return SessionMeta(tracks: tracks)
    }
}

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized.
private struct Transcript: Codable {
    struct Segment: Codable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    let engine: String
    let model: String
    let created_at: String
    let segments: [Segment]

    /// Write transcript.json and render transcript.md. Both writes are atomic
    /// (temp file + rename), so a partially written transcript never exists on
    /// disk — resumePending treats presence of transcript.json as "done".
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        try Data(rendered(title: dir.lastPathComponent).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
    }

    private func rendered(title: String) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))", ""]
        for seg in segments {
            lines.append("**[\(Self.clock(seg.start_ms))] \(seg.speaker):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

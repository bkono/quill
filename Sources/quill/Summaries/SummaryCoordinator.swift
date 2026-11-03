import Foundation

/// An independent queue: Ollama latency/failure never holds up recording or transcription.
/// Only explicitly queued sessions receive a durable marker; enabling summaries does not
/// send the user's entire historical recordings collection to a model.
actor SummaryCoordinator {
    enum Status: Sendable, Equatable {
        case idle
        case summarizing(session: String)
        case failed(session: String)
    }

    private let client: OllamaClient
    private var queue: [URL] = []
    private var active: URL?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var statusHandler: (@Sendable (Status) -> Void)?
    static let pendingFilename = ".summary-pending"

    init(settings: OllamaSettings, client: OllamaClient? = nil) {
        self.client = client ?? OllamaClient(settings: settings)
    }

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Persist the handoff before transcript.json becomes the transcription queue's
    /// completion marker. On restart, an intent without a transcript waits for ASR.
    func recordIntent(_ dir: URL) throws {
        try Data().write(to: dir.appendingPathComponent(Self.pendingFilename), options: .atomic)
    }

    func enqueue(_ dir: URL) throws {
        guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent("summary.md").path) else {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(Self.pendingFilename))
            return
        }
        try recordIntent(dir)
        guard active != dir, !queue.contains(dir) else { return }
        queue.append(dir)
        startIfIdle()
    }

    func resumePending(root: URL) throws {
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for dir in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let fm = FileManager.default
            if fm.fileExists(atPath: dir.appendingPathComponent(Self.pendingFilename).path),
               fm.fileExists(atPath: dir.appendingPathComponent("transcript.json").path) {
                do {
                    try enqueue(dir)
                } catch {
                    log(dir, "summary could not be resumed: \(error)")
                    statusHandler?(.failed(session: dir.lastPathComponent))
                }
            }
        }
    }

    /// CLI entry point for a selected existing session; failures retain a retry marker.
    /// Run this on a separate coordinator from the daemon's automatic queue.
    func summarize(_ dir: URL, overwrite: Bool = false) async throws {
        let output = dir.appendingPathComponent("summary.md")
        if !overwrite, FileManager.default.fileExists(atPath: output.path) { return }
        let marker = dir.appendingPathComponent(Self.pendingFilename)
        try Data().write(to: marker, options: .atomic)
        do {
            let data = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
            let transcript = try JSONDecoder().decode(SummaryTranscript.self, from: data)
            let speech = transcript.segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !speech.isEmpty else { throw OllamaError.emptyTranscript }
            let input = speech.map { "[\($0.start_ms)ms] \($0.speaker): \($0.text)" }.joined(separator: "\n")
            let notes = try await client.summarize(input)
            let document = "# Meeting notes\n\nModel: \(client.settings.model) (local Ollama)\n\n\(notes)\n"
            try Data(document.utf8).write(to: output, options: .atomic)
            try? FileManager.default.removeItem(at: marker)
            log(dir, "summary ready")
        } catch {
            log(dir, "summary failed: \(error)")
            throw error
        }
    }

    func waitUntilIdle() async {
        guard active != nil || !queue.isEmpty else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func startIfIdle() {
        guard active == nil, !queue.isEmpty else { return }
        let dir = queue.removeFirst()
        active = dir
        Task { await process(dir) }
    }

    private func process(_ dir: URL) async {
        statusHandler?(.summarizing(session: dir.lastPathComponent))
        do {
            try await summarize(dir)
            statusHandler?(.idle)
        } catch {
            statusHandler?(.failed(session: dir.lastPathComponent))
        }
        active = nil
        startIfIdle()
        if active == nil {
            let completed = waiters
            waiters = []
            for waiter in completed { waiter.resume() }
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let data = Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8)
        let url = dir.appendingPathComponent("summary.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

private struct SummaryTranscript: Decodable {
    struct Segment: Decodable {
        let speaker: String
        let start_ms: Int
        let text: String
    }
    let segments: [Segment]
}

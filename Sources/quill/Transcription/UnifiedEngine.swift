import AVFoundation
import FluidAudio
import Foundation

/// Reuses Muesli's Parakeet Unified offline Core ML bundles in place. This
/// adapter never invokes FluidAudio's downloading or cache-repair overload.
actor UnifiedEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        case notPrepared
        case unreadableAudio(URL)

        var description: String {
            switch self {
            case .notPrepared: return "parakeet-unified engine used before prepare()"
            case .unreadableAudio(let url):
                return "unreadable or empty audio \(url.lastPathComponent)"
            }
        }
    }

    nonisolated let name = "parakeet-unified"
    nonisolated let model: String
    private let modelFolder: URL
    private var manager: UnifiedAsrManager?

    init(model: String, modelFolder: URL) {
        self.model = model
        self.modelFolder = modelFolder
    }

    func prepare() async throws {
        guard manager == nil else { return }
        try Task.checkCancellation()
        let manager = UnifiedAsrManager()
        // `from:` only loads the supplied compiled bundles and vocabulary.
        // `to:` downloads and may purge the cache on failure; do not use it.
        try await manager.loadModels(from: modelFolder)
        try Task.checkCancellation()
        self.manager = manager
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        guard let manager else { throw EngineError.notPrepared }
        try Task.checkCancellation()

        // Keep empty/unreadable tracks away from the audio conversion path.
        let probe = try AVAudioFile(forReading: audio)
        guard probe.length > 0 else { throw EngineError.unreadableAudio(audio) }
        let samples = try AudioConverter().resampleAudioFile(audio)
        guard !samples.isEmpty else { throw EngineError.unreadableAudio(audio) }

        let result = try await manager.transcribeWithTimings(samples)
        try Task.checkCancellation()
        let words = buildWordTimings(from: result.tokenTimings)
        if !words.isEmpty { return ParakeetEngine.segments(from: words) }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [TranscriptSegment(
            start: 0, end: Double(samples.count) / 16_000, text: text
        )]
    }

    func release() async {
        if let manager { await manager.cleanup() }
        manager = nil
    }
}

import Foundation
import Testing
@testable import quill

@Suite struct MuesliImportTests {
    private func fixture() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func fill(_ model: SpeechModel) throws {
        for name in model.requiredFiles {
            for file in name.hasSuffix(".mlmodelc") ? [name + "/coremldata.bin", name + "/weights/weight.bin"] : [name] {
                let url = model.directory!.appendingPathComponent(file)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([1]).write(to: url)
            }
        }
    }

    private let muesli: [String: Any] = [
        "meeting_transcription_backend": "fluidaudio",
        "meeting_transcription_model": "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        "meeting_summary_backend": "ollama", "ollama_model": "qwen3:8b",
        "ollama_url": "http://localhost:11434", "openrouter_api_key": "fixture-secret"
    ]

    @Test func defaultsRemainV2AndUnknownSelectionsFail() throws {
        let original = try SpeechModel.parse([:])
        #expect(original.model == "v2")
        #expect(original.directory == nil)
        #expect(throws: (any Error).self) { try SpeechModel.parse(["engine": "whisper.cpp"]) }
        #expect(throws: (any Error).self) { try SpeechModel.parse(["engine": "parakeet", "model": "typo"]) }
    }

    @Test func importsSelectedMeetingModelAndPreservesUnrelatedConfig() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let model = try SpeechModel.fromMuesli(muesli, home: home)
        try fill(model)
        let existing: [String: Any] = ["recordings_dir": "~/Meetings", "on_stop": "fixture-hook",
            "meeting_awareness": ["enabled": false]]
        let result = try MuesliImport.proposal(muesli: muesli, existing: existing, home: home, replace: false)
        #expect(result["recordings_dir"] as? String == "~/Meetings")
        #expect(result["on_stop"] as? String == "fixture-hook")
        #expect((result["meeting_awareness"] as? [String: Bool])?["enabled"] == false)
        #expect(result["openrouter_api_key"] == nil)
        let speech = try #require(result["transcription"] as? [String: Any])
        #expect(speech["model"] as? String == "v3")
        #expect(speech["model_directory"] as? String == model.directory?.path)
        let notes = try #require(result["summaries"] as? [String: Any])
        #expect(notes["model"] as? String == "qwen3:8b")
        #expect(notes["enabled"] as? Bool == true)
    }

    @Test func existingSelectionsRequireExplicitReplacementAndKeepDisabledFlag() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        try fill(SpeechModel.fromMuesli(muesli, home: home))
        let existing: [String: Any] = ["transcription": ["enabled": false, "engine": "parakeet"]]
        #expect(throws: (any Error).self) {
            try MuesliImport.proposal(muesli: muesli, existing: existing, home: home, replace: false)
        }
        let result = try MuesliImport.proposal(muesli: muesli, existing: existing, home: home, replace: true)
        #expect((result["transcription"] as? [String: Any])?["enabled"] as? Bool == false)
    }

    @Test func missingInterruptedAndTruncatedCachesAreRejected() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let model = try SpeechModel.fromMuesli(muesli, home: home)
        #expect(throws: (any Error).self) { try model.validateCache() }
        try fill(model)
        try model.validateCache()
        let pending = model.directory!.appendingPathComponent(".muesli-download-state.json")
        try Data().write(to: pending)
        #expect(throws: (any Error).self) { try model.validateCache() }
        try FileManager.default.removeItem(at: pending)
        let weight = model.directory!.appendingPathComponent("Encoder.mlmodelc/weights/weight.bin")
        try Data().write(to: weight)
        #expect(throws: (any Error).self) { try model.validateCache() }
    }

    @Test func manifestSizeMismatchAndUnsupportedModelsFailWithoutFallback() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let model = try SpeechModel.fromMuesli(muesli, home: home)
        try fill(model)
        let manifest = #"{"files":[{"relativePath":"parakeet_vocab.json","expectedByteCount":99}]}"#
        try Data(manifest.utf8).write(to: model.directory!.appendingPathComponent(".muesli-managed-model-complete.json"))
        #expect(throws: (any Error).self) { try model.validateCache() }
        var unknown = muesli
        unknown["meeting_transcription_backend"] = "qwen"
        #expect(throws: (any Error).self) { try SpeechModel.fromMuesli(unknown, home: home) }
    }

    @Test func remoteSummarySettingsAreRejectedAndOtherProvidersAreNotImported() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        try fill(SpeechModel.fromMuesli(muesli, home: home))
        var remote = muesli
        remote["ollama_url"] = "https://example.com"
        #expect(throws: (any Error).self) {
            try MuesliImport.proposal(muesli: remote, existing: [:], home: home, replace: false)
        }
        remote["meeting_summary_backend"] = "openrouter"
        let result = try MuesliImport.proposal(muesli: remote, existing: [:], home: home, replace: false)
        #expect(result["summaries"] == nil)
    }

    @Test func configWriteBacksUpExactOriginalAndDetectsConcurrentEdits() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent("config.json")
        let original = Data(#"{"on_stop":"my-hook"}"#.utf8)
        try original.write(to: path)
        let backup = try #require(try MuesliImport.write(["on_stop": "my-hook", "summaries": ["enabled": true]],
            to: path, expectedOriginal: original))
        #expect(try Data(contentsOf: backup) == original)
        #expect(throws: (any Error).self) {
            try MuesliImport.write([:], to: path, expectedOriginal: original)
        }
        #expect(try MuesliImport.read(path)["on_stop"] as? String == "my-hook")
    }
}

import Foundation
import Testing
@testable import quill

struct WhisperEngineTests {
    private func temporaryHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func tokenizerFiles(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["tokenizer.json", "tokenizer_config.json"] {
            try Data("{}".utf8).write(to: directory.appendingPathComponent(name))
        }
    }

    @Test func resolvesQuantizedModelToSharedTokenizerFamily() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let shared = home.appendingPathComponent("Documents/huggingface/models/openai/whisper-large-v3")
        try tokenizerFiles(at: shared)
        let actual = try WhisperEngine.tokenizerDirectory(
            model: "openai_whisper-large-v3-v20240930_626MB",
            modelFolder: home.appendingPathComponent("model"), home: home
        )
        #expect(actual.path == shared.path)
    }

    @Test func acceptsBundledTokenizerButRejectsPartialCache() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let modelFolder = home.appendingPathComponent("model")
        try tokenizerFiles(at: modelFolder)
        #expect(try WhisperEngine.tokenizerDirectory(model: "small.en", modelFolder: modelFolder, home: home) == modelFolder)
        try FileManager.default.removeItem(at: modelFolder.appendingPathComponent("tokenizer_config.json"))
        #expect(throws: WhisperEngine.EngineError.self) {
            try WhisperEngine.tokenizerDirectory(model: "small.en", modelFolder: modelFolder, home: home)
        }
    }

    @Test func rejectsPathTraversalAndUnknownFamilies() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try tokenizerFiles(at: home)
        for model in ["large-v3/../../tiny", "something-else"] {
            #expect(throws: WhisperEngine.EngineError.self) {
                try WhisperEngine.tokenizerDirectory(model: model, modelFolder: home, home: home)
            }
        }
    }

    @Test func corruptCachedTokenizerFailsBeforeModelLoading() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try tokenizerFiles(at: home)
        try Data("{invalid".utf8).write(to: home.appendingPathComponent("tokenizer.json"))
        let engine = WhisperEngine(model: "tiny", modelFolder: home, home: home)
        await #expect(throws: (any Error).self) { try await engine.prepare() }
        // A failed preparation never leaves a usable, partially loaded engine.
        await #expect(throws: WhisperEngine.EngineError.self) { try await engine.transcribe(home.appendingPathComponent("unread.caf")) }
    }

    @Test func preservesSpecialTokenIDsAcrossWhisperVocabularies() throws {
        // OpenAI Whisper tokenizer.json protocol IDs: English vocab is shifted
        // by one; v3 inserts another language before the task/no-speech tokens.
        for (english, v3) in [(false, false), (true, false), (false, true)] {
            let shift = english ? -1 : 0
            let v3Shift = v3 ? 1 : 0
            let noSpeechKey = v3 ? "<|nospeech|>" : "<|nocaptions|>"
            let vocab = [
                "<|endoftext|>": 50257 + shift,
                "<|en|>": 50259 + shift,
                "<|startoftranscript|>": 50258 + shift,
                "<|translate|>": 50358 + shift + v3Shift,
                "<|transcribe|>": 50359 + shift + v3Shift,
                "<|startofprev|>": 50361 + shift + v3Shift,
                noSpeechKey: 50362 + shift + v3Shift,
                "<|notimestamps|>": 50363 + shift + v3Shift,
                "<|0.00|>": 50364 + shift + v3Shift,
                "Ġ": 220,
            ]
            let tokens = try LocalWhisperTokenizer.makeSpecialTokens { vocab[$0] }
            #expect(tokens.noSpeechToken == vocab[noSpeechKey])
            #expect(tokens.endToken == vocab["<|endoftext|>"])
            #expect(tokens.timeTokenBegin == vocab["<|0.00|>"])
            #expect(tokens.whitespaceToken == 220)
            var incomplete = vocab
            incomplete.removeValue(forKey: noSpeechKey)
            #expect(throws: WhisperEngine.EngineError.self) {
                try LocalWhisperTokenizer.makeSpecialTokens { incomplete[$0] }
            }
        }
    }

}

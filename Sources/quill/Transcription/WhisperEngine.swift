import AVFoundation
import Foundation
import NaturalLanguage
@preconcurrency import WhisperKit

/// Uses Muesli's existing WhisperKit Core ML assets without downloading or
/// repairing them. Tokenizers need separate handling: WhisperKit's download:false
/// only applies to model weights, not its normal tokenizer loader.
actor WhisperEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        case notPrepared
        case unreadableAudio(URL)
        case missingTokenizer(String)
        case invalidTokenizer(String)

        var description: String {
            switch self {
            case .notPrepared: return "WhisperKit engine used before prepare()"
            case .unreadableAudio(let url): return "unreadable or empty audio \(url.lastPathComponent)"
            case .missingTokenizer(let model):
                return "cached tokenizer missing for \(model); restore its tokenizer files or choose another cached model in Models & Notes"
            case .invalidTokenizer(let token): return "cached Whisper tokenizer is missing required token \(token)"
            }
        }
    }

    nonisolated let name = "whisperkit"
    nonisolated let model: String
    private let modelFolder: URL
    private let home: URL
    private var whisper: WhisperKit?

    init(model: String, modelFolder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.model = model
        self.modelFolder = modelFolder
        self.home = home
    }

    func prepare() async throws {
        guard whisper == nil else { return }
        let folder = try Self.tokenizerDirectory(model: model, modelFolder: modelFolder, home: home)
        // This overload reads local JSON only and throws on corrupt/missing files.
        // Do not use ModelUtilities.loadTokenizer: it repairs failures over HTTP.
        let local = try await AutoTokenizerWrapper.from(modelFolder: folder)
        let tokenizer = try LocalWhisperTokenizer(local)
        let instance = try await WhisperKit(WhisperKitConfig(
            modelFolder: modelFolder.path,
            verbose: false,
            prewarm: false,
            load: false,
            download: false
        ))
        instance.tokenizer = tokenizer
        do {
            try await instance.loadModels()
            instance.textDecoder.isModelMultilingual = instance.textDecoder.logitsSize != 51864
            whisper = instance
        } catch {
            await instance.unloadModels()
            throw error
        }
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        guard let whisper else { throw EngineError.notPrepared }
        let probe = try AVAudioFile(forReading: audio)
        guard probe.length > 0 else { throw EngineError.unreadableAudio(audio) }
        let results: [TranscriptionResult] = try await whisper.transcribe(
            audioPath: audio.path,
            decodeOptions: DecodingOptions(
                verbose: false,
                detectLanguage: whisper.textDecoder.isModelMultilingual,
                skipSpecialTokens: true,
                withoutTimestamps: false,
                wordTimestamps: false,
                concurrentWorkerCount: 1
            )
        )
        return results.flatMap(\.segments).compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(start: TimeInterval(segment.start), end: TimeInterval(segment.end), text: text)
        }
    }

    func release() async {
        if let whisper { await whisper.unloadModels() }
        whisper = nil
    }

    /// WhisperKit infers a tokenizer family from model shapes, so compressed
    /// variants still use the ordinary OpenAI tokenizer. Mirror its known cache
    /// layouts, but never guess a different model or fetch a missing tokenizer.
    nonisolated static func tokenizerDirectory(
        model: String,
        modelFolder: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        let variant = model.replacingOccurrences(of: "openai_whisper-", with: "")
        guard !variant.contains("/"), !variant.contains("\\"), !variant.contains("..") else {
            throw EngineError.missingTokenizer(model)
        }
        let family: String
        if variant.hasPrefix("large-v3") { family = "large-v3" }
        else if variant.hasPrefix("large-v2") || variant == "large" || variant.hasPrefix("large-v1") { family = "large-v2" }
        else if let match = ["tiny.en", "base.en", "small.en", "medium.en", "tiny", "base", "small", "medium"].first(where: {
            variant == $0 || variant.hasPrefix($0 + "_") || variant.hasPrefix($0 + "-")
        }) { family = match }
        else { throw EngineError.missingTokenizer(model) }
        let relative = "models/openai/whisper-\(family)"
        let candidates = [
            home.appendingPathComponent("Documents/huggingface/\(relative)"),
            modelFolder,
            modelFolder.appendingPathComponent(relative),
        ]
        guard let directory = candidates.first(where: { candidate in
            ["tokenizer.json", "tokenizer_config.json"].allSatisfy {
                FileManager.default.isReadableFile(atPath: candidate.appendingPathComponent($0).path)
            }
        }) else { throw EngineError.missingTokenizer(model) }
        return directory
    }
}

/// WhisperKit's public tokenizer factory accepts a local directory, but its
/// WhisperTokenizerWrapper initializer is internal. This bridge keeps tokenizer
/// failures local rather than invoking the library's network fallback.
struct LocalWhisperTokenizer: WhisperTokenizer {
    let underlying: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(_ underlying: TokenizerWrapper) throws {
        self.underlying = underlying
        specialTokens = try Self.makeSpecialTokens(lookup: underlying.convertTokenToId)
        allLanguageTokens = Set(Constants.languages.values.compactMap {
            underlying.convertTokenToId("<|\($0)|>")
        })
    }

    static func makeSpecialTokens(lookup: (String) -> Int?) throws -> SpecialTokens {
        func id(_ token: String) throws -> Int {
            guard let value = lookup(token) else {
                throw WhisperEngine.EngineError.invalidTokenizer(token)
            }
            return value
        }
        // Pre-v3 OpenAI tokenizers call this token nocaptions. Its numeric ID
        // also differs for English-only vocabularies; do not use a base-model
        // fallback ID for a missing spelling.
        let noSpeech = try lookup("<|nospeech|>") ?? id("<|nocaptions|>")
        return try SpecialTokens(
            endToken: id("<|endoftext|>"),
            englishToken: id("<|en|>"),
            noSpeechToken: noSpeech,
            noTimestampsToken: id("<|notimestamps|>"),
            specialTokenBegin: id("<|endoftext|>"),
            startOfPreviousToken: id("<|startofprev|>"),
            startOfTranscriptToken: id("<|startoftranscript|>"),
            timeTokenBegin: id("<|0.00|>"),
            transcribeToken: id("<|transcribe|>"),
            translateToken: id("<|translate|>"),
            whitespaceToken: id("Ġ")
        )
    }

    func encode(text: String) -> [Int] { underlying.encode(text: text) }
    func decode(tokens: [Int]) -> String { underlying.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { underlying.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { underlying.convertIdToToken(id) }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(decode(tokens: tokenIds.filter { $0 < specialTokens.specialTokenBegin }))
        let usesSpaces = !["zh", "ja", "th", "lo", "my", "yue"].contains(recognizer.dominantLanguage?.rawValue ?? "")
        var words: [String] = []
        var groups: [[Int]] = []
        var pending: [Int] = []
        func append(_ text: String, tokens: [Int]) {
            let punctuation = !text.isEmpty && text.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
            if !usesSpaces || words.isEmpty || text.hasPrefix(" ") || punctuation || tokens.contains(where: { $0 >= specialTokens.specialTokenBegin }) {
                words.append(text)
                groups.append(tokens)
            } else {
                words[words.count - 1] += text
                groups[groups.count - 1] += tokens
            }
        }
        for token in tokenIds {
            pending.append(token)
            let text = decode(tokens: pending)
            // A Unicode scalar may span multiple BPE tokens. Delay incomplete
            // byte sequences; retain any literal replacement character at EOF.
            if !text.contains("\u{fffd}") {
                append(text, tokens: pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
        if !pending.isEmpty { append(decode(tokens: pending), tokens: pending) }
        return (words, groups)
    }
}

import FluidAudio
import Foundation

struct SetupError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

/// Explicit runtime + version + cache. Older configs retain Parakeet v2's
/// shared cache selection. Missing assets fail locally without downloading.
struct SpeechModel: Sendable {
    let engine: String
    let model: String
    let directory: URL?

    var parakeetVersion: AsrModelVersion {
        switch model {
        case "v3": .v3
        case "redux": .redux
        default: .v2
        }
    }

    static func parse(_ settings: [String: Any]) throws -> SpeechModel {
        let engine = settings["engine"] as? String ?? "parakeet"
        let model = settings["model"] as? String ?? (engine == "parakeet" ? "v2" : "")
        let path = settings["model_directory"] as? String
        let directory = path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        guard (engine == "parakeet" && ["v2", "v3", "redux"].contains(model))
            || (engine == "parakeet-unified" && model == "unified")
            || (engine == "whisperkit" && whisperVariants.contains(model)) else {
            throw SetupError("Unsupported transcription engine/model: \(engine)/\(model). Run quill models to list compatible cached models.")
        }
        if engine != "parakeet" && directory == nil {
            throw SetupError("\(engine) requires model_directory; run quill import-muesli.")
        }
        if let path, path.isEmpty { throw SetupError("model_directory cannot be empty.") }
        return SpeechModel(engine: engine, model: model, directory: directory)
    }

    static let whisperVariants = ["tiny", "tiny.en", "small", "small.en", "medium.en", "large-v3-v20240930_626MB"]

    var requiredFiles: [String] {
        switch engine {
        case "parakeet":
            return ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
                    model == "v2" ? "JointDecision.mlmodelc" : "JointDecisionv3.mlmodelc", "parakeet_vocab.json"]
        case "parakeet-unified":
            return ["parakeet_unified_encoder_int8.mlmodelc", "parakeet_unified_decoder.mlmodelc",
                    "parakeet_unified_joint_decision_single_step.mlmodelc", "vocab.json", "metadata.json"]
        default:
            return ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc",
                    "config.json", "generation_config.json"]
        }
    }

    func validateCache() throws {
        guard let directory else { return }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: directory.appendingPathComponent(".muesli-download-state.json").path) else {
            throw SetupError("Incomplete Muesli download at \(directory.path). Finish it in Muesli first.")
        }
        for file in requiredFiles {
            let paths = file.hasSuffix(".mlmodelc")
                ? [file + "/coremldata.bin", file + "/weights/weight.bin"] : [file]
            for path in paths {
                let url = directory.appendingPathComponent(path)
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                guard attrs?[.type] as? FileAttributeType == .typeRegular,
                      (attrs?[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
                    throw SetupError("Missing or empty model file: \(url.path). Restore these files or select another cached model in Models & Notes; Quill has not downloaded anything.")
                }
            }
        }
        if let files = fm.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let url as URL in files where url.pathExtension == "part" {
                throw SetupError("Partial model download at \(url.path). Finish it in Muesli first.")
            }
        }
        let marker = directory.appendingPathComponent(".muesli-managed-model-complete.json")
        if fm.fileExists(atPath: marker.path) {
            struct Marker: Decodable {
                struct File: Decodable { let relativePath: String; let expectedByteCount: Int64? }
                let files: [File]
            }
            let manifest = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: marker))
            guard !manifest.files.isEmpty else { throw SetupError("Empty Muesli model manifest at \(marker.path).") }
            for file in manifest.files {
                let url = directory.appendingPathComponent(file.relativePath).standardizedFileURL
                guard url.path.hasPrefix(directory.standardizedFileURL.path + "/"),
                      let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
                      file.expectedByteCount == nil || size.int64Value == file.expectedByteCount else {
                    throw SetupError("Incomplete Muesli model manifest at \(marker.path).")
                }
            }
        }
    }

    var configuration: [String: Any] {
        var values: [String: Any] = ["engine": engine, "model": model]
        if let directory { values["model_directory"] = directory.path }
        return values
    }

    static func cachedCandidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [SpeechModel] {
        let fluid = home.appendingPathComponent("Library/Application Support/FluidAudio/Models")
        var candidates = ["v2", "v3", "redux"].map { version in
            SpeechModel(engine: "parakeet", model: version, directory: fluid.appendingPathComponent(
                version == "redux" ? "parakeet-redux" : "parakeet-tdt-0.6b-\(version)"))
        }
        candidates.append(SpeechModel(engine: "parakeet-unified", model: "unified",
            directory: fluid.appendingPathComponent("parakeet-unified-en-0.6b-coreml")))
        let whisper = home.appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
        candidates += whisperVariants.map { SpeechModel(engine: "whisperkit", model: $0,
            directory: whisper.appendingPathComponent("openai_whisper-\($0)")) }
        return candidates
    }

    static func fromMuesli(_ json: [String: Any], home: URL) throws -> SpeechModel {
        guard let backend = json["meeting_transcription_backend"] as? String,
              let selected = json["meeting_transcription_model"] as? String else {
            throw SetupError("Muesli has no explicit meeting transcription selection. Select a meeting model in Muesli first.")
        }
        let engine: String
        let model: String
        switch (backend, selected) {
        case ("fluidaudio", "FluidInference/parakeet-tdt-0.6b-v2-coreml"): engine = "parakeet"; model = "v2"
        case ("fluidaudio", "FluidInference/parakeet-tdt-0.6b-v3-coreml"): engine = "parakeet"; model = "v3"
        case ("fluidaudio", "FluidInference/parakeet-redux-coreml"): engine = "parakeet"; model = "redux"
        case ("parakeet-unified", "FluidInference/parakeet-unified-en-0.6b-coreml"): engine = "parakeet-unified"; model = "unified"
        case ("whisper", _) where whisperVariants.contains(selected): engine = "whisperkit"; model = selected
        default: throw SetupError("Muesli meeting model \(backend)/\(selected) is not supported. Run quill models for compatible local choices; no fallback was selected.")
        }
        return cachedCandidates(home: home).first { $0.engine == engine && $0.model == model }!
    }
}

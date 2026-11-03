import CryptoKit
import Foundation

enum ModelCacheKind: String, Codable, Sendable {
    case fluidAudio = "Shared FluidAudio cache"
    case huggingFace = "Shared Hugging Face cache"
    case custom = "Custom model directory"
}

struct SetupModelInfo: Identifiable, Sendable {
    let id: String
    let engine: String
    let model: String
    let displayName: String
    let backendName: String
    let directory: URL
    let tokenizerDirectory: URL?
    let availabilityError: String?
    let cacheKind: ModelCacheKind
    let importedConfigFrom: URL?
    var isAvailable: Bool { availabilityError == nil }
}

struct SummarySetupSelection: Sendable {
    let enabled: Bool
    let model: String
    let url: String
    let validationError: String?
}

struct ImportProvenance: Codable, Sendable {
    let sourceConfigPath: String
    let importedAt: Date
    var speechEngine: String?
    var speechModel: String?
    var modelDirectory: String?
    var summaryModel: String?
    var summaryURL: String?
    var summarySourceConfigPath: String? = nil
    var summaryImportedAt: Date? = nil
}

struct ModelSetupState: Codable, Sendable {
    enum Outcome: String, Codable, Sendable { case absent, offered, accepted, rejected, dismissed, failed }
    let outcome: Outcome
    let updatedAt: Date
    let offeredAt: Date?
    let sourceConfigPath: String?
    let offerID: UUID?
    let error: String?
}

struct ModelSetupSnapshot: Sendable {
    let configURL: URL
    let transcriptionEnabled: Bool
    let selectedModel: SetupModelInfo?
    let availableModels: [SetupModelInfo]
    let summaries: SummarySetupSelection?
    let provenance: ImportProvenance?
    let configError: String?
    let onboarding: ModelSetupState?
}

struct ImportOffer: Identifiable, Sendable {
    let id: UUID
    let sourceURL: URL?
    let alternativeSources: [URL]
    let model: SetupModelInfo?
    let summaries: SummarySetupSelection?
    let replacesExisting: Bool
    let warnings: [String]
    let error: String?
    var canAccept: Bool { error == nil && proposalData != nil }
    fileprivate let originalConfig: Data?
    fileprivate let sourceDigest: Data?
    fileprivate let proposalData: Data?
}

/// All discovery/validation and writes happen on this actor, never on AppKit's
/// main actor. Only typed snapshots and opaque JSON bytes cross the boundary.
actor ModelSetupStore {
    let home: URL
    let configURL: URL
    let stateURL: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, configURL: URL? = nil) {
        self.home = home
        let path = configURL ?? home.appendingPathComponent(".config/quill/config.json")
        self.configURL = path
        self.stateURL = path.deletingLastPathComponent().appendingPathComponent("model-setup-state.json")
    }

    func snapshot() -> ModelSetupSnapshot {
        var selected: SetupModelInfo?
        var summaries: SummarySetupSelection?
        var provenance: ImportProvenance?
        var configError: String?
        var transcriptionEnabled = true
        do {
            let json = try readConfig().json
            transcriptionEnabled = (json["transcription"] as? [String: Any])?["enabled"] as? Bool ?? true
            provenance = Self.provenance(in: json)
            summaries = Self.summarySelection(json["summaries"] as? [String: Any])
            selected = modelInfo(try SpeechModel.parse(json["transcription"] as? [String: Any] ?? [:]), provenance: provenance)
        } catch { configError = String(describing: error) }
        var models = SpeechModel.cachedCandidates(home: home).filter {
            FileManager.default.fileExists(atPath: $0.directory!.path)
        }.map { modelInfo($0, provenance: provenance) }
        if let selected, !models.contains(where: { $0.id == selected.id }) { models.append(selected) }
        return ModelSetupSnapshot(configURL: configURL, transcriptionEnabled: transcriptionEnabled, selectedModel: selected,
            availableModels: models, summaries: summaries, provenance: provenance,
            configError: configError, onboarding: readState())
    }

    /// Automatic discovery is a one-time offer, including absent/incomplete installs.
    /// A persisted offered state also prevents a crash or window dismissal nag loop.
    func beginOffer(automatic: Bool, sourceURL: URL? = nil) throws -> ImportOffer? {
        if automatic, FileManager.default.fileExists(atPath: stateURL.path) { return nil }
        if automatic, let receipt = try? readConfig().json, let prior = Self.provenance(in: receipt) {
            try writeState(outcome: .accepted, source: URL(fileURLWithPath: prior.sourceConfigPath))
            return nil
        }
        let sources = ["Muesli", "MuesliDev"].map {
            home.appendingPathComponent("Library/Application Support/\($0)/config.json")
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
        let chosen = sourceURL ?? sources.first
        guard let chosen else {
            try writeState(outcome: .absent)
            if automatic { return nil }
            return ImportOffer(id: UUID(), sourceURL: nil, alternativeSources: [], model: nil,
                summaries: nil, replacesExisting: false, warnings: [], error: "No Muesli configuration was found.",
                originalConfig: nil, sourceDigest: nil, proposalData: nil)
        }
        let id = UUID()
        // Persist before returning the offer, including its validation error.
        try writeState(outcome: .offered, source: chosen, offerID: id)
        let alternatives = sources.filter { $0 != chosen }
        var warnings = alternatives.isEmpty ? [] : ["Using \(chosen.path). Another Muesli configuration is also available."]
        var original: Data?
        var sourceData: Data?
        var model: SetupModelInfo?
        var summaries: SummarySetupSelection?
        var replaces = false
        do {
            let loaded = try readConfig()
            original = loaded.data
            sourceData = try Data(contentsOf: chosen)
            var muesli = try Self.object(sourceData!, at: chosen)
            model = modelInfo(try SpeechModel.fromMuesli(muesli, home: home), provenance: nil)
            if muesli["meeting_summary_backend"] as? String == "ollama" {
                do {
                    let settings = try OllamaSettings(model: muesli["ollama_model"] as? String ?? "",
                        baseURL: muesli["ollama_url"] as? String ?? "http://localhost:11434")
                    summaries = SummarySetupSelection(enabled: true, model: settings.model,
                        url: settings.baseURL.absoluteString, validationError: nil)
                } catch {
                    warnings.append("Speech settings can be imported, but summary settings were kept unchanged: \(error)")
                    muesli["meeting_summary_backend"] = ""
                }
            }
            replaces = loaded.json["transcription"] != nil || (summaries != nil && loaded.json["summaries"] != nil)
            let proposal = try MuesliImport.proposal(muesli: muesli, existing: loaded.json, home: home, replace: true)
            return ImportOffer(id: id, sourceURL: chosen, alternativeSources: alternatives,
                model: model, summaries: summaries, replacesExisting: replaces, warnings: warnings, error: nil,
                originalConfig: original, sourceDigest: sourceData.map { Data(SHA256.hash(data: $0)) },
                proposalData: try JSONSerialization.data(withJSONObject: proposal))
        } catch {
            return ImportOffer(id: id, sourceURL: chosen, alternativeSources: alternatives,
                model: model, summaries: summaries, replacesExisting: replaces, warnings: warnings,
                error: String(describing: error), originalConfig: original,
                sourceDigest: sourceData.map { Data(SHA256.hash(data: $0)) }, proposalData: nil)
        }
    }

    func accept(_ offer: ImportOffer) throws -> ModelSetupSnapshot {
        var configWasSaved = false
        do {
            guard offer.canAccept, let source = offer.sourceURL, let data = offer.proposalData,
                  let model = offer.model, readState()?.offerID == offer.id, readState()?.outcome == .offered else {
                throw SetupError("This import offer is unavailable or has expired. Try discovery again.")
            }
            guard try Data(SHA256.hash(data: Data(contentsOf: source))) == offer.sourceDigest else {
                throw SetupError("Muesli settings changed after the preview. Review a new import offer.")
            }
            let speech = SpeechModel(engine: model.engine, model: model.model, directory: model.directory)
            try validate(speech)
            var proposal = try Self.object(data, at: configURL)
            proposal = try Self.addingProvenance(to: proposal, source: source, importedSummaries: offer.summaries != nil)
            _ = try MuesliImport.write(proposal, to: configURL, expectedOriginal: offer.originalConfig)
            configWasSaved = true
            try writeState(outcome: .accepted, source: source, offerID: offer.id)
            return snapshot()
        } catch {
            if configWasSaved {
                throw SetupError("Quill configuration was saved at \(configURL.path), but the setup state could not be saved: \(error). Refresh to see the applied settings.")
            }
            if readState()?.offerID == offer.id, readState()?.outcome == .offered {
                try? writeState(outcome: .failed, source: offer.sourceURL, offerID: offer.id, error: String(describing: error))
            }
            throw error
        }
    }

    func decline(_ offer: ImportOffer) throws {
        try finishOffer(offer, outcome: .rejected)
    }

    func dismiss(_ offer: ImportOffer) throws {
        try finishOffer(offer, outcome: .dismissed)
    }

    func selectModel(id: String) throws -> ModelSetupSnapshot {
        let current = snapshot()
        guard let selected = current.availableModels.first(where: { $0.id == id }) else {
            throw SetupError("This cached model is no longer available. Refresh the model list.")
        }
        let model = SpeechModel(engine: selected.engine, model: selected.model, directory: selected.directory)
        try validate(model)
        let loaded = try readConfig()
        var json = loaded.json
        var transcription = json["transcription"] as? [String: Any] ?? [:]
        for (key, value) in model.configuration { transcription[key] = value }
        json["transcription"] = transcription
        if var receipt = Self.provenance(in: json) {
            receipt.speechEngine = nil; receipt.speechModel = nil; receipt.modelDirectory = nil
            json["muesli_import"] = try Self.encodeObject(receipt)
        }
        _ = try MuesliImport.write(json, to: configURL, expectedOriginal: loaded.data)
        return snapshot()
    }

    func saveSummaries(enabled: Bool, model: String, url: String) throws -> ModelSetupSnapshot {
        if enabled { _ = try OllamaSettings(model: model, baseURL: url) }
        let loaded = try readConfig()
        var json = loaded.json
        var summaries = json["summaries"] as? [String: Any] ?? [:]
        summaries["enabled"] = enabled
        summaries["model"] = model.trimmingCharacters(in: .whitespacesAndNewlines)
        summaries["url"] = url
        json["summaries"] = summaries
        if var receipt = Self.provenance(in: json) {
            receipt.summaryModel = nil; receipt.summaryURL = nil
            receipt.summarySourceConfigPath = nil; receipt.summaryImportedAt = nil
            json["muesli_import"] = try Self.encodeObject(receipt)
        }
        _ = try MuesliImport.write(json, to: configURL, expectedOriginal: loaded.data)
        return snapshot()
    }

    func setTranscriptionEnabled(_ enabled: Bool) throws -> ModelSetupSnapshot {
        let loaded = try readConfig()
        var json = loaded.json
        var transcription = json["transcription"] as? [String: Any] ?? [:]
        transcription["enabled"] = enabled
        json["transcription"] = transcription
        _ = try MuesliImport.write(json, to: configURL, expectedOriginal: loaded.data)
        return snapshot()
    }

    private func finishOffer(_ offer: ImportOffer, outcome: ModelSetupState.Outcome) throws {
        guard let state = readState(), state.outcome == .offered, state.offerID == offer.id else { return }
        try writeState(outcome: outcome, source: offer.sourceURL, offerID: offer.id)
    }

    private func modelInfo(_ selection: SpeechModel, provenance: ImportProvenance?) -> SetupModelInfo {
        let directory = selection.directory ?? SpeechModel.cachedCandidates(home: home).first {
            $0.engine == selection.engine && $0.model == selection.model
        }!.directory!
        let model = SpeechModel(engine: selection.engine, model: selection.model, directory: directory)
        var availabilityError: String?
        var tokenizer: URL?
        do {
            try model.validateCache()
            if model.engine == "whisperkit" {
                tokenizer = try WhisperEngine.tokenizerDirectory(model: model.model, modelFolder: directory, home: home)
            }
        } catch { availabilityError = String(describing: error) }
        let fluid = home.appendingPathComponent("Library/Application Support/FluidAudio/Models").standardizedFileURL.path + "/"
        let hf = home.appendingPathComponent("Documents/huggingface").standardizedFileURL.path + "/"
        let cacheKind: ModelCacheKind = directory.standardizedFileURL.path.hasPrefix(fluid) ? .fluidAudio
            : directory.standardizedFileURL.path.hasPrefix(hf) ? .huggingFace : .custom
        let imported = provenance.flatMap { receipt -> URL? in
            guard receipt.speechEngine == model.engine, receipt.speechModel == model.model,
                  receipt.modelDirectory == directory.path else { return nil }
            return URL(fileURLWithPath: receipt.sourceConfigPath)
        }
        let backend = model.engine == "whisperkit" ? "WhisperKit" : "FluidAudio"
        let name = model.engine == "whisperkit" ? "Whisper \(model.model)"
            : model.engine == "parakeet-unified" ? "Parakeet Unified" : "Parakeet \(model.model)"
        return SetupModelInfo(id: "\(model.engine):\(model.model):\(directory.path)",
            engine: model.engine, model: model.model, displayName: name, backendName: backend,
            directory: directory, tokenizerDirectory: tokenizer, availabilityError: availabilityError,
            cacheKind: cacheKind, importedConfigFrom: imported)
    }

    private func validate(_ model: SpeechModel) throws {
        try model.validateCache()
        if model.engine == "whisperkit", let directory = model.directory {
            _ = try WhisperEngine.tokenizerDirectory(model: model.model, modelFolder: directory, home: home)
        }
    }

    private func readConfig() throws -> (data: Data?, json: [String: Any]) {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return (nil, [:]) }
        let data = try Data(contentsOf: configURL)
        let json = try Self.object(data, at: configURL)
        for key in ["transcription", "summaries"] where json[key] != nil {
            guard json[key] is [String: Any] else {
                throw SetupError("\(key) must be a JSON object in \(configURL.path). Repair it before changing settings; the file was not changed.")
            }
        }
        return (data, json)
    }

    private static func object(_ data: Data, at path: URL) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SetupError("Invalid JSON object at \(path.path). Repair the file before importing; it was not changed.")
        }
        return object
    }

    private static func encodeObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value)) as! [String: Any]
    }

    private static func provenance(in json: [String: Any]) -> ImportProvenance? {
        guard let receipt = json["muesli_import"], let data = try? JSONSerialization.data(withJSONObject: receipt) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ImportProvenance.self, from: data)
    }

    private static func summarySelection(_ json: [String: Any]?) -> SummarySetupSelection? {
        guard let json else { return nil }
        let enabled = json["enabled"] as? Bool ?? false
        let model = json["model"] as? String ?? ""
        let url = json["url"] as? String ?? "http://localhost:11434"
        var error: String?
        if enabled {
            do { _ = try OllamaSettings(model: model, baseURL: url) }
            catch let issue { error = String(describing: issue) }
        }
        return SummarySetupSelection(enabled: enabled, model: model, url: url, validationError: error)
    }

    private func readState() -> ModelSetupState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ModelSetupState.self, from: data)
    }

    private func writeState(outcome: ModelSetupState.Outcome, source: URL? = nil,
                            offerID: UUID? = nil, error: String? = nil) throws {
        let prior = readState()
        let state = ModelSetupState(outcome: outcome, updatedAt: Date(),
            offeredAt: outcome == .offered ? Date() : prior?.offeredAt,
            sourceConfigPath: source?.path, offerID: offerID, error: error)
        try Self.persistState(state, beside: configURL)
    }

    /// CLI writes share the same receipt/state schema without consuming preview offers.
    nonisolated static func recordCLIImport(source: URL, at configURL: URL) throws {
        try persistState(ModelSetupState(outcome: .accepted, updatedAt: Date(), offeredAt: nil,
            sourceConfigPath: source.path, offerID: nil, error: nil), beside: configURL)
    }

    nonisolated static func addingProvenance(to json: [String: Any], source: URL, importedSummaries: Bool) throws -> [String: Any] {
        var result = json
        let speech = json["transcription"] as? [String: Any] ?? [:]
        let summaries = json["summaries"] as? [String: Any] ?? [:]
        let now = Date()
        var receipt = ImportProvenance(sourceConfigPath: source.path, importedAt: now,
            speechEngine: speech["engine"] as? String, speechModel: speech["model"] as? String,
            modelDirectory: speech["model_directory"] as? String,
            summaryModel: nil, summaryURL: nil)
        if importedSummaries {
            receipt.summaryModel = summaries["model"] as? String
            receipt.summaryURL = summaries["url"] as? String
            receipt.summarySourceConfigPath = source.path
            receipt.summaryImportedAt = now
        } else if let prior = provenance(in: json), prior.summaryModel != nil,
                  prior.summaryModel == summaries["model"] as? String,
                  prior.summaryURL == summaries["url"] as? String {
            // A speech-only import must not erase or reattribute notes settings
            // that remain unchanged from an earlier, possibly different source.
            receipt.summaryModel = prior.summaryModel
            receipt.summaryURL = prior.summaryURL
            receipt.summarySourceConfigPath = prior.summarySourceConfigPath ?? prior.sourceConfigPath
            receipt.summaryImportedAt = prior.summaryImportedAt ?? prior.importedAt
        }
        result["muesli_import"] = try encodeObject(receipt)
        return result
    }

    private nonisolated static func persistState(_ state: ModelSetupState, beside configURL: URL) throws {
        let directory = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let path = directory.appendingPathComponent("model-setup-state.json")
        try encoder.encode(state).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}

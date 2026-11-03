import ArgumentParser
import Foundation

enum MuesliImport {
    static func read(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SetupError("Expected a JSON object at \(url.path).")
        }
        return json
    }

    /// Only whitelisted settings cross this boundary. Muesli's full config may
    /// contain credentials for unrelated providers; never copy or print it.
    static func proposal(muesli: [String: Any], existing: [String: Any], home: URL,
                         replace: Bool) throws -> [String: Any] {
        let model = try SpeechModel.fromMuesli(muesli, home: home)
        try model.validateCache()
        if model.engine == "whisperkit", let directory = model.directory {
            _ = try WhisperEngine.tokenizerDirectory(model: model.model, modelFolder: directory, home: home)
        }
        let importSummaries = muesli["meeting_summary_backend"] as? String == "ollama"
        if !replace && (existing["transcription"] != nil || (importSummaries && existing["summaries"] != nil)) {
            throw SetupError("Quill already has transcription or summary settings. Preview with --replace; add --write to apply with a backup.")
        }
        var result = existing
        var transcription = existing["transcription"] as? [String: Any] ?? [:]
        for (key, value) in model.configuration { transcription[key] = value }
        result["transcription"] = transcription
        if importSummaries {
            let settings = try OllamaSettings(model: muesli["ollama_model"] as? String ?? "",
                baseURL: muesli["ollama_url"] as? String ?? "http://localhost:11434")
            var summaries = existing["summaries"] as? [String: Any] ?? [:]
            summaries["enabled"] = true
            summaries["model"] = settings.model
            summaries["url"] = settings.baseURL.absoluteString
            result["summaries"] = summaries
        }
        return result
    }

    static func write(_ config: [String: Any], to path: URL, expectedOriginal: Data?) throws -> URL? {
        let fm = FileManager.default
        // Atomic replacement at the logical path would replace a settings
        // symlink. Write its resolved target and retain the user's linkage.
        let destination = path.resolvingSymlinksInPath()
        let current = fm.fileExists(atPath: destination.path) ? try Data(contentsOf: destination) : nil
        guard current == expectedOriginal else {
            throw SetupError("Quill config changed during import; rerun to review the current settings.")
        }
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var backup: URL?
        if let current {
            let url = path.appendingPathExtension("backup-" + UUID().uuidString)
            try current.write(to: url, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            backup = url
        }
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: destination, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return backup
    }
}

struct ImportMuesli: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "import-muesli",
        abstract: "Preview importing Muesli's meeting model and local Ollama settings. No downloads.")

    @Option(name: .long, help: "Muesli config path (for MuesliDev or a custom install).")
    var config: String?
    @Flag(name: .long, help: "Write Quill config after validation, backing up any existing file.")
    var write = false
    @Flag(name: .long, help: "Replace existing transcription/summary selections; preserve other settings.")
    var replace = false

    func run() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let source = config.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? home.appendingPathComponent("Library/Application Support/Muesli/config.json")
        let muesli = try MuesliImport.read(source)
        let original = FileManager.default.fileExists(atPath: Config.path.path)
            ? try Data(contentsOf: Config.path) : nil
        let existing = original == nil ? [:] : try MuesliImport.read(Config.path)
        let result = try MuesliImport.proposal(muesli: muesli, existing: existing, home: home, replace: replace)
        // Show just the imported sections, not unrelated user configuration.
        var preview: [String: Any] = ["transcription": result["transcription"]!]
        if muesli["meeting_summary_backend"] as? String == "ollama" {
            preview["summaries"] = result["summaries"]
        }
        let data = try JSONSerialization.data(withJSONObject: preview, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if write {
            let recorded = try ModelSetupStore.addingProvenance(to: result, source: source,
                importedSummaries: muesli["meeting_summary_backend"] as? String == "ollama")
            let backup = try MuesliImport.write(recorded, to: Config.path, expectedOriginal: original)
            do { try ModelSetupStore.recordCLIImport(source: source, at: Config.path) }
            catch { throw SetupError("Quill configuration was saved at \(Config.path.path), but setup state could not be saved: \(error).") }
            print("Updated \(Config.path.path)")
            if let backup { print("Backup: \(backup.path)") }
            print("Restart Quill, then run quill doctor to check Ollama and the selected cache.")
        } else {
            print("Preview only. Add --write to apply; Muesli files are never modified.")
        }
        if muesli["meeting_summary_backend"] as? String != "ollama" {
            print("Muesli's summary provider is not Ollama; Quill summary settings were left unchanged.")
        }
    }
}

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List compatible model caches without downloading or loading weights.")
    func run() {
        for model in SpeechModel.cachedCandidates() {
            guard let directory = model.directory,
                  FileManager.default.fileExists(atPath: directory.path) else { continue }
            do {
                try model.validateCache()
                if model.engine == "whisperkit" {
                    _ = try WhisperEngine.tokenizerDirectory(model: model.model, modelFolder: directory)
                }
                print("ready: \(model.engine)/\(model.model) — \(directory.path)")
            } catch {
                print("incomplete: \(model.engine)/\(model.model) — \(error)")
            }
        }
        print("Use quill import-muesli to reuse Muesli's selected meeting model. No model files were changed.")
    }
}

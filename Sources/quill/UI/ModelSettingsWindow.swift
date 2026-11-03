import AppKit
import SwiftUI

@MainActor
final class ModelSettingsViewModel: ObservableObject {
    @Published var snapshot: ModelSetupSnapshot?
    @Published var offer: ImportOffer?
    @Published var selectedModelID = ""
    @Published var notesEnabled = false
    @Published var notesModel = ""
    @Published var notesURL = "http://localhost:11434"
    @Published var installedNotesModels: [String] = []
    @Published var isBusy = false
    @Published var checkingOllama = false
    @Published var message: String?
    @Published var actionError: String?
    @Published var ollamaStatus: String?
    @Published var activeTranscription: String?
    @Published var activeSummary: String?

    let store: ModelSetupStore
    private let discoverOffer: @Sendable (Bool, URL?) async throws -> ImportOffer?
    private var discoveryGeneration = UUID()
    var onChanged: (@MainActor () async -> Void)?
    var onSnapshot: ((ModelSetupSnapshot) -> Void)?
    var onRetryTranscripts: (@MainActor () async -> Void)?

    init(store: ModelSetupStore, discoverOffer: (@Sendable (Bool, URL?) async throws -> ImportOffer?)? = nil) {
        self.store = store
        self.discoverOffer = discoverOffer ?? { automatic, source in
            try await store.beginOffer(automatic: automatic, sourceURL: source)
        }
    }

    func refresh(resetDraft: Bool = true) async {
        apply(await store.snapshot(), resetDraft: resetDraft)
    }

    private func apply(_ snapshot: ModelSetupSnapshot, resetDraft: Bool = true) {
        self.snapshot = snapshot
        if resetDraft {
            selectedModelID = snapshot.selectedModel?.id ?? ""
            notesEnabled = snapshot.summaries?.enabled ?? false
            notesModel = snapshot.summaries?.model ?? ""
            notesURL = snapshot.summaries?.url ?? "http://localhost:11434"
        }
        onSnapshot?(snapshot)
    }

    @discardableResult
    func discover(automatic: Bool, source: URL? = nil) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        let generation = UUID()
        discoveryGeneration = generation
        actionError = nil
        defer { isBusy = false }
        do {
            let discovered = try await discoverOffer(automatic, source)
            guard generation == discoveryGeneration else {
                if let discovered { try await store.dismiss(discovered) }
                await refresh(resetDraft: false)
                return false
            }
            offer = discovered
            await refresh()
            return offer != nil
        } catch {
            actionError = String(describing: error)
            await refresh()
            return !automatic && generation == discoveryGeneration
        }
    }

    func acceptOffer() async {
        guard let offer, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        actionError = nil
        do {
            apply(try await store.accept(offer))
            self.offer = nil
            message = "Setup imported. Quill saved its own settings; model files stay where they are."
            await onChanged?()
        } catch {
            actionError = String(describing: error)
            self.offer = nil
            await refresh()
            // A config write may succeed before receipt persistence fails.
            // Always align runtime with the config now actually on disk.
            await onChanged?()
        }
    }

    func windowClosed() async {
        discoveryGeneration = UUID()
        guard let offer else { return }
        self.offer = nil
        do { try await store.dismiss(offer) }
        catch { actionError = String(describing: error) }
        await refresh()
        await onChanged?()
    }

    func closeOffer(rejected: Bool = false) async {
        guard let offer, !isBusy else { return }
        self.offer = nil
        do {
            if rejected { try await store.decline(offer) }
            else { try await store.dismiss(offer) }
            await refresh()
            await onChanged?()
        } catch { actionError = String(describing: error) }
    }

    func useSelectedModel() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        actionError = nil
        do {
            apply(try await store.selectModel(id: selectedModelID))
            message = "Model saved for the next transcript. Work already running keeps its current model."
            await onChanged?()
        } catch { actionError = String(describing: error) }
    }

    func setTranscriptionEnabled(_ enabled: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            apply(try await store.setTranscriptionEnabled(enabled))
            await onChanged?()
            if enabled { await onRetryTranscripts?() }
        } catch { actionError = String(describing: error) }
    }

    func checkOllama() async {
        guard !checkingOllama else { return }
        checkingOllama = true
        let endpoint = notesURL
        let selection = notesModel
        defer { checkingOllama = false }
        do {
            let settings = try OllamaSettings(model: selection.isEmpty ? "metadata-only" : selection, baseURL: endpoint)
            let models = try await OllamaClient(settings: settings).availableModels()
            guard endpoint == notesURL else { return }
            installedNotesModels = models
            ollamaStatus = installedNotesModels.isEmpty ? "Ollama has no installed models." : "Ollama is available. Choose a locally installed model."
        } catch {
            guard endpoint == notesURL else { return }
            installedNotesModels = []
            ollamaStatus = String(describing: error)
        }
    }

    func saveNotes() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        actionError = nil
        do {
            if notesEnabled {
                let settings = try OllamaSettings(model: notesModel, baseURL: notesURL)
                try await OllamaClient(settings: settings).validateLocalModel()
            }
            apply(try await store.saveSummaries(enabled: notesEnabled, model: notesModel, url: notesURL))
            message = "Meeting-note settings saved for new jobs."
            await onChanged?()
        } catch { actionError = String(describing: error) }
    }

    func chooseMuesliConfiguration() {
        let panel = NSOpenPanel()
        panel.title = "Choose Muesli configuration"
        panel.message = "Choose Muesli's config.json. Quill reads only the model and local Ollama settings."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { await self?.discover(automatic: false, source: url) }
        }
    }

    func retryTranscripts() async {
        await onRetryTranscripts?()
        message = "Pending transcripts queued again. Existing transcripts are kept."
        await refresh(resetDraft: false)
    }

    static func reveal(_ url: URL) {
        var visible = url
        while !FileManager.default.fileExists(atPath: visible.path), visible.path != "/" {
            visible.deleteLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([visible])
    }
}

struct ModelSettingsView: View {
    @ObservedObject var model: ModelSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Models & Notes").font(.title2.weight(.semibold))
                Text("Choose what Quill uses, and see where your files live.").foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let offer = model.offer { importOffer(offer) }
                    if let error = model.actionError { notice(error, error: true) }
                    if let message = model.message { notice(message, error: false) }
                    if let snapshot = model.snapshot {
                        if let error = snapshot.configError {
                            notice("Your Quill configuration could not be read. It has not been replaced. \(error)", error: true)
                        }
                        speech(snapshot)
                        Divider()
                        notes(snapshot)
                        Divider()
                        storage(snapshot)
                    } else {
                        ProgressView("Checking local settings…")
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Check Muesli again…") { Task { await model.discover(automatic: false) } }
                    .disabled(model.isBusy)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await model.refresh() } }.disabled(model.isBusy)
            }.padding(16)
        }
        .frame(minWidth: 570, idealWidth: 640, minHeight: 600, idealHeight: 760)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func importOffer(_ offer: ImportOffer) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Use your Muesli setup?").font(.headline)
                Text("Reuse the models you already have. Quill will save its own settings and reference the existing model files, without downloading or moving them.")
                if let speech = offer.model {
                    LabeledContent("Transcription", value: "\(speech.displayName) · \(speech.backendName)")
                }
                if let notes = offer.summaries {
                    LabeledContent("Meeting notes", value: "\(notes.model) · local Ollama")
                }
                if let source = offer.sourceURL {
                    Text("Settings source: \(source.path)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if offer.replacesExisting {
                    Text("This replaces your current model and imported note selections. Other Quill settings are kept, and the original configuration is backed up.").font(.callout)
                }
                ForEach(offer.warnings, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                if let error = offer.error {
                    notice(error, error: true)
                    Text("Finish or restore the model's files, choose an available model below, or check another configuration. Quill can still record.").font(.callout)
                }
                HStack {
                    if offer.canAccept {
                        Button("Use this setup") { Task { await model.acceptOffer() } }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                    Button(offer.canAccept ? "Keep my setup" : "Dismiss") {
                        Task { await model.closeOffer(rejected: offer.canAccept) }
                    }
                    if offer.error != nil {
                        Button("Check again") { Task { await model.discover(automatic: false, source: offer.sourceURL) } }
                    }
                }.disabled(model.isBusy)
                if !offer.alternativeSources.isEmpty {
                    Menu("Other Muesli configuration") {
                        ForEach(offer.alternativeSources, id: \.path) { url in
                            Button(url.deletingLastPathComponent().lastPathComponent) {
                                Task { await model.discover(automatic: false, source: url) }
                            }
                        }
                    }.disabled(model.isBusy)
                }
                Button("Choose Muesli configuration…") { model.chooseMuesliConfiguration() }
                    .disabled(model.isBusy)
                Text("You won't be asked again on normal launches. Check Muesli again here whenever you want.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func speech(_ snapshot: ModelSetupSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcription").font(.headline)
            Toggle("Transcribe finished recordings", isOn: Binding(
                get: { snapshot.transcriptionEnabled },
                set: { enabled in Task { await model.setTranscriptionEnabled(enabled) } }
            )).disabled(model.isBusy || snapshot.configError != nil)
            if let current = snapshot.selectedModel {
                LabeledContent("Saved model", value: "\(current.displayName) · \(current.backendName)")
                if let active = model.activeTranscription {
                    LabeledContent("Running now", value: active)
                }
                Text("Changes apply to the next transcript. A job already running finishes with its current model.")
                    .font(.callout).foregroundStyle(.secondary)
                if let error = current.availabilityError {
                    notice("Model files unavailable. \(error)", error: true)
                    Text("Restore the folder below or choose another cached model. No model downloads start automatically.")
                        .font(.callout)
                }
                Picker("Cached model", selection: $model.selectedModelID) {
                    ForEach(snapshot.availableModels) { item in
                        Text("\(item.displayName) · \(item.backendName)\(item.isAvailable ? "" : " — unavailable")").tag(item.id)
                    }
                }
                Button("Use selected model") { Task { await model.useSelectedModel() } }
                    .disabled(model.isBusy || !snapshot.availableModels.contains { $0.id == model.selectedModelID && $0.isAvailable })
                Text(current.cacheKind.rawValue).font(.subheadline.weight(.medium))
                Text("Quill uses these files in place. Keep the model and tokenizer folders when cleaning up other apps. Removing Muesli.app alone leaves shared caches intact.")
                    .font(.callout).foregroundStyle(.secondary)
                pathRow(current.directory)
                if let physical = current.resolvedDirectory {
                    Text("Storage destination (this path is a link)").font(.callout).foregroundStyle(.secondary)
                    pathRow(physical)
                }
                if let tokenizer = current.tokenizerDirectory {
                    Text("Tokenizer files").font(.callout).foregroundStyle(.secondary)
                    pathRow(tokenizer)
                }
                if let source = current.importedConfigFrom {
                    Text("This selection was imported from \(source.deletingLastPathComponent().lastPathComponent). Quill uses its own saved configuration; it does not read that app's settings for each recording.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Button("Retry pending transcripts") { Task { await model.retryTranscripts() } }
                .disabled(model.isBusy || !snapshot.transcriptionEnabled || snapshot.selectedModel?.isAvailable != true)
        }.disabled(model.isBusy || snapshot.configError != nil)
    }

    private func notes(_ snapshot: ModelSetupSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meeting notes").font(.headline)
            if let active = model.activeSummary { LabeledContent("Running now", value: active) }
            if let saved = snapshot.summaries, saved.enabled {
                LabeledContent("Saved model", value: "\(saved.model) · Ollama")
                Text(saved.url).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if let receipt = snapshot.provenance, receipt.summaryModel == saved.model,
                   receipt.summaryURL == saved.url, let source = receipt.summarySourceConfigPath {
                    Text("Note settings imported from \(source). Quill keeps its own copy.")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } else { Text("Automatic notes are off.").foregroundStyle(.secondary) }
            Toggle("Create notes after transcription", isOn: $model.notesEnabled)
            TextField("Ollama address", text: $model.notesURL)
                .onChange(of: model.notesURL) { _, _ in
                    model.installedNotesModels = []
                    model.ollamaStatus = nil
                }
            HStack {
                TextField("Model name", text: $model.notesModel, prompt: Text("Choose an installed model"))
                Menu("Installed models") {
                    ForEach(model.installedNotesModels, id: \.self) { name in
                        Button(name) { model.notesModel = name }
                    }
                }.disabled(model.installedNotesModels.isEmpty)
            }
            HStack {
                Button("Check Ollama") { Task { await model.checkOllama() } }.disabled(model.checkingOllama)
                if model.checkingOllama { ProgressView().controlSize(.small) }
                Button("Save note settings") { Task { await model.saveNotes() } }.disabled(model.isBusy)
            }
            if let status = model.ollamaStatus { Text(status).font(.callout).foregroundStyle(.secondary) }
            if let error = snapshot.summaries?.validationError { notice(error, error: true) }
            Text("Ollama manages these model files separately. Keep Ollama and the selected local model available. A note failure never removes the transcript or interrupts recording.")
                .font(.callout).foregroundStyle(.secondary)
        }.disabled(model.isBusy || snapshot.configError != nil)
    }

    private func storage(_ snapshot: ModelSetupSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your configuration and shared files").font(.headline)
            Text("Quill owns its configuration here:")
            pathRow(snapshot.configURL)
            if let receipt = snapshot.provenance {
                Text("Imported \(receipt.importedAt.formatted(date: .abbreviated, time: .shortened)) from \(receipt.sourceConfigPath). Later model changes are saved independently in Quill.")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Shared caches can be used by Muesli and other apps; their location does not establish which app downloaded them. Removing Muesli.app alone does not remove these caches. Deleting or cleaning the referenced model or tokenizer folders will make this setup unavailable.")
                .font(.callout).foregroundStyle(.secondary)
            if let state = snapshot.onboarding {
                LabeledContent("Muesli setup", value: state.outcome.rawValue.capitalized)
            }
        }
    }

    private func pathRow(_ path: URL) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(path.path).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button("Show in Finder") { ModelSettingsViewModel.reveal(path) }.controlSize(.small)
        }
    }

    private func notice(_ text: String, error: Bool) -> some View {
        Label(text, systemImage: error ? "exclamationmark.triangle" : "checkmark.circle")
            .foregroundStyle(error ? Color.primary : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
final class ModelSettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: ModelSettingsViewModel

    init(model: ModelSettingsViewModel) {
        self.model = model
        let host = NSHostingController(rootView: ModelSettingsView(model: model))
        let window = NSWindow(contentViewController: host)
        window.title = "Quill — Models & Notes"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 640, height: 760))
        window.minSize = NSSize(width: 590, height: 640)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        Task { await model.refresh() }
    }

    func windowWillClose(_ notification: Notification) {
        Task { await model.windowClosed() }
    }
}

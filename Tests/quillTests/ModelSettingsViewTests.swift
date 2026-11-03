import AppKit
import SwiftUI
import Testing
@testable import quill

@MainActor
@Suite(.serialized)
struct ModelSettingsViewTests {
    private func fixture() throws -> (URL, ModelSetupStore) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = home.appendingPathComponent("Library/Application Support/Muesli/config.json")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json: [String: Any] = [
            "meeting_transcription_backend": "fluidaudio",
            "meeting_transcription_model": "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            "meeting_summary_backend": "ollama", "ollama_model": "qwen3:8b", "ollama_url": "http://localhost:11434"
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: source)
        for model in SpeechModel.cachedCandidates(home: home).filter({ $0.engine == "parakeet" && ["v2", "v3"].contains($0.model) }) {
            for name in model.requiredFiles {
                for path in name.hasSuffix(".mlmodelc") ? [name + "/coremldata.bin", name + "/weights/weight.bin"] : [name] {
                    let file = model.directory!.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data([1]).write(to: file)
                }
            }
        }
        return (home, ModelSetupStore(home: home))
    }

    @Test func offerAcceptanceUpdatesDisplayedSelectionAndRuntimeCallback() async throws {
        let (home, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let model = ModelSettingsViewModel(store: store)
        var changes = 0
        model.onChanged = { changes += 1 }
        #expect(await model.discover(automatic: true))
        #expect(model.offer?.canAccept == true)
        await model.acceptOffer()
        #expect(model.offer == nil)
        #expect(model.snapshot?.selectedModel?.model == "v3")
        #expect(model.snapshot?.summaries?.model == "qwen3:8b")
        #expect(model.snapshot?.onboarding?.outcome == .accepted)
        #expect(changes == 1)
        let relaunched = ModelSettingsViewModel(store: ModelSetupStore(home: home))
        #expect(await relaunched.discover(automatic: true) == false)
    }

    @Test func windowCloseAndRejectionStayDismissedUntilExplicitRetry() async throws {
        let (home, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let model = ModelSettingsViewModel(store: store)
        #expect(await model.discover(automatic: true))
        await model.closeOffer()
        #expect(model.snapshot?.onboarding?.outcome == .dismissed)
        #expect(await model.discover(automatic: true) == false)
        #expect(await model.discover(automatic: false))
        await model.closeOffer(rejected: true)
        #expect(model.snapshot?.onboarding?.outcome == .rejected)
        #expect(await model.discover(automatic: true) == false)
        #expect(model.snapshot?.selectedModel?.model == "v2")
    }

    @Test func missingAssetsCanBeReplacedFromTheCachedModelPicker() async throws {
        let (home, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let model = ModelSettingsViewModel(store: store)
        _ = await model.discover(automatic: true)
        await model.acceptOffer()
        let old = try #require(model.snapshot?.selectedModel)
        try FileManager.default.removeItem(at: old.directory)
        await model.refresh()
        #expect(model.snapshot?.selectedModel?.isAvailable == false)
        let replacement = try #require(model.snapshot?.availableModels.first { $0.model == "v2" })
        model.selectedModelID = replacement.id
        await model.useSelectedModel()
        #expect(model.snapshot?.selectedModel?.model == "v2")
        #expect(model.snapshot?.selectedModel?.isAvailable == true)
        #expect(model.snapshot?.selectedModel?.importedConfigFrom == nil)
    }

    @Test func closingDuringDiscoveryDiscardsTheDelayedOfferAndPersistsDismissal() async throws {
        let (home, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let gate = OfferDeliveryGate()
        let model = ModelSettingsViewModel(store: store, discoverOffer: { automatic, source in
            let offer = try await store.beginOffer(automatic: automatic, sourceURL: source)
            await gate.hold()
            return offer
        })
        let discovery = Task { await model.discover(automatic: true) }
        await gate.waitUntilHeld()
        await model.windowClosed()
        await gate.release()
        #expect(await discovery.value == false)
        #expect(model.offer == nil)
        #expect(model.snapshot?.onboarding?.outcome == .dismissed)
        #expect(try await store.beginOffer(automatic: true) == nil)
    }

    @Test func failedAcceptanceClearsExpiredOfferAndRefreshesRuntimeConfiguration() async throws {
        let (home, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let model = ModelSettingsViewModel(store: store)
        var reconfigurations = 0
        model.onChanged = { reconfigurations += 1 }
        _ = await model.discover(automatic: true)
        let source = try #require(model.offer?.sourceURL)
        try Data("{}".utf8).write(to: source)
        await model.acceptOffer()
        #expect(model.offer == nil)
        #expect(model.actionError != nil)
        #expect(model.snapshot?.onboarding?.outcome == .failed)
        #expect(reconfigurations == 1)
        #expect(await model.discover(automatic: true) == false)
    }

    /// Opt-in rendered UI artifacts, not text/image golden assertions. Uses only
    /// synthetic caches and never opens capture, reads user configs or calls Ollama.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QUILL_RENDER_UI_TESTS"] == "1"))
    func renderNativeSettingsStates() async throws {
        let (home, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let model = ModelSettingsViewModel(store: store)
        _ = await model.discover(automatic: true)
        try render(model, name: "import-light", appearance: .aqua)
        try render(model, name: "import-dark", appearance: .darkAqua)
        await model.acceptOffer()
        model.activeTranscription = "parakeet/v3 · sample-meeting"
        model.activeSummary = "qwen3:8b · previous-meeting"
        try render(model, name: "configured-light", appearance: .aqua)
        try render(model, name: "notes-and-storage-dark", appearance: .darkAqua, scrollToBottom: true)
        let selected = try #require(model.snapshot?.selectedModel)
        try FileManager.default.removeItem(at: selected.directory)
        await model.refresh()
        try render(model, name: "missing-dark", appearance: .darkAqua)
    }

    private func render(_ model: ModelSettingsViewModel, name: String, appearance: NSAppearance.Name,
                        scrollToBottom: Bool = false) throws {
        _ = NSApplication.shared
        let controller = ModelSettingsWindowController(model: model)
        let window = try #require(controller.window)
        let host = try #require(window.contentView)
        window.appearance = NSAppearance(named: appearance)
        window.setContentSize(NSSize(width: 640, height: 760))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        if scrollToBottom {
            func scrollView(in view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
            }
            let scroll = try #require(scrollView(in: host))
            let document = try #require(scroll.documentView)
            let offset = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let destination = URL(fileURLWithPath: "/tmp/quill-ui-review")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try data.write(to: destination.appendingPathComponent(name + ".png"))
        window.orderOut(nil)
    }
}

private actor OfferDeliveryGate {
    private var isHeld = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var delivery: CheckedContinuation<Void, Never>?
    func hold() async {
        isHeld = true
        for waiter in heldWaiters { waiter.resume() }
        heldWaiters = []
        await withCheckedContinuation { delivery = $0 }
    }
    func waitUntilHeld() async {
        if isHeld { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }
    func release() { delivery?.resume(); delivery = nil }
}

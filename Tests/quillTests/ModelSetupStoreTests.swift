import Foundation
import Testing
@testable import quill

@Suite struct ModelSetupStoreTests {
    @Test func absenceIsRememberedButExplicitRetryDiscoversLaterInstall() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        #expect(try await store.beginOffer(automatic: true) == nil)
        #expect(await store.snapshot().onboarding?.outcome == .absent)
        try fixture.installMuesli()
        #expect(try await fixture.store().beginOffer(automatic: true) == nil)
        let offer = try #require(try await fixture.store().beginOffer(automatic: false))
        #expect(offer.canAccept)
        #expect(offer.model?.model == "v3")
    }

    @Test func offeredRejectedAndDismissedStatesDoNotNagOnRelaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.installMuesli()
        let store = fixture.store()
        let first = try #require(try await store.beginOffer(automatic: true))
        let offered = await store.snapshot().onboarding
        #expect(offered?.outcome == .offered)
        #expect(offered?.offeredAt != nil)
        #expect(try await fixture.store().beginOffer(automatic: true) == nil)
        try await store.decline(first)
        #expect(await store.snapshot().onboarding?.outcome == .rejected)
        #expect(try await fixture.store().beginOffer(automatic: true) == nil)
        let retry = try #require(try await store.beginOffer(automatic: false))
        try await store.dismiss(retry)
        #expect(await store.snapshot().onboarding?.outcome == .dismissed)
        #expect(try await fixture.store().beginOffer(automatic: true) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.config.path))
    }

    @Test func acceptancePreservesUserConfigRecordsProvenanceAndNeverChangesSource() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.installMuesli()
        let sourceBefore = try Data(contentsOf: fixture.source())
        try fixture.writeConfig([
            "recordings_dir": "~/Custom", "on_stop": "fixture-hook", "future": ["value": 17],
            "transcription": ["enabled": false, "custom": "retained"],
            "summaries": ["custom": "kept"],
        ])
        let store = fixture.store()
        let offer = try #require(try await store.beginOffer(automatic: true))
        #expect(offer.replacesExisting)
        let result = try await store.accept(offer)
        #expect(!result.transcriptionEnabled)
        #expect(result.provenance?.sourceConfigPath == fixture.source().path)
        #expect(result.provenance?.modelDirectory == fixture.model("v3").directory?.path)
        #expect(result.provenance?.summaryModel == "qwen3:8b")
        #expect(result.selectedModel?.importedConfigFrom == fixture.source())
        #expect(result.selectedModel?.isAvailable == true)
        #expect(result.selectedModel?.cacheKind == .fluidAudio)
        #expect(result.onboarding?.outcome == .accepted)
        let saved = try MuesliImport.read(fixture.config)
        #expect(saved["recordings_dir"] as? String == "~/Custom")
        #expect(saved["on_stop"] as? String == "fixture-hook")
        #expect((saved["future"] as? [String: Int])?["value"] == 17)
        #expect((saved["transcription"] as? [String: Any])?["custom"] as? String == "retained")
        #expect((saved["summaries"] as? [String: Any])?["custom"] as? String == "kept")
        #expect(saved["api_key"] == nil)
        #expect(try Data(contentsOf: fixture.source()) == sourceBefore)
        #expect(try await fixture.store().beginOffer(automatic: true) == nil)
        // Dismiss callbacks arriving after acceptance must not rewrite acceptance.
        try await store.dismiss(offer)
        #expect(await store.snapshot().onboarding?.outcome == .accepted)
    }

    @Test func malformedSourceAndDestinationProduceOneErrorOfferWithoutOverwritingEither() async throws {
        for malformedSource in [true, false] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.installMuesli()
            let target = malformedSource ? fixture.source() : fixture.config
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = Data("not valid json".utf8)
            try original.write(to: target)
            let store = fixture.store()
            let offer = try #require(try await store.beginOffer(automatic: true))
            #expect(!offer.canAccept)
            #expect(offer.error != nil)
            #expect(try Data(contentsOf: target) == original)
            #expect(try await fixture.store().beginOffer(automatic: true) == nil)
            try await store.dismiss(offer)
            #expect(await store.snapshot().onboarding?.outcome == .dismissed)
        }
    }

    @Test func incompleteCacheOfferAndLaterMissingFileAreSafeAndRetryable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.installMuesli(fillModel: false)
        let store = fixture.store()
        let incomplete = try #require(try await store.beginOffer(automatic: true))
        #expect(!incomplete.canAccept)
        #expect(incomplete.model?.availabilityError != nil)
        try fixture.fill(fixture.model("v3"))
        let repaired = try #require(try await store.beginOffer(automatic: false))
        #expect(repaired.canAccept)
        try FileManager.default.removeItem(at: fixture.model("v3").directory!.appendingPathComponent("parakeet_vocab.json"))
        await #expect(throws: (any Error).self) { try await store.accept(repaired) }
        #expect(await store.snapshot().onboarding?.outcome == .failed)
        #expect(try await fixture.store().beginOffer(automatic: true) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.config.path))
        try fixture.fill(fixture.model("v3"))
        let retry = try #require(try await store.beginOffer(automatic: false))
        #expect(try await store.accept(retry).onboarding?.outcome == .accepted)
    }

    @Test func malformedKnownSectionsArePreservedInsteadOfReplaced() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.installMuesli()
        try fixture.writeConfig(["transcription": "invalid fixture"])
        let original = try Data(contentsOf: fixture.config)
        let store = fixture.store()
        #expect(await store.snapshot().configError != nil)
        let offer = try #require(try await store.beginOffer(automatic: true))
        #expect(!offer.canAccept)
        await #expect(throws: (any Error).self) { try await store.setTranscriptionEnabled(true) }
        #expect(try Data(contentsOf: fixture.config) == original)
    }

    @Test func staleDestinationAndSourcePreventAcceptingAnOutdatedPreview() async throws {
        for changeSource in [false, true] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.installMuesli()
            let store = fixture.store()
            let offer = try #require(try await store.beginOffer(automatic: true))
            let target = changeSource ? fixture.source() : fixture.config
            let newer = Data(#"{"future":"changed"}"#.utf8)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try newer.write(to: target)
            await #expect(throws: (any Error).self) { try await store.accept(offer) }
            #expect(try Data(contentsOf: target) == newer)
            #expect(await store.snapshot().onboarding?.outcome == .failed)
        }
    }

    @Test func invalidSummaryDoesNotBlockSpeechOrReplaceExistingSummarySettings() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.installMuesli(summaryURL: "https://example.com")
        try fixture.writeConfig(["summaries": ["enabled": false, "model": "existing", "url": "http://localhost:11434"]])
        let store = fixture.store()
        let offer = try #require(try await store.beginOffer(automatic: true))
        #expect(offer.canAccept)
        #expect(!offer.warnings.isEmpty)
        #expect(offer.summaries == nil)
        let result = try await store.accept(offer)
        #expect(result.selectedModel?.model == "v3")
        #expect(result.summaries?.model == "existing")
        #expect(result.summaries?.enabled == false)
        #expect(result.provenance?.summaryModel == nil)
    }

    @Test func standardInstallIsPreferredAndDevCanBeExplicitlySelected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.installMuesli()
        try fixture.installMuesli(name: "MuesliDev")
        let store = fixture.store()
        let standard = try #require(try await store.beginOffer(automatic: true))
        #expect(standard.sourceURL == fixture.source())
        #expect(standard.alternativeSources == [fixture.source("MuesliDev")])
        let dev = try #require(try await store.beginOffer(automatic: false, sourceURL: fixture.source("MuesliDev")))
        #expect(dev.sourceURL == fixture.source("MuesliDev"))
        #expect(try await store.accept(dev).provenance?.sourceConfigPath == fixture.source("MuesliDev").path)
        // An older offer cannot rewrite the newer accepted decision.
        await #expect(throws: (any Error).self) { try await store.accept(standard) }
        #expect(await store.snapshot().onboarding?.outcome == .accepted)
    }

    @Test func speechOnlyReimportPreservesNotesSourceAndImportDate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.installMuesli()
        let store = fixture.store()
        let first = try #require(try await store.beginOffer(automatic: true))
        let original = try await store.accept(first)
        try fixture.installMuesli(name: "MuesliDev", summaryURL: "https://example.com")
        let second = try #require(try await store.beginOffer(automatic: false, sourceURL: fixture.source("MuesliDev")))
        let result = try await store.accept(second)
        #expect(result.provenance?.sourceConfigPath == fixture.source("MuesliDev").path)
        #expect(result.provenance?.summarySourceConfigPath == fixture.source().path)
        #expect(result.provenance?.summaryImportedAt == original.provenance?.summaryImportedAt)
        #expect(result.provenance?.summaryModel == original.provenance?.summaryModel)
        #expect(result.summaries?.model == original.summaries?.model)
        let changed = try await store.saveSummaries(enabled: false, model: "", url: "http://localhost:11434")
        #expect(changed.provenance?.summarySourceConfigPath == nil)
        #expect(changed.provenance?.summaryImportedAt == nil)
        #expect(changed.provenance?.sourceConfigPath == fixture.source("MuesliDev").path)
        #expect(changed.provenance?.speechModel == "v3")
    }

    @Test func manualSelectionsClearOnlyTheirOwnImportedProvenanceAndPreserveDisabledFlag() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.installMuesli()
        try fixture.fill(fixture.model("v2"))
        try fixture.writeConfig(["transcription": ["enabled": false]])
        let store = fixture.store()
        let offer = try #require(try await store.beginOffer(automatic: true))
        let imported = try await store.accept(offer)
        let v2 = try #require(imported.availableModels.first { $0.model == "v2" })
        let selected = try await store.selectModel(id: v2.id)
        #expect(selected.selectedModel?.model == "v2")
        #expect(selected.selectedModel?.importedConfigFrom == nil)
        #expect(selected.provenance?.modelDirectory == nil)
        #expect(selected.provenance?.summaryModel == "qwen3:8b")
        #expect(!selected.transcriptionEnabled)
        #expect(try await store.setTranscriptionEnabled(true).transcriptionEnabled)
        let changed = try await store.saveSummaries(enabled: true, model: "gemma3:4b", url: "http://localhost:11434")
        #expect(changed.summaries?.model == "gemma3:4b")
        #expect(changed.provenance?.summaryModel == nil)
        #expect(changed.onboarding?.outcome == .accepted)
    }

    @Test func defaultAndCustomCacheSnapshotsHaveEffectivePathsAndOwnership() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let initial = await store.snapshot()
        #expect(initial.selectedModel?.directory == fixture.model("v2").directory)
        #expect(initial.selectedModel?.cacheKind == .fluidAudio)
        #expect(initial.selectedModel?.availabilityError != nil)
        let directory = fixture.home.appendingPathComponent("custom-asr")
        let custom = SpeechModel(engine: "parakeet", model: "v3", directory: directory)
        try fixture.fill(custom)
        try fixture.writeConfig(["transcription": custom.configuration])
        let current = await store.snapshot()
        #expect(current.selectedModel?.directory.path == directory.path)
        #expect(current.selectedModel?.cacheKind == .custom)
        #expect(current.selectedModel?.isAvailable == true)
    }

    @Test func cliReceiptAndStatePreventLaterAutomaticOfferWithoutAttributingUnimportedSummaries() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.installMuesli()
        let model = fixture.model("v3")
        let config: [String: Any] = ["transcription": model.configuration,
            "summaries": ["enabled": true, "model": "existing"]]
        let recorded = try ModelSetupStore.addingProvenance(to: config, source: fixture.source(), importedSummaries: false)
        try fixture.writeConfig(recorded)
        try ModelSetupStore.recordCLIImport(source: fixture.source(), at: fixture.config)
        let store = fixture.store()
        #expect(try await store.beginOffer(automatic: true) == nil)
        #expect(await store.snapshot().provenance?.summaryModel == nil)
        #expect(await store.snapshot().onboarding?.outcome == .accepted)
        // A successful config write still suppresses another offer if state writing was interrupted.
        try FileManager.default.removeItem(at: await store.stateURL)
        #expect(try await fixture.store().beginOffer(automatic: true) == nil)
        #expect(await store.snapshot().onboarding?.outcome == .accepted)
    }

    @Test func customAliasIntoSharedCacheRetainsItsSharedDependencyAndConfiguredPath() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let shared = fixture.model("v3")
        try fixture.fill(shared)
        let alias = fixture.home.appendingPathComponent("my-model")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: shared.directory!)
        try fixture.writeConfig(["transcription": ["engine": "parakeet", "model": "v3", "model_directory": alias.path]])
        let current = await fixture.store().snapshot()
        #expect(current.selectedModel?.directory.path == alias.path)
        #expect(current.selectedModel?.resolvedDirectory?.path == shared.directory!.resolvingSymlinksInPath().path)
        #expect(current.selectedModel?.cacheKind == .fluidAudio)
        #expect(current.selectedModel?.isAvailable == true)
    }

    @Test func sharedRootMovedBySymlinkStillClassifiesAsSharedStorage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sharedRoot = fixture.home.appendingPathComponent("Library/Application Support/FluidAudio/Models")
        let external = fixture.home.appendingPathComponent("external-drive/models")
        try FileManager.default.createDirectory(at: sharedRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sharedRoot, withDestinationURL: external)
        let shared = fixture.model("v3")
        try fixture.fill(shared)
        // Saving the external path directly must not conceal its relationship
        // to the shared cache root used by Muesli and FluidAudio.
        let target = shared.directory!.resolvingSymlinksInPath()
        try fixture.writeConfig(["transcription": ["engine": "parakeet", "model": "v3", "model_directory": target.path]])
        let current = await fixture.store().snapshot()
        #expect(current.selectedModel?.directory.path == target.path)
        #expect(current.selectedModel?.cacheKind == .fluidAudio)
        #expect(current.selectedModel?.isAvailable == true)
    }

    @Test func settingsWritePreservesSymlinkAndBacksUpExactTargetBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let backing = fixture.home.appendingPathComponent("dotfiles/quill.json")
        let original = Data("{\n  \"future\": 42\n}\n".utf8)
        try FileManager.default.createDirectory(at: backing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: backing)
        try FileManager.default.createDirectory(at: fixture.config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.config, withDestinationURL: backing)
        _ = try await fixture.store().setTranscriptionEnabled(false)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.config.path) == backing.path)
        #expect(try Data(contentsOf: fixture.config) == Data(contentsOf: backing))
        let saved = try MuesliImport.read(backing)
        #expect(saved["future"] as? Int == 42)
        #expect((saved["transcription"] as? [String: Any])?["enabled"] as? Bool == false)
        let backups = try FileManager.default.contentsOfDirectory(at: fixture.config.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("config.json.backup-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == original)
    }

    private struct Fixture: Sendable {
        let home: URL
        var config: URL { home.appendingPathComponent(".config/quill/config.json") }
        init() throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        func store() -> ModelSetupStore { ModelSetupStore(home: home) }
        func source(_ name: String = "Muesli") -> URL {
            home.appendingPathComponent("Library/Application Support/\(name)/config.json")
        }
        func model(_ version: String) -> SpeechModel {
            SpeechModel.cachedCandidates(home: home).first { $0.engine == "parakeet" && $0.model == version }!
        }
        func fill(_ model: SpeechModel) throws {
            for name in model.requiredFiles {
                let files = name.hasSuffix(".mlmodelc") ? [name + "/coremldata.bin", name + "/weights/weight.bin"] : [name]
                for file in files {
                    let path = model.directory!.appendingPathComponent(file)
                    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data([1]).write(to: path)
                }
            }
        }
        func installMuesli(name: String = "Muesli", fillModel: Bool = true,
                           summaryURL: String = "http://localhost:11434") throws {
            if fillModel { try fill(model("v3")) }
            let json: [String: Any] = ["meeting_transcription_backend": "fluidaudio",
                "meeting_transcription_model": "FluidInference/parakeet-tdt-0.6b-v3-coreml",
                "meeting_summary_backend": "ollama", "ollama_model": "qwen3:8b", "ollama_url": summaryURL,
                "api_key": "fixture-secret"]
            let path = source(name)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: json).write(to: path)
        }
        func writeConfig(_ json: [String: Any]) throws {
            try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: json).write(to: config)
        }
        func remove() { try? FileManager.default.removeItem(at: home) }
    }
}

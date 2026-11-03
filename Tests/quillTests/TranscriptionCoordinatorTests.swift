import Foundation
import Testing
@testable import quill

struct TranscriptionCoordinatorTests {
    @Test func selectionChangesApplyBetweenJobsAndRetryDoesNotDuplicateActiveSession() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try session(root, "01", tracks: ["mic", "system"])
        let second = try session(root, "02", tracks: ["mic"])
        let gate = TranscriptionGate()
        let old = FixtureEngine(model: "old", gate: gate)
        let next = FixtureEngine(model: "next")
        let box = SelectionBox(model: "old")
        let queue = coordinator(box: box, factory: { $0.model == "old" ? old : next })
        await queue.enqueue(first)
        await gate.waitUntilEntered()
        box.select("next")
        await queue.enqueue(second)
        // A foreground retry returns directory URLs with different directory
        // hints from URLs returned by recording. Neither spelling is a new job.
        await queue.enqueue(URL(fileURLWithPath: first.path, isDirectory: true))
        await queue.resumePending(root: root)
        await gate.open()
        await queue.waitUntilIdle()
        #expect(await old.calls == ["01/mic.caf", "01/system.caf"])
        #expect(await next.calls == ["02/mic.caf"])
        #expect(await old.preparations == 1)
        #expect(await next.preparations == 1)
        #expect(await old.releases == 1)
        #expect(await next.releases == 1)
        #expect(try transcriptModel(first) == "old")
        #expect(try transcriptModel(second) == "next")
    }

    @Test func unchangedSelectionReusesPreparedEngineAcrossQueuedJobs() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try session(root, "01", tracks: ["mic"])
        let second = try session(root, "02", tracks: ["mic"])
        let gate = TranscriptionGate()
        let engine = FixtureEngine(model: "same", gate: gate)
        let queue = coordinator(box: SelectionBox(model: "same"), factory: { _ in engine })
        await queue.enqueue(first)
        await gate.waitUntilEntered()
        await queue.enqueue(second)
        await gate.open()
        await queue.waitUntilIdle()
        #expect(await engine.preparations == 1)
        #expect(await engine.releases == 1)
        #expect(await engine.calls.count == 2)
    }

    @Test func changingOnlyCacheDirectoryReloadsTheNextJob() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try session(root, "01", tracks: ["mic"])
        let second = try session(root, "02", tracks: ["mic"])
        let gate = TranscriptionGate()
        let old = FixtureEngine(model: "same", gate: gate)
        let next = FixtureEngine(model: "same")
        let box = SelectionBox(model: "same")
        let queue = coordinator(box: box, factory: { $0.directory?.path == "/fixture/same" ? old : next })
        await queue.enqueue(first)
        await gate.waitUntilEntered()
        box.moveCache(to: "/replacement/same")
        await queue.enqueue(second)
        await gate.open()
        await queue.waitUntilIdle()
        #expect(await old.calls == ["01/mic.caf"])
        #expect(await next.calls == ["02/mic.caf"])
        #expect(await old.releases == 1)
        #expect(await next.preparations == 1)
    }

    @Test func disablingSummariesKeepsCurrentJobHandoffButDoesNotQueueNextJob() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try session(root, "01", tracks: ["mic"])
        let second = try session(root, "02", tracks: ["mic"])
        let gate = TranscriptionGate()
        // Empty synthetic speech causes summary processing to stop locally,
        // without an HTTP request, while still proving the durable handoff.
        let engine = FixtureEngine(model: "same", gate: gate, empty: true)
        let summaries = SummaryCoordinator(settings: try OllamaSettings(model: "fixture"))
        let queue = coordinator(box: SelectionBox(model: "same"), summaries: summaries, factory: { _ in engine })
        await queue.enqueue(first)
        await gate.waitUntilEntered()
        await queue.updateSummaries(nil)
        await queue.enqueue(second)
        await gate.open()
        await queue.waitUntilIdle()
        await summaries.waitUntilIdle()
        #expect(FileManager.default.fileExists(atPath: first.appendingPathComponent(SummaryCoordinator.pendingFilename).path))
        #expect(FileManager.default.fileExists(atPath: first.appendingPathComponent("summary.log").path))
        #expect(!FileManager.default.fileExists(atPath: second.appendingPathComponent(SummaryCoordinator.pendingFilename).path))
        #expect(!FileManager.default.fileExists(atPath: second.appendingPathComponent("summary.log").path))
    }

    @Test func disablingTranscriptionFinishesCurrentJobAndDefersBacklogWithoutHooks() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try session(root, "01", tracks: ["mic", "system"])
        let second = try session(root, "02", tracks: ["mic"])
        let gate = TranscriptionGate()
        let engine = FixtureEngine(model: "same", gate: gate)
        let selection = SelectionBox(model: "same")
        let controls = RuntimeControls()
        let queue = TranscriptionCoordinator(modelProvider: { selection.current() }, engineFactory: { _ in engine },
            enabled: { controls.isEnabled }, hookCommand: { controls.recordHook(); return nil }, notify: { _, _ in })
        await queue.enqueue(first)
        await gate.waitUntilEntered()
        await queue.enqueue(second)
        controls.isEnabled = false
        await gate.open()
        await queue.waitUntilIdle()
        #expect(try transcriptModel(first) == "same")
        #expect(!FileManager.default.fileExists(atPath: second.appendingPathComponent("transcript.json").path))
        #expect(await engine.calls == ["01/mic.caf", "01/system.caf"])
        #expect(controls.hooks == 1)
        controls.isEnabled = true
        await queue.resumePending(root: root)
        await queue.waitUntilIdle()
        #expect(try transcriptModel(second) == "same")
        #expect(await engine.calls == ["01/mic.caf", "01/system.caf", "02/mic.caf"])
        #expect(controls.hooks == 2)
    }

    @Test func missingParakeetCacheFailsWithoutCreatingOrDownloadingAssets() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let absent = root.appendingPathComponent("missing")
        let engine = ParakeetEngine(selection: SpeechModel(engine: "parakeet", model: "v2", directory: absent))
        await #expect(throws: SetupError.self) { try await engine.prepare() }
        #expect(!FileManager.default.fileExists(atPath: absent.path))
        await engine.release()
        let oldConfig = try SpeechModel.parse([:])
        let resolved = ParakeetEngine.localSelection(oldConfig)
        #expect(resolved.engine == "parakeet")
        #expect(resolved.model == "v2")
        #expect(resolved.directory != nil)
    }

    private func coordinator(box: SelectionBox, summaries: SummaryCoordinator? = nil,
                             factory: @escaping @Sendable (SpeechModel) throws -> any TranscriptionEngine) -> TranscriptionCoordinator {
        TranscriptionCoordinator(summaries: summaries, modelProvider: { box.current() }, engineFactory: factory,
                                 enabled: { true }, hookCommand: { nil }, notify: { _, _ in })
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func session(_ root: URL, _ name: String, tracks: [String]) throws -> URL {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [String: String] = [:]
        for track in tracks {
            files[track] = track + ".caf"
            try Data([0]).write(to: dir.appendingPathComponent(track + ".caf"))
        }
        try JSONSerialization.data(withJSONObject: ["files": files]).write(to: dir.appendingPathComponent("meta.json"))
        return dir
    }

    private func transcriptModel(_ dir: URL) throws -> String? {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("transcript.json"))) as? [String: Any]
        return value?["model"] as? String
    }
}

private final class SelectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var model: String
    private var directory: String?
    init(model: String) { self.model = model }
    func select(_ model: String) { lock.withLock { self.model = model } }
    func moveCache(to directory: String) { lock.withLock { self.directory = directory } }
    func current() -> SpeechModel {
        lock.withLock { SpeechModel(engine: "fixture", model: model, directory: URL(fileURLWithPath: directory ?? "/fixture/\(model)")) }
    }
}

private actor FixtureEngine: TranscriptionEngine {
    nonisolated let name = "fixture"
    nonisolated let model: String
    let gate: TranscriptionGate?
    let empty: Bool
    var preparations = 0
    var releases = 0
    var calls: [String] = []
    init(model: String, gate: TranscriptionGate? = nil, empty: Bool = false) {
        self.model = model
        self.gate = gate
        self.empty = empty
    }
    func prepare() { preparations += 1 }
    func transcribe(_ audio: URL) async -> [TranscriptSegment] {
        calls.append(audio.deletingLastPathComponent().lastPathComponent + "/" + audio.lastPathComponent)
        if calls.count == 1 { await gate?.pause() }
        return empty ? [] : [TranscriptSegment(start: 0, end: 1, text: "Synthetic speech")]
    }
    func release() { releases += 1 }
}

private actor TranscriptionGate {
    private var entered = false
    private var opened = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        if !opened { await withCheckedContinuation { continuation = $0 } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private final class RuntimeControls: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    private var hookCount = 0
    var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }
    var hooks: Int { lock.withLock { hookCount } }
    func recordHook() { lock.withLock { hookCount += 1 } }
}

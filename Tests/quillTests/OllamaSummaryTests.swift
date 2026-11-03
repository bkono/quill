import Foundation
import Testing
@testable import quill

@Suite(.serialized)
struct OllamaSummaryTests {
    @Test func endpointsAndModelAreExplicitlyLocal() throws {
        for url in ["https://example.com", "file:///tmp/a", "http://localhost.evil.test",
                    "http://localhost:11434/api", "http://u:p@localhost:11434", "http://localhost?q=x"] {
            #expect(throws: OllamaError.invalidEndpoint) { try OllamaSettings(model: "qwen3:8b", baseURL: url) }
        }
        for url in ["http://localhost:11434", "http://127.0.0.1:11434/", "http://[::1]:11434"] {
            #expect(try OllamaSettings(model: "qwen3:8b", baseURL: url).model == "qwen3:8b")
        }
        #expect(throws: OllamaError.missingModel) { try OllamaSettings(model: "  ") }
        #expect(throws: OllamaError.remoteModel) { try OllamaSettings(model: "qwen3:cloud") }
    }

    @Test func unicodeChunkingPreservesEveryByte() {
        let input = String(repeating: "Alice: 決定 👩🏽‍💻 café\n", count: 2000)
        let chunks = OllamaClient.chunks(input)
        #expect(chunks.count > 1)
        #expect(chunks.joined() == input)
        #expect(chunks.allSatisfy { $0.utf8.count <= OllamaClient.inputByteLimit })
    }

    @Test func discoversModelsWithoutGeneration() async throws {
        let client = try client { request in
            #expect(request.url?.path == "/api/tags")
            #expect(request.httpMethod == "GET")
            return (200, ["models": [["name": "qwen3:8b"], ["name": "gemma3:4b"]]])
        }
        #expect(try await client.availableModels() == ["gemma3:4b", "qwen3:8b"])
    }

    @Test func emptyTranscriptDoesNotContactServer() async throws {
        let client = try client { _ in
            Issue.record("Empty input must not make any request")
            return Self.localModel
        }
        await #expect(throws: OllamaError.emptyTranscript) { try await client.summarize(" \n ") }
        #expect(StubProtocol.state.requests.isEmpty)
    }

    @Test func cloudAliasesAreRejectedBeforeSendingTranscript() async throws {
        let client = try client { request in
            #expect(request.url?.path == "/api/show")
            return (200, ["remote_model": "qwen3", "remote_host": "https://ollama.com",
                          "details": ["format": "gguf"]])
        }
        await #expect(throws: OllamaError.remoteModel) { try await client.summarize("private fixture") }
        #expect(StubProtocol.state.requests.count == 1)
    }

    @Test func sendsNonstreamingRequestAndUsesAnswerNotThinking() async throws {
        let client = try client { request in
            if request.url?.path == "/api/show" { return Self.localModel }
            let body = try Self.body(request)
            #expect(request.url?.path == "/api/chat")
            #expect(body["model"] as? String == "qwen3:8b")
            #expect(body["stream"] as? Bool == false)
            #expect(body["think"] as? Bool == false)
            let messages = try #require(body["messages"] as? [[String: String]])
            #expect(messages.last?["content"] == "me: ship Friday")
            return Self.answer("<think>internal</think>\nShip Friday.")
        }
        #expect(try await client.summarize("me: ship Friday") == "Ship Friday.")
    }

    @Test func longMeetingIsChunkedThenSynthesized() async throws {
        let input = String(repeating: "word ", count: 6000)
        let client = try client { request in
            if request.url?.path == "/api/show" { return Self.localModel }
            let body = try Self.body(request)
            let messages = try #require(body["messages"] as? [[String: String]])
            #expect(try #require(messages.last?["content"]).utf8.count <= OllamaClient.inputByteLimit)
            return Self.answer("Decision fixture.")
        }
        #expect(try await client.summarize(input) == "Decision fixture.")
        let requests = StubProtocol.state.requests.filter { $0.url?.path == "/api/chat" }
        #expect(requests.count == 4)
        let contents = try requests.dropLast().map { request in
            let body = try Self.body(request)
            return try #require((body["messages"] as? [[String: String]])?.last?["content"])
        }
        #expect(contents.joined() == input)
    }

    @Test func rejectsFailedEmptyThinkingOnlyAndTruncatedResponses() async throws {
        let cases: [(Int, [String: Any], OllamaError)] = [
            (404, [:], .http(404)),
            (200, ["error": "private fixture"], .serverError),
            (200, ["done": true, "message": ["content": " "]], .emptyResponse),
            (200, ["done": true, "message": ["content": "<think>only thinking"]], .emptyResponse),
            (200, ["done": false, "message": ["content": "partial"]], .incompleteResponse),
            (200, ["done": true, "done_reason": "length", "message": ["content": "partial"]], .incompleteResponse),
        ]
        for (status, payload, error) in cases {
            // Encode before capture so the handler is Sendable under Swift 6.
            let encoded = try JSONSerialization.data(withJSONObject: payload)
            StubProtocol.state.reset { request in
                if request.url?.path == "/api/show" { return (200, try JSONSerialization.data(withJSONObject: Self.localModel.1)) }
                return (status, encoded)
            }
            let client = OllamaClient(settings: try OllamaSettings(model: "qwen3:8b"), session: Self.session())
            await #expect(throws: error) { try await client.summarize("fixture") }
        }
    }

    @Test func failedJobPreservesTranscriptAndDoesNotBlockNextJobThenRetries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        let fixture = try Self.writeTranscript(to: first, text: "failure fixture")
        _ = try Self.writeTranscript(to: second, text: "success fixture")
        let client = try client { request in
            if request.url?.path == "/api/show" { return Self.localModel }
            let body = try Self.body(request)
            let text = (body["messages"] as? [[String: String]])?.last?["content"] ?? ""
            return text.contains("failure fixture") ? (503, [:]) : Self.answer("Successful notes.")
        }
        let queue = SummaryCoordinator(settings: client.settings, client: client)
        try await queue.enqueue(first)
        try await queue.enqueue(second)
        await queue.waitUntilIdle()
        #expect(try Data(contentsOf: first.appendingPathComponent("transcript.json")) == fixture)
        #expect(!FileManager.default.fileExists(atPath: first.appendingPathComponent("summary.md").path))
        #expect(FileManager.default.fileExists(atPath: first.appendingPathComponent(SummaryCoordinator.pendingFilename).path))
        #expect(FileManager.default.fileExists(atPath: second.appendingPathComponent("summary.md").path))
        #expect(!FileManager.default.fileExists(atPath: second.appendingPathComponent(SummaryCoordinator.pendingFilename).path))
        StubProtocol.state.reset { request in
            let response = request.url?.path == "/api/show" ? Self.localModel : Self.answer("Retried notes.")
            return (response.0, try JSONSerialization.data(withJSONObject: response.1))
        }
        try await queue.summarize(first)
        #expect(FileManager.default.fileExists(atPath: first.appendingPathComponent("summary.md").path))
        #expect(try Data(contentsOf: first.appendingPathComponent("transcript.json")) == fixture)
    }

    @Test func resumesOnlyMarkedJobsAndPreservesExistingNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), marked = root.appendingPathComponent("marked")
        _ = try Self.writeTranscript(to: old, text: "old fixture")
        _ = try Self.writeTranscript(to: marked, text: "marked fixture")
        try Data().write(to: marked.appendingPathComponent(SummaryCoordinator.pendingFilename))
        let client = try client { request in request.url?.path == "/api/show" ? Self.localModel : Self.answer("Generated.") }
        let queue = SummaryCoordinator(settings: client.settings, client: client)
        try await queue.resumePending(root: root)
        await queue.waitUntilIdle()
        #expect(!FileManager.default.fileExists(atPath: old.appendingPathComponent("summary.md").path))
        let notes = try Data(contentsOf: marked.appendingPathComponent("summary.md"))
        let requestCount = StubProtocol.state.requests.count
        try await queue.summarize(marked)
        #expect(try Data(contentsOf: marked.appendingPathComponent("summary.md")) == notes)
        #expect(StubProtocol.state.requests.count == requestCount)
    }

    @Test func intentBeforeTranscriptCommitRecoversInterruptedHandoff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let client = try client { request in request.url?.path == "/api/show" ? Self.localModel : Self.answer("Recovered.") }
        let beforeCrash = SummaryCoordinator(settings: client.settings, client: client)
        try await beforeCrash.recordIntent(dir)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(SummaryCoordinator.pendingFilename).path))

        // A crash before the transcript commit must not attempt an empty summary.
        let restarted = SummaryCoordinator(settings: client.settings, client: client)
        try await restarted.resumePending(root: root)
        await restarted.waitUntilIdle()
        #expect(StubProtocol.state.requests.isEmpty)

        // A crash after the commit but before enqueue must still recover the job.
        let fixture = try Self.writeTranscript(to: dir, text: "committed before interruption")
        try await restarted.resumePending(root: root)
        await restarted.waitUntilIdle()
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("summary.md").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(SummaryCoordinator.pendingFilename).path))
        #expect(try Data(contentsOf: dir.appendingPathComponent("transcript.json")) == fixture)
    }

    @Test func oneUnwritablePendingDirectoryDoesNotBlockRecoveryOfLaterJobs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("a-readonly"), second = root.appendingPathComponent("b-ready")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: first.path)
            try? FileManager.default.removeItem(at: root)
        }
        _ = try Self.writeTranscript(to: first, text: "readonly fixture")
        _ = try Self.writeTranscript(to: second, text: "ready fixture")
        for dir in [first, second] {
            try Data().write(to: dir.appendingPathComponent(SummaryCoordinator.pendingFilename))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: first.path)
        let client = try client { request in request.url?.path == "/api/show" ? Self.localModel : Self.answer("Recovered.") }
        let queue = SummaryCoordinator(settings: client.settings, client: client)
        try await queue.resumePending(root: root)
        await queue.waitUntilIdle()
        #expect(FileManager.default.fileExists(atPath: first.appendingPathComponent(SummaryCoordinator.pendingFilename).path))
        #expect(!FileManager.default.fileExists(atPath: first.appendingPathComponent("summary.md").path))
        #expect(FileManager.default.fileExists(atPath: second.appendingPathComponent("summary.md").path))
        #expect(!FileManager.default.fileExists(atPath: second.appendingPathComponent(SummaryCoordinator.pendingFilename).path))
    }

    private static var localModel: (Int, [String: Any]) { (200, ["details": ["format": "gguf"]]) }
    private static func answer(_ content: String) -> (Int, [String: Any]) {
        (200, ["done": true, "message": ["content": content]])
    }
    private func client(handler: @escaping @Sendable (URLRequest) throws -> (Int, [String: Any])) throws -> OllamaClient {
        StubProtocol.state.reset { request in
            let (status, body) = try handler(request)
            return (status, try JSONSerialization.data(withJSONObject: body))
        }
        return OllamaClient(settings: try OllamaSettings(model: "qwen3:8b"), session: Self.session())
    }
    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
    private static func body(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                collected.append(contentsOf: buffer.prefix(count))
            }
            data = collected
        } else { data = Data() }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private static func writeTranscript(to dir: URL, text: String) throws -> Data {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["segments": [["speaker": "me", "start_ms": 0, "text": text]]])
        try data.write(to: dir.appendingPathComponent("transcript.json"))
        return data
    }
}

private final class StubState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }
    func reset(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) {
        lock.withLock { self.handler = handler; recorded = [] }
    }
    func handle(_ request: URLRequest) throws -> (Int, Data) {
        let handler = lock.withLock { recorded.append(request); return self.handler! }
        return try handler(request)
    }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let state = StubState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var recorded = request
            if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                recorded.httpBodyStream = nil
                recorded.httpBody = data
            }
            let (status, data) = try Self.state.handle(recorded)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

import XCTest
@testable import QuireCore

final class AITests: XCTestCase {
    private func body(_ r: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    func testOpenAICompatibleRequest() throws {
        let p = AIProvider(name: "Groq", format: .openAICompatible, baseURL: "https://api.groq.com/openai/v1/", model: "llama",
                           headers: ["X-Title": "Quire"])
        let r = try AIWire.streamRequest(p, apiKey: " sk-123 ", AIRequest(system: "sys", messages: [AIMessage(.user, "hi")]))
        XCTAssertEqual(r.url?.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer sk-123")
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-Title"), "Quire")
        let b = body(r)
        XCTAssertEqual(b["model"] as? String, "llama")
        XCTAssertEqual(b["stream"] as? Bool, true)
        XCTAssertNil(b["max_tokens"])
        let msgs = b["messages"] as? [[String: String]]
        XCTAssertEqual(msgs?.first, ["role": "system", "content": "sys"])
        XCTAssertEqual(msgs?.last, ["role": "user", "content": "hi"])
    }

    func testLocalServerSendsNoAuthorization() throws {
        let p = AIProvider(name: "Ollama", format: .openAICompatible, baseURL: "http://localhost:11434/v1", model: "qwen", needsKey: false)
        let r = try AIWire.streamRequest(p, apiKey: nil, AIRequest(messages: [AIMessage(.user, "hi")]))
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(r.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
    }

    func testAnthropicRequest() throws {
        let p = AIProvider(name: "Anthropic", format: .anthropic, baseURL: "https://api.anthropic.com/v1", model: "claude-opus-5-5")
        let r = try AIWire.streamRequest(p, apiKey: "key", AIRequest(system: "sys", messages: [AIMessage(.user, "hi")], maxTokens: 500))
        XCTAssertEqual(r.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-api-key"), "key")
        XCTAssertEqual(r.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
        let b = body(r)
        XCTAssertEqual(b["system"] as? String, "sys")
        XCTAssertEqual(b["max_tokens"] as? Int, 500)
        XCTAssertEqual(b["fallbacks"] as? String, "default")
        XCTAssertEqual(r.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        XCTAssertEqual((b["messages"] as? [[String: String]])?.count, 1)
    }

    func testAnthropicProxyGetsNoFallbacks() throws {
        let p = AIProvider(name: "Proxy", format: .anthropic, baseURL: "https://proxy.example.com/v1", model: "claude-opus-5-5")
        let r = try AIWire.streamRequest(p, apiKey: "key", AIRequest(messages: [AIMessage(.user, "hi")]))
        XCTAssertNil(body(r)["fallbacks"])
        XCTAssertNil(r.value(forHTTPHeaderField: "anthropic-beta"))
    }

    func testRequestValidation() {
        let noModel = AIProvider(name: "X", format: .openAICompatible, baseURL: "https://x.com/v1")
        XCTAssertThrowsError(try AIWire.streamRequest(noModel, apiKey: nil, AIRequest(messages: [])))
        let badURL = AIProvider(name: "X", format: .openAICompatible, baseURL: "localhost:1234", model: "m")
        XCTAssertThrowsError(try AIWire.streamRequest(badURL, apiKey: nil, AIRequest(messages: [])))
    }

    func testOpenAIStreamDecoding() {
        let f = AIWireFormat.openAICompatible
        XCTAssertEqual(AIWire.decodeStreamLine(#"data: {"choices":[{"delta":{"content":"Hel"}}]}"#, format: f), .text("Hel"))
        XCTAssertEqual(AIWire.decodeStreamLine(#"data:{"choices":[{"delta":{"role":"assistant"}}]}"#, format: f), nil)
        XCTAssertEqual(AIWire.decodeStreamLine("data: [DONE]", format: f), .done)
        XCTAssertEqual(AIWire.decodeStreamLine(": keep-alive", format: f), nil)
        XCTAssertEqual(AIWire.decodeStreamLine(#"data: {"error":{"message":"bad model"}}"#, format: f), .failure("bad model"))
    }

    func testAnthropicStreamDecoding() {
        let f = AIWireFormat.anthropic
        XCTAssertEqual(AIWire.decodeStreamLine("event: content_block_delta", format: f), nil)
        XCTAssertEqual(AIWire.decodeStreamLine(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#, format: f), .text("Hi"))
        XCTAssertEqual(AIWire.decodeStreamLine(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"…"}}"#, format: f), nil)
        XCTAssertEqual(AIWire.decodeStreamLine(#"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#, format: f), .failure("The model declined this request."))
        XCTAssertEqual(AIWire.decodeStreamLine(#"data: {"type":"message_stop"}"#, format: f), .done)
        XCTAssertEqual(AIWire.decodeStreamLine(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, format: f), .failure("Overloaded"))
    }

    func testModelListParsing() throws {
        XCTAssertEqual(try AIWire.parseModels(Data(#"{"data":[{"id":"b"},{"id":"a"}]}"#.utf8)), ["a", "b"])
        XCTAssertEqual(try AIWire.parseModels(Data(#"{"data":[{"id":"models/gemini-x"}]}"#.utf8)), ["gemini-x"])
        XCTAssertEqual(try AIWire.parseModels(Data(#"{"models":[{"name":"llama3:8b"}]}"#.utf8)), ["llama3:8b"])
        XCTAssertThrowsError(try AIWire.parseModels(Data(#"{"error":{"message":"no"}}"#.utf8)))
    }

    func testHTTPErrorMessage() {
        let e = AIWire.httpError(status: 401, body: Data(#"{"error":{"message":"invalid x-api-key"}}"#.utf8))
        XCTAssertEqual(e.message, "HTTP 401: invalid x-api-key Check the API key.")
        XCTAssertEqual(AIWire.httpError(status: 500, body: Data("oops".utf8)).message, "HTTP 500: oops")
    }

    func testProviderListRoundTripAndLenientDecoding() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("p.json")
        let list = AIProviderList(providers: [AIProvider.presets[0], AIProvider.presets[10]], defaultID: AIProvider.presets[10].id)
        try list.save(to: url)
        XCTAssertEqual(AIProviderList.load(from: url), list)
        XCTAssertEqual(AIProviderList.load(from: url).defaultProvider?.name, "Ollama (local)")

        // Hand-written entries only need a name and base URL.
        let json = #"{"providers":[{"name":"vLLM","baseURL":"http://gpu:8000/v1","model":"m"}]}"#
        let decoded = try JSONDecoder().decode(AIProviderList.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.providers.first?.format, .openAICompatible)
        XCTAssertEqual(decoded.defaultProvider?.name, "vLLM")
    }

    func testInterleavedDiff() {
        let d = LineDiff.interleaved(old: "a\nb\nc\n", new: "a\nB\nc\nd\n")
        XCTAssertEqual(d.text, "a\nb\nB\nc\nd\n")
        XCTAssertEqual(d.changes.map(\.kind), [.deleted, .inserted, .inserted])
        XCTAssertEqual(d.changes.map(\.range), [NSRange(location: 2, length: 2), NSRange(location: 4, length: 2), NSRange(location: 8, length: 2)])
        XCTAssertTrue(LineDiff.interleaved(old: "same\n", new: "same\n").changes.isEmpty)
    }

    func testStripFence() {
        XCTAssertEqual(AIText.stripFence("```swift\nlet a = 1\n```", matchTrailingNewlineOf: "let a=1\n"), "let a = 1\n")
        XCTAssertEqual(AIText.stripFence("  plain  \n", matchTrailingNewlineOf: "x"), "plain")
        XCTAssertEqual(AIText.stripFence("a ``` b", matchTrailingNewlineOf: "x"), "a ``` b")
    }

    // MARK: Streaming through URLSession

    private func session(status: Int, body: String) -> URLSession {
        StubProtocol.status = status
        StubProtocol.body = Data(body.utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    private func collect(_ p: AIProvider, _ s: URLSession) async throws -> String {
        var out = ""
        for try await chunk in AIClient.stream(p, apiKey: "k", AIRequest(messages: [AIMessage(.user, "hi")]), session: s) { out += chunk }
        return out
    }

    func testStreamsOpenAICompatible() async throws {
        let sse = """
            data: {"choices":[{"delta":{"role":"assistant"}}]}

            data: {"choices":[{"delta":{"content":"Hello"}}]}

            data: {"choices":[{"delta":{"content":", world"}}]}

            data: [DONE]

            """
        let p = AIProvider(name: "x", format: .openAICompatible, baseURL: "https://stub.test/v1", model: "m")
        let out = try await collect(p, session(status: 200, body: sse))
        XCTAssertEqual(out, "Hello, world")
    }

    func testStreamsAnthropic() async throws {
        let sse = """
            event: message_start
            data: {"type":"message_start","message":{"id":"m"}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" there"}}

            event: message_stop
            data: {"type":"message_stop"}

            """
        let p = AIProvider(name: "x", format: .anthropic, baseURL: "https://stub.test/v1", model: "m")
        let out = try await collect(p, session(status: 200, body: sse))
        XCTAssertEqual(out, "Hi there")
    }

    func testStreamHTTPErrorSurfacesMessage() async {
        let p = AIProvider(name: "x", format: .openAICompatible, baseURL: "https://stub.test/v1", model: "m")
        do {
            _ = try await collect(p, session(status: 404, body: #"{"error":{"message":"model not found"}}"#))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "HTTP 404: model not found Check the base URL and model name.")
        }
    }
}

private final class StubProtocol: URLProtocol {
    static var status = 200
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let r = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
                                headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

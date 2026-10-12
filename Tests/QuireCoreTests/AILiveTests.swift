import XCTest
@testable import QuireCore

/// Talks to real local model servers. Skipped unless QUIRE_AI_LIVE is set, e.g.
///   QUIRE_AI_LIVE=1 swift test --filter AILiveTests
/// Each server is tried only if it's running.
final class AILiveTests: XCTestCase {
    private let servers = [
        AIProvider(name: "Ollama", format: .openAICompatible, baseURL: "http://localhost:11434/v1", model: "", needsKey: false),
        AIProvider(name: "LM Studio", format: .openAICompatible, baseURL: "http://localhost:1234/v1", model: "", needsKey: false),
        AIProvider(name: "llama.cpp", format: .openAICompatible, baseURL: "http://localhost:8080/v1", model: "", needsKey: false),
    ]

    func testLocalServersTransformText() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["QUIRE_AI_LIVE"] == nil, "set QUIRE_AI_LIVE=1 to run")
        var tried = 0
        for var p in servers {
            guard let models = try? await AIClient.listModels(p, apiKey: nil),
                  let model = models.first(where: { !$0.contains("embed") }) else { continue }
            tried += 1
            p.model = model
            let input = "let x = 0\nx += 1\n"
            let request = AIRequest(system: AIText.transformSystemPrompt, messages: [AIMessage(.user,
                AIText.transformPrompt(instruction: "Rename the variable x to count", text: input, language: "Swift", fileName: "a.swift"))])
            let reply = AIText.stripFence(try await AIClient.complete(p, apiKey: nil, request), matchTrailingNewlineOf: input)
            print("[\(p.name) · \(model)] \(reply.debugDescription)")
            XCTAssertTrue(reply.contains("count"), "\(p.name): \(reply)")
            XCTAssertFalse(reply.contains("```"), "\(p.name): \(reply)")
        }
        try XCTSkipIf(tried == 0, "no local model server is running")
    }
}

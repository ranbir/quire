import Foundation

// Bring-your-own-model support. Almost every hosted and local model server
// speaks the OpenAI Chat Completions protocol (OpenAI, Gemini, OpenRouter,
// Groq, Mistral, DeepSeek, xAI, Together, Fireworks, Ollama, LM Studio,
// llama.cpp, vLLM…); Anthropic gets its native Messages API. A provider is just
// a wire format, base URL, model and optional extra headers. API keys are not
// part of it: the app keeps them in the Keychain and passes them in.

public enum AIWireFormat: String, Codable, CaseIterable {
    case openAICompatible = "openai"
    case anthropic

    public var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI-compatible"
        case .anthropic: return "Anthropic Messages"
        }
    }
}

public struct AIProvider: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var format: AIWireFormat
    public var baseURL: String
    public var model: String
    /// Sent with every request, e.g. `api-key` for Azure or `HTTP-Referer` for OpenRouter.
    public var headers: [String: String]
    /// Local servers (Ollama, LM Studio…) usually don't take a key.
    public var needsKey: Bool

    public init(id: String = UUID().uuidString, name: String, format: AIWireFormat, baseURL: String,
                model: String = "", headers: [String: String] = [:], needsKey: Bool = true) {
        self.id = id; self.name = name; self.format = format; self.baseURL = baseURL
        self.model = model; self.headers = headers; self.needsKey = needsKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        format = try c.decodeIfPresent(AIWireFormat.self, forKey: .format) ?? .openAICompatible
        baseURL = try c.decode(String.self, forKey: .baseURL)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        needsKey = try c.decodeIfPresent(Bool.self, forKey: .needsKey) ?? true
    }

    /// Starting points offered by the + button; every field stays editable.
    public static let presets: [AIProvider] = [
        AIProvider(name: "Anthropic", format: .anthropic, baseURL: "https://api.anthropic.com/v1", model: "claude-opus-5-5"),
        AIProvider(name: "OpenAI", format: .openAICompatible, baseURL: "https://api.openai.com/v1"),
        AIProvider(name: "Google Gemini", format: .openAICompatible, baseURL: "https://generativelanguage.googleapis.com/v1beta/openai"),
        AIProvider(name: "OpenRouter", format: .openAICompatible, baseURL: "https://openrouter.ai/api/v1"),
        AIProvider(name: "Groq", format: .openAICompatible, baseURL: "https://api.groq.com/openai/v1"),
        AIProvider(name: "Mistral", format: .openAICompatible, baseURL: "https://api.mistral.ai/v1"),
        AIProvider(name: "DeepSeek", format: .openAICompatible, baseURL: "https://api.deepseek.com/v1"),
        AIProvider(name: "xAI", format: .openAICompatible, baseURL: "https://api.x.ai/v1"),
        AIProvider(name: "Together AI", format: .openAICompatible, baseURL: "https://api.together.xyz/v1"),
        AIProvider(name: "Fireworks", format: .openAICompatible, baseURL: "https://api.fireworks.ai/inference/v1"),
        AIProvider(name: "Ollama (local)", format: .openAICompatible, baseURL: "http://localhost:11434/v1", needsKey: false),
        AIProvider(name: "LM Studio (local)", format: .openAICompatible, baseURL: "http://localhost:1234/v1", needsKey: false),
        AIProvider(name: "llama.cpp server (local)", format: .openAICompatible, baseURL: "http://localhost:8080/v1", needsKey: false),
        AIProvider(name: "Custom OpenAI-compatible", format: .openAICompatible, baseURL: "http://localhost:8000/v1", needsKey: false),
    ]
}

public struct AIMessage: Equatable {
    public enum Role: String { case user, assistant }
    public var role: Role
    public var content: String
    public init(_ role: Role, _ content: String) { self.role = role; self.content = content }
}

public struct AIRequest {
    public var system: String?
    public var messages: [AIMessage]
    /// Required by Anthropic; left to the server's default for OpenAI-compatible
    /// endpoints, where reasoning models reject `max_tokens`.
    public var maxTokens: Int
    public init(system: String? = nil, messages: [AIMessage], maxTokens: Int = 64000) {
        self.system = system; self.messages = messages; self.maxTokens = maxTokens
    }
}

public struct AIError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// One decoded line of a streamed response.
public enum AIStreamEvent: Equatable {
    case text(String)
    case done
    case failure(String)
}

/// Request building and response parsing, kept free of networking so it can be tested.
public enum AIWire {
    static let anthropicVersion = "2023-06-01"
    /// Anthropic models that accept server-side refusal fallbacks.
    static let fallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    static func endpoint(_ provider: AIProvider, _ path: String) throws -> URL {
        var base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path), url.scheme == "http" || url.scheme == "https" else {
            throw AIError("“\(provider.baseURL)” isn’t a valid http(s) base URL.")
        }
        return url
    }

    static func addHeaders(_ r: inout URLRequest, _ provider: AIProvider, apiKey: String?) {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch provider.format {
        case .openAICompatible:
            if !key.isEmpty { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .anthropic:
            if !key.isEmpty { r.setValue(key, forHTTPHeaderField: "x-api-key") }
            r.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        }
        for (k, v) in provider.headers { r.setValue(v, forHTTPHeaderField: k) }
    }

    public static func streamRequest(_ provider: AIProvider, apiKey: String?, _ request: AIRequest) throws -> URLRequest {
        guard !provider.model.isEmpty else { throw AIError("No model is set for “\(provider.name)”.") }
        var body: [String: Any] = ["model": provider.model, "stream": true]
        var r: URLRequest
        switch provider.format {
        case .openAICompatible:
            r = URLRequest(url: try endpoint(provider, "/chat/completions"))
            var messages: [[String: String]] = []
            if let s = request.system, !s.isEmpty { messages.append(["role": "system", "content": s]) }
            messages += request.messages.map { ["role": $0.role.rawValue, "content": $0.content] }
            body["messages"] = messages
        case .anthropic:
            r = URLRequest(url: try endpoint(provider, "/messages"))
            body["max_tokens"] = request.maxTokens
            if let s = request.system, !s.isEmpty { body["system"] = s }
            body["messages"] = request.messages.map { ["role": $0.role.rawValue, "content": $0.content] }
            if r.url?.host == "api.anthropic.com", fallbackModels.contains(provider.model) {
                body["fallbacks"] = "default"
                r.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            }
        }
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        addHeaders(&r, provider, apiKey: apiKey)
        r.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return r
    }

    public static func modelsRequest(_ provider: AIProvider, apiKey: String?) throws -> URLRequest {
        var r = URLRequest(url: try endpoint(provider, provider.format == .anthropic ? "/models?limit=1000" : "/models"))
        addHeaders(&r, provider, apiKey: apiKey)
        return r
    }

    /// Model ids from a `/models` listing (`{"data":[{"id":…}]}` for both formats;
    /// some local servers return `{"models":[{"name":…}]}`).
    public static func parseModels(_ data: Data) throws -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError("The server’s model list isn’t JSON.")
        }
        if let msg = errorMessage(in: obj) { throw AIError(msg) }
        let items = (obj["data"] ?? obj["models"]) as? [[String: Any]] ?? []
        let ids = items.compactMap { ($0["id"] ?? $0["name"]) as? String }
        return ids.map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }.sorted()
    }

    /// Decodes one line of a server-sent event stream. Only `data:` lines carry
    /// anything we need; both formats tag each payload with enough to decode it alone.
    public static func decodeStreamLine(_ line: String, format: AIWireFormat) -> AIStreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return nil }
        if let msg = errorMessage(in: obj) { return .failure(msg) }
        switch format {
        case .openAICompatible:
            guard let choice = (obj["choices"] as? [[String: Any]])?.first else { return nil }
            if let s = (choice["delta"] as? [String: Any])?["content"] as? String, !s.isEmpty { return .text(s) }
            if let reason = choice["finish_reason"] as? String, reason == "content_filter" {
                return .failure("The model’s content filter stopped the response.")
            }
            return nil
        case .anthropic:
            switch obj["type"] as? String {
            case "content_block_delta":
                guard let delta = obj["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                      let s = delta["text"] as? String else { return nil }
                return .text(s)
            case "message_delta":
                if (obj["delta"] as? [String: Any])?["stop_reason"] as? String == "refusal" {
                    return .failure("The model declined this request.")
                }
                return nil
            case "message_stop": return .done
            default: return nil
            }
        }
    }

    /// The human-readable message from an error body, whatever shape it has.
    public static func errorMessage(in obj: [String: Any]) -> String? {
        if let err = obj["error"] as? [String: Any] { return err["message"] as? String ?? "Unknown error" }
        if let err = obj["error"] as? String { return err }
        if obj["type"] as? String == "error" { return "Unknown error" }
        return nil
    }

    public static func httpError(status: Int, body: Data) -> AIError {
        let detail = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]).flatMap { errorMessage(in: $0) }
            ?? String(decoding: body.prefix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let hint: String
        switch status {
        case 401, 403: hint = " Check the API key."
        case 404: hint = " Check the base URL and model name."
        case 429: hint = " Rate limited; try again shortly."
        default: hint = ""
        }
        return AIError("HTTP \(status)" + (detail.isEmpty ? "." : ": \(detail)") + hint)
    }
}

/// Streams completions from any configured provider.
public enum AIClient {
    public static func stream(_ provider: AIProvider, apiKey: String?, _ request: AIRequest,
                              session: URLSession = .shared) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try AIWire.streamRequest(provider, apiKey: apiKey, request)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                    guard (200..<300).contains(status) else {
                        var body = Data()
                        for try await b in bytes { body.append(b); if body.count > 64_000 { break } }
                        throw AIWire.httpError(status: status, body: body)
                    }
                    lines: for try await line in bytes.lines {
                        switch AIWire.decodeStreamLine(line, format: provider.format) {
                        case .text(let s): continuation.yield(s)
                        case .failure(let msg): throw AIError(msg)
                        case .done: break lines
                        case nil: continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public static func complete(_ provider: AIProvider, apiKey: String?, _ request: AIRequest) async throws -> String {
        var out = ""
        for try await chunk in stream(provider, apiKey: apiKey, request) { out += chunk }
        return out
    }

    public static func listModels(_ provider: AIProvider, apiKey: String?, session: URLSession = .shared) async throws -> [String] {
        let (data, response) = try await session.data(for: AIWire.modelsRequest(provider, apiKey: apiKey))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else { throw AIWire.httpError(status: status, body: data) }
        return try AIWire.parseModels(data)
    }
}

/// The configured providers, stored as editable JSON (no secrets).
public struct AIProviderList: Codable, Equatable {
    public var providers: [AIProvider]
    public var defaultID: String?

    public init(providers: [AIProvider] = [], defaultID: String? = nil) {
        self.providers = providers; self.defaultID = defaultID
    }

    public var defaultProvider: AIProvider? {
        providers.first { $0.id == defaultID } ?? providers.first
    }

    public static func load(from url: URL) -> AIProviderList {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode(AIProviderList.self, from: data) else { return AIProviderList() }
        return list
    }

    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(self).write(to: url, options: .atomic)
    }
}

public enum AIText {
    /// Models often wrap code in a Markdown fence despite being asked not to.
    /// Strips one fence around the whole reply, keeping the input's trailing newline policy.
    public static func stripFence(_ reply: String, matchTrailingNewlineOf input: String) -> String {
        var s = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```"), s.hasSuffix("```"), s.count >= 6 {
            var lines = s.components(separatedBy: "\n")
            if lines.count >= 2 {
                lines.removeFirst()
                if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
                s = lines.joined(separator: "\n")
            }
        }
        if input.hasSuffix("\n") && !s.hasSuffix("\n") { s += "\n" }
        return s
    }

    public static let transformSystemPrompt = """
        You are the text-transformation engine inside a code editor. The user gives an \
        instruction and a piece of text from their file. Apply the instruction to the text \
        and reply with only the resulting text, exactly as it should appear in the file: no \
        explanation, no preamble, no Markdown code fences. Preserve the original indentation \
        style and line endings unless the instruction says otherwise.
        """

    public static func transformPrompt(instruction: String, text: String, language: String?, fileName: String?) -> String {
        var ctx: [String] = []
        if let fileName { ctx.append("File: \(fileName)") }
        if let language, language != "Plain Text" { ctx.append("Language: \(language)") }
        return (ctx.isEmpty ? "" : ctx.joined(separator: "\n") + "\n\n")
            + "Instruction: \(instruction)\n\n<text>\n\(text)\n</text>"
    }
}

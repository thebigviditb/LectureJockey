import Foundation

/// One model call, independent of who serves it. The interpreter builds it; a backend
/// translates it into its own request format.
public struct ModelRequest: @unchecked Sendable {
    /// Stays the same for every command (cacheable).
    public let instructions: String
    /// Stays the same for every command on one video (cacheable).
    public let transcript: String
    /// Changes every command: player state and what was said.
    public let user: String
    /// Each tool: ["name", "description", "inputSchema": ["json": JSON schema]].
    public let tools: [[String: Any]]
}

public struct ModelReply: @unchecked Sendable {
    public let toolUses: [BedrockClient.ToolUse]
    public let text: String
    public let stopReason: String
    public let usage: BedrockClient.Usage
    public let latencyMs: Int
}

/// A model that can answer a `ModelRequest` with tool calls.
public protocol ModelBackend: Sendable {
    /// Shown in the log, e.g. "bedrock us.anthropic.claude-haiku-4-5-...".
    var label: String { get }
    func complete(_ request: ModelRequest) throws -> ModelReply
}

/// Settings: KEY=VALUE lines in ~/Library/Application Support/LectureJockey/config
/// (written by setup), overridden by environment variables of the same name.
public enum Settings {
    public static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LectureJockey/config")

    public static func load(file: URL = Settings.file, environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var values = parse((try? String(contentsOf: file, encoding: .utf8)) ?? "")
        for (k, v) in environment where k.hasPrefix("LJ_") || k == "ANTHROPIC_API_KEY" { values[k] = v }
        return values
    }

    /// Ignores blank lines and # comments; values may be quoted.
    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, f == value.last, f == "\"" || f == "'" { value = String(value.dropFirst().dropLast()) }
            if !key.isEmpty { out[key] = value }
        }
        return out
    }
}

/// Choosing a backend from settings:
///   LJ_BACKEND=ollama    (default) LJ_OLLAMA_URL (default http://127.0.0.1:11434), LJ_MODEL (default qwen3:4b-instruct)
///   LJ_BACKEND=anthropic ANTHROPIC_API_KEY, or the Keychain item LectureJockey/anthropic; LJ_MODEL (default claude-haiku-5-5)
///   LJ_BACKEND=bedrock   LJ_AWS_PROFILE (default "default"), LJ_AWS_REGION (default us-west-2), LJ_MODEL
///   LJ_BACKEND=none      grammar only
public enum Backends {
    public static func fromEnvironment(_ env: [String: String] = Settings.load()) throws -> ModelBackend? {
        switch env["LJ_BACKEND"] ?? "ollama" {
        case "none":
            return nil
        case "bedrock":
            let creds = try AWSCredentials.fromProfile(env["LJ_AWS_PROFILE"] ?? "default")
            return BedrockBackend(client: BedrockClient(credentials: creds, region: env["LJ_AWS_REGION"] ?? "us-west-2"),
                                  model: env["LJ_MODEL"] ?? BedrockBackend.defaultModel)
        case "anthropic":
            guard let key = env["ANTHROPIC_API_KEY"] ?? Keychain.read(service: "LectureJockey", account: "anthropic") else {
                throw BackendError.missingKey
            }
            return AnthropicBackend(apiKey: key, model: env["LJ_MODEL"] ?? AnthropicBackend.defaultModel)
        case "ollama":
            return OllamaBackend(base: URL(string: env["LJ_OLLAMA_URL"] ?? "http://127.0.0.1:11434")!,
                                 model: env["LJ_MODEL"] ?? OllamaBackend.defaultModel)
        case let other:
            throw BackendError.unknown(other)
        }
    }
}

public enum BackendError: Error, CustomStringConvertible {
    case missingKey, unknown(String), http(String, Int, String), badResponse(String)
    public var description: String {
        switch self {
        case .missingKey: return "LJ_BACKEND=anthropic needs ANTHROPIC_API_KEY or the Keychain item LectureJockey/anthropic"
        case .unknown(let b): return "unknown LJ_BACKEND \(b) (ollama, anthropic, bedrock or none)"
        case .http(let who, let code, let body): return "\(who) HTTP \(code): \(body)"
        case .badResponse(let who): return "\(who) returned an unexpected response"
        }
    }
}

// MARK: - Bedrock (Converse API, SigV4)

public struct BedrockBackend: ModelBackend {
    public static let defaultModel = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
    public let client: BedrockClient
    public let model: String
    public var label: String { "bedrock \(model)" }

    public init(client: BedrockClient, model: String = BedrockBackend.defaultModel) {
        self.client = client
        self.model = model
    }

    /// Instructions and transcript before a cache point; a tool call is required.
    public static func body(_ r: ModelRequest) -> [String: Any] {
        [
            "system": [["text": r.instructions], ["text": r.transcript], ["cachePoint": ["type": "default"]]],
            "messages": [["role": "user", "content": [["text": r.user]]]],
            "toolConfig": ["tools": r.tools.map { ["toolSpec": $0] }, "toolChoice": ["any": [String: Any]()]],
            "inferenceConfig": ["maxTokens": 400],
        ]
    }

    public func complete(_ request: ModelRequest) throws -> ModelReply {
        let r = try client.converse(model: model, body: Self.body(request))
        return ModelReply(toolUses: r.toolUses, text: r.text, stopReason: r.stopReason, usage: r.usage, latencyMs: r.latencyMs)
    }
}

// MARK: - Anthropic API (the user's own key)

public struct AnthropicBackend: ModelBackend {
    public static let defaultModel = "claude-haiku-5-5"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public let apiKey: String
    public let model: String
    public var timeout: TimeInterval = 15
    public var label: String { "anthropic \(model)" }

    public init(apiKey: String, model: String = AnthropicBackend.defaultModel) {
        self.apiKey = apiKey
        self.model = model
    }

    public static func body(_ r: ModelRequest, model: String) -> [String: Any] {
        [
            "model": model,
            "max_tokens": 400,
            "system": [["type": "text", "text": r.instructions],
                       ["type": "text", "text": r.transcript, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": r.user]],
            "tools": r.tools.map { t -> [String: Any] in
                ["name": t["name"] ?? "", "description": t["description"] ?? "",
                 "input_schema": (t["inputSchema"] as? [String: Any])?["json"] ?? [:]]
            },
            // A tool call is required (no_action covers "do nothing"). Haiku accepts "any";
            // Opus 5.5 and Sonnet 5.5 would reject it, so set LJ_MODEL to a Haiku here.
            "tool_choice": ["type": "any"],
        ]
    }

    public func complete(_ request: ModelRequest) throws -> ModelReply {
        var req = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: Self.body(request, model: model))
        let started = Date()
        let (data, status) = try HTTP.send(req)
        guard status == 200 else { throw BackendError.http("Anthropic", status, String(decoding: data.prefix(300), as: UTF8.self)) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else { throw BackendError.badResponse("Anthropic") }
        var tools: [BedrockClient.ToolUse] = []
        var text = ""
        for b in content {
            if b["type"] as? String == "tool_use", let name = b["name"] as? String {
                tools.append(.init(name: name, input: b["input"] as? [String: Any] ?? [:]))
            } else if let t = b["text"] as? String { text += t }
        }
        let u = obj["usage"] as? [String: Any] ?? [:]
        return ModelReply(toolUses: tools, text: text, stopReason: obj["stop_reason"] as? String ?? "",
                          usage: .init(inputTokens: u["input_tokens"] as? Int ?? 0, outputTokens: u["output_tokens"] as? Int ?? 0,
                                       cacheReadTokens: u["cache_read_input_tokens"] as? Int ?? 0,
                                       cacheWriteTokens: u["cache_creation_input_tokens"] as? Int ?? 0),
                          latencyMs: Int(Date().timeIntervalSince(started) * 1000))
    }
}

// MARK: - Ollama (local model)

public struct OllamaBackend: ModelBackend {
    public static let defaultModel = "qwen3:4b-instruct"
    public let base: URL
    public let model: String
    /// Large enough for a one-hour transcript (~13k tokens) plus instructions.
    public var contextTokens = 20480
    /// Ollama unloads the model after this long idle, freeing its memory.
    public var keepAlive = "5m"
    public var timeout: TimeInterval = 120
    public var label: String { "ollama \(model)" }

    public init(base: URL = URL(string: "http://127.0.0.1:11434")!, model: String = OllamaBackend.defaultModel) {
        self.base = base
        self.model = model
    }

    public func body(_ r: ModelRequest) -> [String: Any] {
        [
            "model": model,
            "stream": false,
            "think": false,
            "keep_alive": keepAlive,
            "options": ["temperature": 0, "num_ctx": contextTokens, "num_predict": 300],
            // One system message (instructions then transcript) keeps the prefix identical
            // across commands, so Ollama can reuse its cached prompt.
            "messages": [["role": "system", "content": r.instructions + "\n\n" + r.transcript],
                         // Qwen3 ignores "think": false in some Ollama versions; /no_think is its own switch.
                         ["role": "user", "content": r.user + (model.hasPrefix("qwen3") ? " /no_think" : "")]],
            "tools": r.tools.map { t -> [String: Any] in
                ["type": "function", "function": ["name": t["name"] ?? "", "description": t["description"] ?? "",
                                                  "parameters": (t["inputSchema"] as? [String: Any])?["json"] ?? [:]]]
            },
        ]
    }

    public func complete(_ request: ModelRequest) throws -> ModelReply {
        var req = URLRequest(url: base.appendingPathComponent("api/chat"), timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body(request))
        let started = Date()
        let (data, status) = try HTTP.send(req)
        guard status == 200 else { throw BackendError.http("Ollama", status, String(decoding: data.prefix(300), as: UTF8.self)) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? [String: Any] else { throw BackendError.badResponse("Ollama") }
        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { c -> BedrockClient.ToolUse? in
            guard let f = c["function"] as? [String: Any], let name = f["name"] as? String else { return nil }
            var args = f["arguments"] as? [String: Any] ?? [:]
            if args.isEmpty, let s = f["arguments"] as? String, let d = s.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { args = parsed }
            return .init(name: name, input: args)
        }
        return ModelReply(toolUses: calls, text: message["content"] as? String ?? "", stopReason: obj["done_reason"] as? String ?? "",
                          usage: .init(inputTokens: obj["prompt_eval_count"] as? Int ?? 0, outputTokens: obj["eval_count"] as? Int ?? 0,
                                       cacheReadTokens: 0, cacheWriteTokens: 0),
                          latencyMs: Int(Date().timeIntervalSince(started) * 1000))
    }
}

/// Reads a Keychain item through `/usr/bin/security`, the tool that saved it (setup runs
/// `security add-generic-password -s LectureJockey -a anthropic -w`), so reading it never
/// prompts, even after a rebuild changes this binary's signature.
enum Keychain {
    static func read(service: String, account: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}

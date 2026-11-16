import Foundation

// MARK: - Prism endpoint: one shape for three APIs
//
// Clients speak Anthropic Messages, OpenAI Chat Completions or OpenAI
// Responses; upstream providers speak Messages (Anthropic) or Chat
// Completions (OpenAI, xAI, local servers). When the client and the
// provider share an API the request passes through untouched (only the
// model and credentials change). Otherwise it is parsed into the canonical
// request below and rebuilt for the provider, and the reply is converted
// back the same way.

typealias JSONObject = [String: Any]

enum GatewayJSON {
    static func parse(_ data: Data) -> JSONObject? {
        (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
    }

    static func data(_ value: Any) -> Data {
        guard JSONSerialization.isValidJSONObject(value),
              let d = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]) else {
            return Data("{}".utf8)
        }
        return d
    }

    static func string(_ value: Any) -> String {
        String(decoding: data(value), as: UTF8.self)
    }

    /// Parse a JSON text that may be any value (tool arguments are usually
    /// objects but providers sometimes send other values).
    static func value(fromString s: String) -> Any? {
        guard let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }

    static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
}

enum GatewayID {
    static func make(_ prefix: String) -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return prefix + String(hex.prefix(24))
    }

    /// Anthropic tool ids must match ^[a-zA-Z0-9_-]+$.
    static func toolID(_ raw: String) -> String {
        let cleaned = String(raw.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" ? Character($0) : "_"
        })
        return cleaned.isEmpty ? make("toolu_") : cleaned
    }
}

/// The three client-facing APIs.
enum GatewayAPI: String, Sendable {
    case anthropic
    case chat
    case responses

    var label: String {
        switch self {
        case .anthropic: return "Messages"
        case .chat: return "Chat"
        case .responses: return "Responses"
        }
    }
}

// MARK: - Canonical request

enum CanonPart {
    case text(String)
    case image(mediaType: String, base64: String?, url: String?)
    case toolCall(id: String, name: String, arguments: String)
    case toolResult(id: String, content: String, isError: Bool)
}

struct CanonMessage {
    enum Role { case user, assistant }
    var role: Role
    var parts: [CanonPart]
}

struct CanonTool {
    var name: String
    var description: String?
    var schema: JSONObject
    /// A Responses "custom" (free-form text) tool, exposed upstream as a
    /// function with one string argument named "input".
    var custom = false
}

enum CanonToolChoice {
    case auto, none, required
    case named(String)
}

struct CanonRequest {
    var model = ""
    var system: String?
    var messages: [CanonMessage] = []
    var tools: [CanonTool] = []
    var toolChoice: CanonToolChoice?
    var maxTokens: Int?
    var temperature: Double?
    var topP: Double?
    var stop: [String] = []
    var stream = false
    var reasoningEffort: String?
    var parallelToolCalls: Bool?

    var customToolNames: Set<String> {
        Set(tools.filter(\.custom).map(\.name))
    }
}

enum CanonStop {
    case end, maxTokens, toolUse, stopSequence, refusal
}

struct CanonUsage {
    /// Uncached input tokens (Anthropic's meaning).
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0

    var totalInput: Int { input + cacheRead + cacheWrite }
}

struct CanonResponse {
    var id: String
    var model: String
    var parts: [CanonPart]
    var reasoning = ""
    var stop: CanonStop = .end
    var usage = CanonUsage()
}

// MARK: - Shared helpers

private func dataURL(mediaType: String, base64: String) -> String {
    "data:\(mediaType);base64,\(base64)"
}

/// "data:image/png;base64,AAAA" → ("image/png", "AAAA").
private func splitDataURL(_ s: String) -> (String, String)? {
    guard s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") else { return nil }
    let meta = s[s.index(s.startIndex, offsetBy: 5)..<comma]
    guard meta.hasSuffix(";base64") else { return nil }
    let media = String(meta.dropLast(7))
    return (media.isEmpty ? "image/png" : media, String(s[s.index(after: comma)...]))
}

private func imagePart(fromURL url: String) -> CanonPart {
    if let (media, b64) = splitDataURL(url) {
        return .image(mediaType: media, base64: b64, url: nil)
    }
    return .image(mediaType: "image/png", base64: nil, url: url)
}

/// Text of a content value that may be a string or an array of blocks.
private func flattenText(_ content: Any?) -> String {
    if let s = content as? String { return s }
    guard let blocks = content as? [Any] else { return "" }
    var out: [String] = []
    for case let b as JSONObject in blocks {
        if let t = b["text"] as? String {
            out.append(t)
        } else if let type = b["type"] as? String, type.contains("image") {
            out.append("[image]")
        }
    }
    return out.joined(separator: "\n")
}

private func stopSequences(_ v: Any?) -> [String] {
    if let s = v as? String { return [s] }
    return (v as? [Any])?.compactMap { $0 as? String } ?? []
}

// MARK: - Parse: Anthropic Messages

extension CanonRequest {
    init(anthropic j: JSONObject) {
        model = j["model"] as? String ?? ""
        if let s = j["system"] as? String {
            system = s
        } else if let blocks = j["system"] as? [Any] {
            let text = flattenText(blocks)
            system = text.isEmpty ? nil : text
        }
        for case let m as JSONObject in (j["messages"] as? [Any] ?? []) {
            let role: CanonMessage.Role = (m["role"] as? String) == "assistant" ? .assistant : .user
            var parts: [CanonPart] = []
            if let s = m["content"] as? String {
                parts.append(.text(s))
            } else {
                for case let b as JSONObject in (m["content"] as? [Any] ?? []) {
                    switch b["type"] as? String {
                    case "text":
                        parts.append(.text(b["text"] as? String ?? ""))
                    case "image":
                        let src = b["source"] as? JSONObject ?? [:]
                        if (src["type"] as? String) == "url", let url = src["url"] as? String {
                            parts.append(.image(mediaType: "image/png", base64: nil, url: url))
                        } else {
                            parts.append(.image(mediaType: src["media_type"] as? String ?? "image/png",
                                                base64: src["data"] as? String, url: nil))
                        }
                    case "tool_use", "server_tool_use":
                        let input = b["input"] ?? [String: Any]()
                        parts.append(.toolCall(id: b["id"] as? String ?? GatewayID.make("toolu_"),
                                               name: b["name"] as? String ?? "",
                                               arguments: GatewayJSON.string(input)))
                    case "tool_result":
                        parts.append(.toolResult(id: b["tool_use_id"] as? String ?? "",
                                                 content: flattenText(b["content"]),
                                                 isError: b["is_error"] as? Bool ?? false))
                    case "document":
                        parts.append(.text("[document omitted]"))
                    default:
                        // thinking, redacted_thinking, search results: provider-specific.
                        break
                    }
                }
            }
            messages.append(CanonMessage(role: role, parts: parts))
        }
        for case let t as JSONObject in (j["tools"] as? [Any] ?? []) {
            // Server tools (web_search_…, code_execution_…) have no schema
            // and only exist on Anthropic.
            guard let name = t["name"] as? String, t["input_schema"] != nil || t["type"] == nil else { continue }
            tools.append(CanonTool(name: name,
                                   description: t["description"] as? String,
                                   schema: t["input_schema"] as? JSONObject ?? ["type": "object"]))
        }
        if let tc = j["tool_choice"] as? JSONObject {
            switch tc["type"] as? String {
            case "any": toolChoice = .required
            case "none": toolChoice = CanonToolChoice.none
            case "tool": toolChoice = .named(tc["name"] as? String ?? "")
            default: toolChoice = .auto
            }
            if let off = tc["disable_parallel_tool_use"] as? Bool { parallelToolCalls = !off }
        }
        maxTokens = GatewayJSON.int(j["max_tokens"])
        temperature = GatewayJSON.double(j["temperature"])
        topP = GatewayJSON.double(j["top_p"])
        stop = stopSequences(j["stop_sequences"])
        stream = j["stream"] as? Bool ?? false
    }
}

// MARK: - Parse: OpenAI Chat Completions

extension CanonRequest {
    init(chat j: JSONObject) {
        model = j["model"] as? String ?? ""
        var systemParts: [String] = []
        for case let m as JSONObject in (j["messages"] as? [Any] ?? []) {
            let role = m["role"] as? String ?? "user"
            switch role {
            case "system", "developer":
                systemParts.append(flattenText(m["content"]))
            case "assistant":
                var parts: [CanonPart] = []
                let text = flattenText(m["content"])
                if !text.isEmpty { parts.append(.text(text)) }
                for case let call as JSONObject in (m["tool_calls"] as? [Any] ?? []) {
                    let fn = call["function"] as? JSONObject ?? [:]
                    parts.append(.toolCall(id: call["id"] as? String ?? GatewayID.make("call_"),
                                           name: fn["name"] as? String ?? "",
                                           arguments: fn["arguments"] as? String ?? "{}"))
                }
                messages.append(CanonMessage(role: .assistant, parts: parts))
            case "tool", "function":
                let part = CanonPart.toolResult(id: m["tool_call_id"] as? String ?? "",
                                                content: flattenText(m["content"]), isError: false)
                appendUserPart(part)
            default:
                var parts: [CanonPart] = []
                if let s = m["content"] as? String {
                    parts.append(.text(s))
                } else {
                    for case let p as JSONObject in (m["content"] as? [Any] ?? []) {
                        switch p["type"] as? String {
                        case "text":
                            parts.append(.text(p["text"] as? String ?? ""))
                        case "image_url":
                            let iu = p["image_url"]
                            let url = (iu as? JSONObject)?["url"] as? String ?? iu as? String ?? ""
                            parts.append(imagePart(fromURL: url))
                        default:
                            break
                        }
                    }
                }
                messages.append(CanonMessage(role: .user, parts: parts))
            }
        }
        let sys = systemParts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        system = sys.isEmpty ? nil : sys
        for case let t as JSONObject in (j["tools"] as? [Any] ?? []) {
            guard let fn = t["function"] as? JSONObject, let name = fn["name"] as? String else { continue }
            tools.append(CanonTool(name: name, description: fn["description"] as? String,
                                   schema: fn["parameters"] as? JSONObject ?? ["type": "object", "properties": [String: Any]()]))
        }
        toolChoice = Self.openAIToolChoice(j["tool_choice"])
        maxTokens = GatewayJSON.int(j["max_completion_tokens"]) ?? GatewayJSON.int(j["max_tokens"])
        temperature = GatewayJSON.double(j["temperature"])
        topP = GatewayJSON.double(j["top_p"])
        stop = stopSequences(j["stop"])
        stream = j["stream"] as? Bool ?? false
        reasoningEffort = j["reasoning_effort"] as? String
        parallelToolCalls = j["parallel_tool_calls"] as? Bool
    }

    /// Tool results arrive as separate messages; group consecutive ones
    /// into one user turn (Anthropic's shape).
    private mutating func appendUserPart(_ part: CanonPart) {
        if let last = messages.last, last.role == .user,
           last.parts.allSatisfy({ if case .toolResult = $0 { return true }; return false }) {
            messages[messages.count - 1].parts.append(part)
        } else {
            messages.append(CanonMessage(role: .user, parts: [part]))
        }
    }

    static func openAIToolChoice(_ v: Any?) -> CanonToolChoice? {
        if let s = v as? String {
            switch s {
            case "none": return CanonToolChoice.none
            case "required": return .required
            case "auto": return .auto
            default: return nil
            }
        }
        if let o = v as? JSONObject {
            let name = (o["function"] as? JSONObject)?["name"] as? String ?? o["name"] as? String
            if let name { return .named(name) }
        }
        return nil
    }
}

// MARK: - Parse: OpenAI Responses

extension CanonRequest {
    init(responses j: JSONObject) {
        model = j["model"] as? String ?? ""
        var systemParts: [String] = []
        if let s = j["instructions"] as? String, !s.isEmpty { systemParts.append(s) }
        if let s = j["input"] as? String {
            messages.append(CanonMessage(role: .user, parts: [.text(s)]))
        }
        for case let item as JSONObject in (j["input"] as? [Any] ?? []) {
            let type = item["type"] as? String ?? (item["role"] != nil ? "message" : "")
            switch type {
            case "message":
                let role = item["role"] as? String ?? "user"
                if role == "system" || role == "developer" {
                    systemParts.append(flattenText(item["content"]))
                    continue
                }
                var parts: [CanonPart] = []
                if let s = item["content"] as? String {
                    parts.append(.text(s))
                } else {
                    for case let p as JSONObject in (item["content"] as? [Any] ?? []) {
                        switch p["type"] as? String {
                        case "input_text", "output_text", "text":
                            parts.append(.text(p["text"] as? String ?? ""))
                        case "refusal":
                            parts.append(.text(p["refusal"] as? String ?? ""))
                        case "input_image":
                            let url = p["image_url"] as? String ?? (p["image_url"] as? JSONObject)?["url"] as? String
                            if let url { parts.append(imagePart(fromURL: url)) }
                        default:
                            break
                        }
                    }
                }
                append(role == "assistant" ? .assistant : .user, parts)
            case "function_call":
                append(.assistant, [.toolCall(id: item["call_id"] as? String ?? GatewayID.make("call_"),
                                              name: item["name"] as? String ?? "",
                                              arguments: item["arguments"] as? String ?? "{}")])
            case "custom_tool_call":
                let args = GatewayJSON.string(["input": item["input"] as? String ?? ""])
                append(.assistant, [.toolCall(id: item["call_id"] as? String ?? GatewayID.make("call_"),
                                              name: item["name"] as? String ?? "", arguments: args)])
            case "function_call_output", "custom_tool_call_output":
                append(.user, [.toolResult(id: item["call_id"] as? String ?? "",
                                           content: flattenText(item["output"]), isError: false)])
            default:
                // reasoning (encrypted, provider-bound), web search calls, etc.
                break
            }
        }
        let sys = systemParts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        system = sys.isEmpty ? nil : sys
        for case let t as JSONObject in (j["tools"] as? [Any] ?? []) {
            guard let name = t["name"] as? String else { continue }
            switch t["type"] as? String {
            case "function":
                tools.append(CanonTool(name: name, description: t["description"] as? String,
                                       schema: t["parameters"] as? JSONObject ?? ["type": "object", "properties": [String: Any]()]))
            case "custom":
                tools.append(CanonTool(name: name, description: t["description"] as? String,
                                       schema: ["type": "object",
                                                "properties": ["input": ["type": "string", "description": "The raw text input for this tool."]],
                                                "required": ["input"]],
                                       custom: true))
            default:
                break
            }
        }
        toolChoice = Self.openAIToolChoice(j["tool_choice"])
        maxTokens = GatewayJSON.int(j["max_output_tokens"])
        temperature = GatewayJSON.double(j["temperature"])
        topP = GatewayJSON.double(j["top_p"])
        stream = j["stream"] as? Bool ?? false
        reasoningEffort = (j["reasoning"] as? JSONObject)?["effort"] as? String
        parallelToolCalls = j["parallel_tool_calls"] as? Bool
    }

    /// Consecutive items with the same role form one turn.
    private mutating func append(_ role: CanonMessage.Role, _ parts: [CanonPart]) {
        if let last = messages.last, last.role == role {
            messages[messages.count - 1].parts.append(contentsOf: parts)
        } else {
            messages.append(CanonMessage(role: role, parts: parts))
        }
    }
}

// MARK: - Build: Anthropic Messages

extension CanonRequest {
    func anthropicBody(model: String) -> JSONObject {
        var turns: [(role: String, blocks: [JSONObject])] = []
        for m in messages {
            let role = m.role == .assistant ? "assistant" : "user"
            var results: [JSONObject] = []
            var blocks: [JSONObject] = []
            for p in m.parts {
                switch p {
                case .text(let t):
                    if !t.isEmpty { blocks.append(["type": "text", "text": t]) }
                case .image(let media, let b64, let url):
                    if let b64 {
                        blocks.append(["type": "image", "source": ["type": "base64", "media_type": media, "data": b64]])
                    } else if let url {
                        blocks.append(["type": "image", "source": ["type": "url", "url": url]])
                    }
                case .toolCall(let id, let name, let args):
                    let input = GatewayJSON.value(fromString: args) as? JSONObject ?? [:]
                    blocks.append(["type": "tool_use", "id": GatewayID.toolID(id), "name": name, "input": input])
                case .toolResult(let id, let content, let isError):
                    var r: JSONObject = ["type": "tool_result", "tool_use_id": GatewayID.toolID(id),
                                         "content": content.isEmpty ? "(empty)" : content]
                    if isError { r["is_error"] = true }
                    results.append(r)
                }
            }
            // Tool results must lead a user turn.
            let all = results + blocks
            guard !all.isEmpty else { continue }
            if let last = turns.last, last.role == role {
                turns[turns.count - 1].blocks.append(contentsOf: all)
            } else {
                turns.append((role, all))
            }
        }
        if turns.first?.role == "assistant" {
            turns.insert(("user", [["type": "text", "text": "(continuing the conversation)"]]), at: 0)
        }
        var body: JSONObject = [
            "model": model,
            "max_tokens": maxTokens ?? 8192,
            "messages": turns.map { ["role": $0.role, "content": $0.blocks] },
        ]
        if let system, !system.isEmpty { body["system"] = system }
        if !tools.isEmpty {
            body["tools"] = tools.map { t -> JSONObject in
                var o: JSONObject = ["name": t.name, "input_schema": t.schema]
                if let d = t.description { o["description"] = d }
                return o
            }
        }
        if let toolChoice, !tools.isEmpty {
            var tc: JSONObject
            switch toolChoice {
            case .auto: tc = ["type": "auto"]
            case .none: tc = ["type": "none"]
            case .required: tc = ["type": "any"]
            case .named(let n): tc = ["type": "tool", "name": n]
            }
            if parallelToolCalls == false, toolChoice.allowsParallelFlag { tc["disable_parallel_tool_use"] = true }
            body["tool_choice"] = tc
        }
        // Anthropic accepts 0…1; OpenAI clients may send up to 2.
        if let temperature { body["temperature"] = min(max(temperature, 0), 1) }
        if let topP, temperature == nil { body["top_p"] = topP }
        if !stop.isEmpty { body["stop_sequences"] = stop }
        if stream { body["stream"] = true }
        return body
    }
}

private extension CanonToolChoice {
    var allowsParallelFlag: Bool {
        if case .none = self { return false }
        return true
    }
}

// MARK: - Build: OpenAI Chat Completions

extension CanonRequest {
    func chatBody(model: String, provider: GatewayProvider) -> JSONObject {
        var msgs: [JSONObject] = []
        if let system, !system.isEmpty { msgs.append(["role": "system", "content": system]) }
        for m in messages {
            switch m.role {
            case .assistant:
                var text: [String] = []
                var calls: [JSONObject] = []
                for p in m.parts {
                    switch p {
                    case .text(let t): text.append(t)
                    case .toolCall(let id, let name, let args):
                        calls.append(["id": id, "type": "function", "function": ["name": name, "arguments": args]])
                    default: break
                    }
                }
                var o: JSONObject = ["role": "assistant"]
                let joined = text.joined(separator: "\n\n")
                o["content"] = joined.isEmpty && !calls.isEmpty ? NSNull() : joined
                if !calls.isEmpty { o["tool_calls"] = calls }
                msgs.append(o)
            case .user:
                var content: [JSONObject] = []
                var hasImage = false
                for p in m.parts {
                    switch p {
                    case .toolResult(let id, let c, let isError):
                        msgs.append(["role": "tool", "tool_call_id": id, "content": isError ? "Error: \(c)" : c])
                    case .text(let t):
                        content.append(["type": "text", "text": t])
                    case .image(let media, let b64, let url):
                        hasImage = true
                        let u = b64.map { dataURL(mediaType: media, base64: $0) } ?? url ?? ""
                        content.append(["type": "image_url", "image_url": ["url": u]])
                    case .toolCall:
                        break
                    }
                }
                if content.isEmpty { continue }
                if hasImage {
                    msgs.append(["role": "user", "content": content])
                } else {
                    msgs.append(["role": "user", "content": content.compactMap { $0["text"] as? String }.joined(separator: "\n\n")])
                }
            }
        }
        var body: JSONObject = ["model": model, "messages": msgs]
        if !tools.isEmpty {
            body["tools"] = tools.map { t -> JSONObject in
                var fn: JSONObject = ["name": t.name, "parameters": t.schema]
                if let d = t.description { fn["description"] = d }
                return ["type": "function", "function": fn]
            }
            if let toolChoice {
                switch toolChoice {
                case .auto: body["tool_choice"] = "auto"
                case .none: body["tool_choice"] = "none"
                case .required: body["tool_choice"] = "required"
                case .named(let n): body["tool_choice"] = ["type": "function", "function": ["name": n]]
                }
            }
            if let parallelToolCalls { body["parallel_tool_calls"] = parallelToolCalls }
        }
        if let maxTokens {
            // OpenAI's current models reject max_tokens.
            body[provider == .openai ? "max_completion_tokens" : "max_tokens"] = maxTokens
        }
        if let temperature { body["temperature"] = temperature }
        if let topP { body["top_p"] = topP }
        if !stop.isEmpty { body["stop"] = stop }
        if provider == .openai, let reasoningEffort { body["reasoning_effort"] = reasoningEffort }
        if stream {
            body["stream"] = true
            if provider == .openai || provider == .xai { body["stream_options"] = ["include_usage": true] }
        }
        return body
    }
}

// MARK: - Responses (non-streaming)

extension CanonStop {
    var anthropic: String {
        switch self {
        case .end: return "end_turn"
        case .maxTokens: return "max_tokens"
        case .toolUse: return "tool_use"
        case .stopSequence: return "stop_sequence"
        case .refusal: return "refusal"
        }
    }

    var chat: String {
        switch self {
        case .end, .stopSequence: return "stop"
        case .maxTokens: return "length"
        case .toolUse: return "tool_calls"
        case .refusal: return "content_filter"
        }
    }

    init(anthropic s: String?) {
        switch s {
        case "max_tokens", "model_context_window_exceeded": self = .maxTokens
        case "tool_use": self = .toolUse
        case "stop_sequence": self = .stopSequence
        case "refusal": self = .refusal
        default: self = .end
        }
    }

    init(chat s: String?) {
        switch s {
        case "length": self = .maxTokens
        case "tool_calls", "function_call": self = .toolUse
        case "content_filter": self = .refusal
        default: self = .end
        }
    }
}

extension CanonUsage {
    init(anthropic u: JSONObject?) {
        input = GatewayJSON.int(u?["input_tokens"]) ?? 0
        output = GatewayJSON.int(u?["output_tokens"]) ?? 0
        cacheRead = GatewayJSON.int(u?["cache_read_input_tokens"]) ?? 0
        cacheWrite = GatewayJSON.int(u?["cache_creation_input_tokens"]) ?? 0
    }

    init(chat u: JSONObject?) {
        let prompt = GatewayJSON.int(u?["prompt_tokens"]) ?? 0
        cacheRead = GatewayJSON.int((u?["prompt_tokens_details"] as? JSONObject)?["cached_tokens"]) ?? 0
        input = max(0, prompt - cacheRead)
        output = GatewayJSON.int(u?["completion_tokens"]) ?? 0
    }

    var anthropicJSON: JSONObject {
        var o: JSONObject = ["input_tokens": input, "output_tokens": output]
        if cacheRead > 0 { o["cache_read_input_tokens"] = cacheRead }
        if cacheWrite > 0 { o["cache_creation_input_tokens"] = cacheWrite }
        return o
    }

    var chatJSON: JSONObject {
        ["prompt_tokens": totalInput, "completion_tokens": output, "total_tokens": totalInput + output,
         "prompt_tokens_details": ["cached_tokens": cacheRead]]
    }

    var responsesJSON: JSONObject {
        ["input_tokens": totalInput, "output_tokens": output, "total_tokens": totalInput + output,
         "input_tokens_details": ["cached_tokens": cacheRead],
         "output_tokens_details": ["reasoning_tokens": 0]]
    }
}

extension CanonResponse {
    init(anthropic j: JSONObject) {
        id = j["id"] as? String ?? GatewayID.make("msg_")
        model = j["model"] as? String ?? ""
        parts = []
        for case let b as JSONObject in (j["content"] as? [Any] ?? []) {
            switch b["type"] as? String {
            case "text":
                parts.append(.text(b["text"] as? String ?? ""))
            case "tool_use":
                parts.append(.toolCall(id: b["id"] as? String ?? GatewayID.make("toolu_"),
                                       name: b["name"] as? String ?? "",
                                       arguments: GatewayJSON.string(b["input"] ?? [String: Any]())))
            case "thinking":
                reasoning += b["thinking"] as? String ?? ""
            default:
                break
            }
        }
        stop = CanonStop(anthropic: j["stop_reason"] as? String)
        usage = CanonUsage(anthropic: j["usage"] as? JSONObject)
    }

    init(chat j: JSONObject) {
        id = j["id"] as? String ?? GatewayID.make("chatcmpl-")
        model = j["model"] as? String ?? ""
        parts = []
        let choice = (j["choices"] as? [Any])?.first as? JSONObject ?? [:]
        let msg = choice["message"] as? JSONObject ?? [:]
        reasoning = msg["reasoning_content"] as? String ?? msg["reasoning"] as? String ?? ""
        let text = flattenText(msg["content"])
        if !text.isEmpty { parts.append(.text(text)) }
        for case let call as JSONObject in (msg["tool_calls"] as? [Any] ?? []) {
            let fn = call["function"] as? JSONObject ?? [:]
            parts.append(.toolCall(id: call["id"] as? String ?? GatewayID.make("call_"),
                                   name: fn["name"] as? String ?? "",
                                   arguments: fn["arguments"] as? String ?? "{}"))
        }
        stop = CanonStop(chat: choice["finish_reason"] as? String)
        if stop == .end, parts.contains(where: { if case .toolCall = $0 { return true }; return false }) {
            stop = .toolUse
        }
        usage = CanonUsage(chat: j["usage"] as? JSONObject)
    }

    func anthropicJSON(model: String) -> JSONObject {
        var content: [JSONObject] = []
        for p in parts {
            switch p {
            case .text(let t):
                content.append(["type": "text", "text": t])
            case .toolCall(let id, let name, let args):
                content.append(["type": "tool_use", "id": GatewayID.toolID(id), "name": name,
                                "input": GatewayJSON.value(fromString: args) as? JSONObject ?? [:]])
            default:
                break
            }
        }
        return ["id": id.hasPrefix("msg_") ? id : GatewayID.make("msg_"), "type": "message", "role": "assistant",
                "model": model, "content": content, "stop_reason": stop.anthropic,
                "stop_sequence": NSNull(), "usage": usage.anthropicJSON]
    }

    func chatJSON(model: String) -> JSONObject {
        var text: [String] = []
        var calls: [JSONObject] = []
        for p in parts {
            switch p {
            case .text(let t): text.append(t)
            case .toolCall(let id, let name, let args):
                calls.append(["id": id, "type": "function", "function": ["name": name, "arguments": args]])
            default: break
            }
        }
        var message: JSONObject = ["role": "assistant"]
        let joined = text.joined()
        message["content"] = joined.isEmpty && !calls.isEmpty ? NSNull() : joined
        if !calls.isEmpty { message["tool_calls"] = calls }
        if !reasoning.isEmpty { message["reasoning_content"] = reasoning }
        return ["id": id.hasPrefix("chatcmpl-") ? id : GatewayID.make("chatcmpl-"),
                "object": "chat.completion", "created": Int(Date().timeIntervalSince1970), "model": model,
                "choices": [["index": 0, "message": message, "finish_reason": stop.chat]],
                "usage": usage.chatJSON]
    }

    func responsesJSON(model: String, customTools: Set<String>) -> JSONObject {
        var output: [JSONObject] = []
        var text = ""
        for p in parts {
            switch p {
            case .text(let t): text += t
            case .toolCall(let id, let name, let args):
                output.append(ResponsesItems.toolItem(callID: id, name: name, arguments: args,
                                                      custom: customTools.contains(name)))
            default: break
            }
        }
        if !text.isEmpty { output.insert(ResponsesItems.message(text: text), at: 0) }
        return ResponsesItems.response(id: GatewayID.make("resp_"), model: model,
                                       status: stop == .maxTokens ? "incomplete" : "completed",
                                       output: output, usage: usage)
    }
}

/// Building blocks shared by the Responses encoders.
enum ResponsesItems {
    static func message(id: String = GatewayID.make("msg_"), text: String, status: String = "completed") -> JSONObject {
        ["id": id, "type": "message", "status": status, "role": "assistant",
         "content": [["type": "output_text", "text": text, "annotations": [Any]()]]]
    }

    static func toolItem(id: String? = nil, callID: String, name: String, arguments: String,
                         custom: Bool, status: String = "completed") -> JSONObject {
        if custom {
            let input = (GatewayJSON.value(fromString: arguments) as? JSONObject)?["input"] as? String ?? arguments
            return ["id": id ?? GatewayID.make("ctc_"), "type": "custom_tool_call", "status": status,
                    "call_id": callID, "name": name, "input": input]
        }
        return ["id": id ?? GatewayID.make("fc_"), "type": "function_call", "status": status,
                "call_id": callID, "name": name, "arguments": arguments]
    }

    static func response(id: String, model: String, status: String, output: [JSONObject],
                         usage: CanonUsage?, createdAt: Int = Int(Date().timeIntervalSince1970)) -> JSONObject {
        var r: JSONObject = ["id": id, "object": "response", "created_at": createdAt, "status": status,
                             "model": model, "output": output, "error": NSNull(),
                             "incomplete_details": status == "incomplete" ? ["reason": "max_output_tokens"] : NSNull(),
                             "parallel_tool_calls": true, "tool_choice": "auto", "tools": [Any]()]
        r["usage"] = usage.map { $0.responsesJSON } ?? NSNull()
        return r
    }
}

// MARK: - Errors in each API's shape

enum GatewayErrorBody {
    static func make(_ api: GatewayAPI, status: Int, message: String) -> JSONObject {
        switch api {
        case .anthropic:
            let type: String
            switch status {
            case 400: type = "invalid_request_error"
            case 401: type = "authentication_error"
            case 403: type = "permission_error"
            case 404: type = "not_found_error"
            case 429: type = "rate_limit_error"
            case 529: type = "overloaded_error"
            default: type = "api_error"
            }
            return ["type": "error", "error": ["type": type, "message": message]]
        case .chat, .responses:
            let type = status == 401 ? "invalid_api_key" : (status >= 500 ? "server_error" : "invalid_request_error")
            return ["error": ["message": message, "type": type, "code": NSNull(), "param": NSNull()]]
        }
    }

    /// The message inside any provider's error body.
    static func message(from data: Data) -> String {
        if let j = GatewayJSON.parse(data) {
            if let e = j["error"] as? JSONObject, let m = e["message"] as? String { return m }
            if let m = j["error"] as? String { return m }
            if let m = j["message"] as? String { return m }
            if let m = j["detail"] as? String { return m }
        }
        let text = String(decoding: data.prefix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Upstream error" : text
    }
}

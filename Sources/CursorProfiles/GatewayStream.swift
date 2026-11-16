import Foundation

// MARK: - Prism endpoint: streaming translation
//
// Upstream server-sent events are decoded into StreamEvents, then encoded
// as the client's API expects. Same-API requests never come through here
// (their bytes are piped straight through).

enum StreamEvent {
    case start(id: String, model: String, usage: CanonUsage)
    case text(String)
    case reasoning(String)
    case toolStart(index: Int, id: String, name: String)
    case toolArgs(index: Int, delta: String)
    case finish(CanonStop, CanonUsage)
    case error(String)
}

/// Splits a byte stream into SSE `data:` payloads.
struct SSELineBuffer {
    private var buffer = Data()

    mutating func feed(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var out: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<nl]
            buffer = Data(buffer[buffer.index(after: nl)...])
            if line.last == 0x0D { line = line.dropLast() }
            if let payload = Self.payload(line) { out.append(payload) }
        }
        return out
    }

    /// Whatever is left when the stream ends without a final newline.
    mutating func flush() -> [String] {
        defer { buffer = Data() }
        guard !buffer.isEmpty, let payload = Self.payload(buffer[...]) else { return [] }
        return [payload]
    }

    private static func payload(_ line: Data.SubSequence) -> String? {
        let s = String(decoding: line, as: UTF8.self)
        guard s.hasPrefix("data:") else { return nil }
        var p = s.dropFirst(5)
        if p.first == " " { p = p.dropFirst() }
        return String(p)
    }
}

protocol GatewayStreamDecoder: AnyObject {
    func decode(_ payload: String) -> [StreamEvent]
    /// Events still owed when the upstream closes (a missing finish).
    func end() -> [StreamEvent]
}

protocol GatewayStreamEncoder: AnyObject {
    func encode(_ event: StreamEvent) -> String
}

// MARK: Decode Anthropic

final class AnthropicStreamDecoder: GatewayStreamDecoder {
    private var toolIndex: [Int: Int] = [:]
    private var nextTool = 0
    private var stop: CanonStop = .end
    private var usage = CanonUsage()
    private var finished = false

    func decode(_ payload: String) -> [StreamEvent] {
        guard let j = GatewayJSON.parse(Data(payload.utf8)) else { return [] }
        switch j["type"] as? String {
        case "message_start":
            let m = j["message"] as? JSONObject ?? [:]
            usage = CanonUsage(anthropic: m["usage"] as? JSONObject)
            return [.start(id: m["id"] as? String ?? GatewayID.make("msg_"), model: m["model"] as? String ?? "", usage: usage)]
        case "content_block_start":
            let index = GatewayJSON.int(j["index"]) ?? 0
            let block = j["content_block"] as? JSONObject ?? [:]
            switch block["type"] as? String {
            case "tool_use":
                let t = nextTool
                nextTool += 1
                toolIndex[index] = t
                return [.toolStart(index: t, id: block["id"] as? String ?? GatewayID.make("toolu_"), name: block["name"] as? String ?? "")]
            case "text":
                if let t = block["text"] as? String, !t.isEmpty { return [.text(t)] }
            default:
                break
            }
            return []
        case "content_block_delta":
            let index = GatewayJSON.int(j["index"]) ?? 0
            let delta = j["delta"] as? JSONObject ?? [:]
            switch delta["type"] as? String {
            case "text_delta":
                return [.text(delta["text"] as? String ?? "")]
            case "input_json_delta":
                guard let t = toolIndex[index] else { return [] }
                return [.toolArgs(index: t, delta: delta["partial_json"] as? String ?? "")]
            case "thinking_delta":
                return [.reasoning(delta["thinking"] as? String ?? "")]
            default:
                return []
            }
        case "message_delta":
            let delta = j["delta"] as? JSONObject ?? [:]
            if let s = delta["stop_reason"] as? String { stop = CanonStop(anthropic: s) }
            if let u = j["usage"] as? JSONObject {
                if let o = GatewayJSON.int(u["output_tokens"]) { usage.output = o }
                if let i = GatewayJSON.int(u["input_tokens"]), i > 0 { usage.input = i }
            }
            return []
        case "message_stop":
            finished = true
            return [.finish(stop, usage)]
        case "error":
            finished = true
            let e = j["error"] as? JSONObject
            return [.error(e?["message"] as? String ?? "Upstream stream error")]
        default:
            return []
        }
    }

    func end() -> [StreamEvent] {
        finished ? [] : [.finish(stop, usage)]
    }
}

// MARK: Decode Chat Completions

final class ChatStreamDecoder: GatewayStreamDecoder {
    private var started = false
    private var tools: [Int: Int] = [:]
    private var nextTool = 0
    private var stop: CanonStop?
    private var usage = CanonUsage()
    private var finished = false

    func decode(_ payload: String) -> [StreamEvent] {
        if payload.trimmingCharacters(in: .whitespaces) == "[DONE]" { return end() }
        guard let j = GatewayJSON.parse(Data(payload.utf8)) else { return [] }
        if let e = j["error"] as? JSONObject {
            finished = true
            return [.error(e["message"] as? String ?? "Upstream stream error")]
        }
        var out: [StreamEvent] = []
        if !started {
            started = true
            out.append(.start(id: j["id"] as? String ?? GatewayID.make("chatcmpl-"), model: j["model"] as? String ?? "", usage: CanonUsage()))
        }
        if let u = j["usage"] as? JSONObject { usage = CanonUsage(chat: u) }
        guard let choice = (j["choices"] as? [Any])?.first as? JSONObject else { return out }
        let delta = choice["delta"] as? JSONObject ?? [:]
        if let r = delta["reasoning_content"] as? String ?? delta["reasoning"] as? String, !r.isEmpty {
            out.append(.reasoning(r))
        }
        if let t = delta["content"] as? String, !t.isEmpty {
            out.append(.text(t))
        }
        for case let call as JSONObject in (delta["tool_calls"] as? [Any] ?? []) {
            let raw = GatewayJSON.int(call["index"]) ?? 0
            let fn = call["function"] as? JSONObject ?? [:]
            if tools[raw] == nil {
                let t = nextTool
                nextTool += 1
                tools[raw] = t
                out.append(.toolStart(index: t, id: call["id"] as? String ?? GatewayID.make("call_"), name: fn["name"] as? String ?? ""))
            }
            if let args = fn["arguments"] as? String, !args.isEmpty, let t = tools[raw] {
                out.append(.toolArgs(index: t, delta: args))
            }
        }
        if let f = choice["finish_reason"] as? String {
            stop = CanonStop(chat: f)
        }
        return out
    }

    func end() -> [StreamEvent] {
        guard !finished else { return [] }
        finished = true
        var s = stop ?? .end
        if s == .end, nextTool > 0 { s = .toolUse }
        return [.finish(s, usage)]
    }
}

// MARK: Encode Anthropic

final class AnthropicStreamEncoder: GatewayStreamEncoder {
    private let model: String
    private var started = false
    private var blockIndex = -1
    private enum Open { case none, text, tool(Int) }
    private var open: Open = .none
    private var sawTool = false

    init(model: String) { self.model = model }

    private func event(_ name: String, _ data: JSONObject) -> String {
        "event: \(name)\ndata: \(GatewayJSON.string(data))\n\n"
    }

    private func ensureStarted(id: String? = nil, usage: CanonUsage = CanonUsage()) -> String {
        guard !started else { return "" }
        started = true
        let message: JSONObject = ["id": GatewayID.make("msg_"), "type": "message", "role": "assistant", "model": model,
                                   "content": [Any](), "stop_reason": NSNull(), "stop_sequence": NSNull(),
                                   "usage": ["input_tokens": usage.input, "output_tokens": 0,
                                             "cache_read_input_tokens": usage.cacheRead]]
        return event("message_start", ["type": "message_start", "message": message])
    }

    private func closeBlock() -> String {
        if case .none = open { return "" }
        open = .none
        return event("content_block_stop", ["type": "content_block_stop", "index": blockIndex])
    }

    func encode(_ e: StreamEvent) -> String {
        switch e {
        case .start(let id, _, let usage):
            return ensureStarted(id: id, usage: usage)
        case .text(let t):
            guard !t.isEmpty else { return "" }
            var out = ensureStarted()
            if case .text = open {} else {
                out += closeBlock()
                blockIndex += 1
                open = .text
                out += event("content_block_start", ["type": "content_block_start", "index": blockIndex,
                                                     "content_block": ["type": "text", "text": ""]])
            }
            return out + event("content_block_delta", ["type": "content_block_delta", "index": blockIndex,
                                                       "delta": ["type": "text_delta", "text": t]])
        case .reasoning:
            // Thinking from another provider has no signature Anthropic
            // clients could send back; leave it out.
            return ensureStarted()
        case .toolStart(let i, let id, let name):
            var out = ensureStarted() + closeBlock()
            blockIndex += 1
            open = .tool(i)
            sawTool = true
            out += event("content_block_start", ["type": "content_block_start", "index": blockIndex,
                                                 "content_block": ["type": "tool_use", "id": GatewayID.toolID(id),
                                                                   "name": name, "input": [String: Any]()]])
            return out
        case .toolArgs(let i, let d):
            guard case .tool(let current) = open, current == i, !d.isEmpty else { return "" }
            return event("content_block_delta", ["type": "content_block_delta", "index": blockIndex,
                                                  "delta": ["type": "input_json_delta", "partial_json": d]])
        case .finish(let stop, let usage):
            var out = ensureStarted() + closeBlock()
            let s = (stop == .end && sawTool) ? CanonStop.toolUse : stop
            out += event("message_delta", ["type": "message_delta",
                                           "delta": ["stop_reason": s.anthropic, "stop_sequence": NSNull()],
                                           "usage": ["output_tokens": usage.output, "input_tokens": usage.input,
                                                     "cache_read_input_tokens": usage.cacheRead]])
            out += event("message_stop", ["type": "message_stop"])
            return out
        case .error(let m):
            return ensureStarted() + event("error", ["type": "error", "error": ["type": "api_error", "message": m]])
        }
    }
}

// MARK: Encode Chat Completions

final class ChatStreamEncoder: GatewayStreamEncoder {
    private let model: String
    private let id = GatewayID.make("chatcmpl-")
    private let created = Int(Date().timeIntervalSince1970)
    private let includeUsage: Bool
    private var started = false
    private var sawTool = false

    init(model: String, includeUsage: Bool) {
        self.model = model
        self.includeUsage = includeUsage
    }

    private func chunk(_ delta: JSONObject, finish: String? = nil) -> String {
        let choice: JSONObject = ["index": 0, "delta": delta, "finish_reason": finish ?? NSNull()]
        return "data: " + GatewayJSON.string(["id": id, "object": "chat.completion.chunk", "created": created,
                                              "model": model, "choices": [choice]]) + "\n\n"
    }

    private func ensureStarted() -> String {
        guard !started else { return "" }
        started = true
        return chunk(["role": "assistant", "content": ""])
    }

    func encode(_ e: StreamEvent) -> String {
        switch e {
        case .start:
            return ensureStarted()
        case .text(let t):
            return t.isEmpty ? "" : ensureStarted() + chunk(["content": t])
        case .reasoning(let r):
            return r.isEmpty ? "" : ensureStarted() + chunk(["reasoning_content": r])
        case .toolStart(let i, let id, let name):
            sawTool = true
            return ensureStarted() + chunk(["tool_calls": [["index": i, "id": id, "type": "function",
                                                            "function": ["name": name, "arguments": ""]]]])
        case .toolArgs(let i, let d):
            return d.isEmpty ? "" : chunk(["tool_calls": [["index": i, "function": ["arguments": d]]]])
        case .finish(let stop, let usage):
            let s = (stop == .end && sawTool) ? CanonStop.toolUse : stop
            var out = ensureStarted() + chunk([:], finish: s.chat)
            if includeUsage {
                out += "data: " + GatewayJSON.string(["id": id, "object": "chat.completion.chunk", "created": created,
                                                      "model": model, "choices": [Any](), "usage": usage.chatJSON]) + "\n\n"
            }
            return out + "data: [DONE]\n\n"
        case .error(let m):
            return "data: " + GatewayJSON.string(["error": ["message": m, "type": "server_error"]]) + "\n\ndata: [DONE]\n\n"
        }
    }
}

// MARK: Encode Responses

final class ResponsesStreamEncoder: GatewayStreamEncoder {
    private let model: String
    private let customTools: Set<String>
    private let responseID = GatewayID.make("resp_")
    private let createdAt = Int(Date().timeIntervalSince1970)
    private var seq = 0
    private var started = false
    private var output: [JSONObject] = []

    private enum Open {
        case none
        case message(id: String, text: String)
        case tool(index: Int, id: String, callID: String, name: String, args: String)
    }
    private var open: Open = .none

    init(model: String, customTools: Set<String>) {
        self.model = model
        self.customTools = customTools
    }

    private func event(_ type: String, _ fields: JSONObject) -> String {
        var data = fields
        data["type"] = type
        data["sequence_number"] = seq
        seq += 1
        return "event: \(type)\ndata: \(GatewayJSON.string(data))\n\n"
    }

    private func snapshot(status: String, usage: CanonUsage?) -> JSONObject {
        ResponsesItems.response(id: responseID, model: model, status: status, output: output, usage: usage, createdAt: createdAt)
    }

    private func ensureStarted() -> String {
        guard !started else { return "" }
        started = true
        let r = snapshot(status: "in_progress", usage: nil)
        return event("response.created", ["response": r]) + event("response.in_progress", ["response": r])
    }

    private func closeItem() -> String {
        let index = output.count
        switch open {
        case .none:
            return ""
        case .message(let id, let text):
            open = .none
            let part: JSONObject = ["type": "output_text", "text": text, "annotations": [Any]()]
            let item = ResponsesItems.message(id: id, text: text)
            output.append(item)
            return event("response.output_text.done", ["item_id": id, "output_index": index, "content_index": 0, "text": text])
                + event("response.content_part.done", ["item_id": id, "output_index": index, "content_index": 0, "part": part])
                + event("response.output_item.done", ["output_index": index, "item": item])
        case .tool(_, let id, let callID, let name, let args):
            open = .none
            let custom = customTools.contains(name)
            let item = ResponsesItems.toolItem(id: id, callID: callID, name: name, arguments: args, custom: custom)
            output.append(item)
            var out = ""
            if custom {
                out += event("response.custom_tool_call_input.done", ["item_id": id, "output_index": index,
                                                                      "input": item["input"] as? String ?? ""])
            } else {
                out += event("response.function_call_arguments.done", ["item_id": id, "output_index": index, "arguments": args])
            }
            return out + event("response.output_item.done", ["output_index": index, "item": item])
        }
    }

    func encode(_ e: StreamEvent) -> String {
        switch e {
        case .start:
            return ensureStarted()
        case .text(let t):
            guard !t.isEmpty else { return "" }
            var out = ensureStarted()
            let index: Int
            let itemID: String
            if case .message(let id, let text) = open {
                open = .message(id: id, text: text + t)
                index = output.count
                itemID = id
            } else {
                out += closeItem()
                itemID = GatewayID.make("msg_")
                index = output.count
                open = .message(id: itemID, text: t)
                out += event("response.output_item.added", ["output_index": index, "item":
                    ["id": itemID, "type": "message", "status": "in_progress", "role": "assistant", "content": [Any]()]])
                out += event("response.content_part.added", ["item_id": itemID, "output_index": index, "content_index": 0,
                                                             "part": ["type": "output_text", "text": "", "annotations": [Any]()]])
            }
            return out + event("response.output_text.delta", ["item_id": itemID, "output_index": index,
                                                              "content_index": 0, "delta": t])
        case .reasoning:
            return ensureStarted()
        case .toolStart(let i, let callID, let name):
            var out = ensureStarted() + closeItem()
            let custom = customTools.contains(name)
            let id = GatewayID.make(custom ? "ctc_" : "fc_")
            open = .tool(index: i, id: id, callID: callID, name: name, args: "")
            var item: JSONObject = ["id": id, "type": custom ? "custom_tool_call" : "function_call",
                                    "status": "in_progress", "call_id": callID, "name": name]
            item[custom ? "input" : "arguments"] = ""
            out += event("response.output_item.added", ["output_index": output.count, "item": item])
            return out
        case .toolArgs(let i, let d):
            guard case .tool(let current, let id, let callID, let name, let args) = open, current == i else { return "" }
            open = .tool(index: i, id: id, callID: callID, name: name, args: args + d)
            // A custom tool's input is the "input" field of the JSON being
            // streamed; it is only known once complete (sent at .done).
            if customTools.contains(name) { return "" }
            return event("response.function_call_arguments.delta", ["item_id": id, "output_index": output.count, "delta": d])
        case .finish(let stop, let usage):
            var out = ensureStarted() + closeItem()
            let status = stop == .maxTokens ? "incomplete" : "completed"
            out += event(status == "completed" ? "response.completed" : "response.incomplete",
                         ["response": snapshot(status: status, usage: usage)])
            return out
        case .error(let m):
            var r = snapshot(status: "failed", usage: nil)
            r["error"] = ["code": "server_error", "message": m]
            return ensureStarted() + event("error", ["code": "server_error", "message": m, "param": NSNull()])
                + event("response.failed", ["response": r])
        }
    }
}

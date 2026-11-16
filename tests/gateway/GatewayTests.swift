import Foundation

// Prism endpoint tests: unit checks for routing and translation, then
// end-to-end requests through a real GatewayServer to a mock provider.
// Run with tests/gateway/run.sh (macOS).

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passes = 0

func check(_ cond: @autoclosure () -> Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if cond() {
        passes += 1
        print("  ✓ \(name)")
    } else {
        failures += 1
        print("  ✗ \(name) \(detail())")
    }
}

// MARK: - Mock provider

final class MockLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _last: [String: JSONObject] = [:]
    private var _headers: [String: [String: String]] = [:]
    func record(_ path: String, _ body: JSONObject, _ headers: [String: String]) {
        lock.lock(); _last[path] = body; _headers[path] = headers; lock.unlock()
    }
    func last(_ path: String) -> JSONObject? { lock.lock(); defer { lock.unlock() }; return _last[path] }
    func headers(_ path: String) -> [String: String]? { lock.lock(); defer { lock.unlock() }; return _headers[path] }
}

let mockLog = MockLog()

func lastUserText(_ body: JSONObject, api: GatewayAPI) -> String {
    GatewayUserText.texts(in: body, api: api).last ?? ""
}

@Sendable func mockHandler(_ req: GatewayHTTPRequest, _ w: GatewayResponseWriter) async {
    let body = GatewayJSON.parse(req.body) ?? [:]
    mockLog.record(req.path, body, req.headers)
    let stream = body["stream"] as? Bool ?? false
    let hasTools = !((body["tools"] as? [Any]) ?? []).isEmpty

    if req.path.hasSuffix("/models") {
        if req.path.hasPrefix("/anthropic") {
            await w.sendJSON(status: 200, ["data": [["id": "claude-test-sonnet", "type": "model"]]])
        } else {
            await w.sendJSON(status: 200, ["data": [["id": "gpt-test"], ["id": "text-embedding-3-small"]]])
        }
        return
    }

    if req.path == "/anthropic/v1/messages" {
        let key = req.headers["x-api-key"] ?? ""
        guard key.hasPrefix("ak-") else {
            await w.sendJSON(status: 401, ["type": "error", "error": ["type": "authentication_error", "message": "bad key"]])
            return
        }
        // Thinking blocks signed by another account are rejected.
        let hasThinking = (body["messages"] as? [Any] ?? []).contains { m in
            ((m as? JSONObject)?["content"] as? [Any] ?? []).contains { (($0 as? JSONObject)?["type"] as? String) == "thinking" }
        }
        if hasThinking {
            await w.sendJSON(status: 400, ["type": "error", "error": ["type": "invalid_request_error",
                                                                     "message": "Invalid `signature` in `thinking` block"]])
            return
        }
        let text = "key=\(key) said=\(lastUserText(body, api: .anthropic))"
        if stream {
            await w.startStream(status: 200, headers: [("Content-Type", "text/event-stream")])
            func ev(_ name: String, _ d: JSONObject) -> String { "event: \(name)\ndata: \(GatewayJSON.string(d))\n\n" }
            var s = ev("message_start", ["type": "message_start", "message": ["id": "msg_1", "type": "message", "role": "assistant",
                                                                             "model": body["model"] ?? "", "content": [Any](),
                                                                             "usage": ["input_tokens": 11, "output_tokens": 0]]])
            s += ev("content_block_start", ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]])
            s += ev("content_block_delta", ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": text]])
            s += ev("content_block_stop", ["type": "content_block_stop", "index": 0])
            if hasTools {
                s += ev("content_block_start", ["type": "content_block_start", "index": 1,
                                                "content_block": ["type": "tool_use", "id": "toolu_1", "name": "get_weather", "input": [String: Any]()]])
                s += ev("content_block_delta", ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": "{\"city\":"]])
                s += ev("content_block_delta", ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": "\"Sydney\"}"]])
                s += ev("content_block_stop", ["type": "content_block_stop", "index": 1])
            }
            s += ev("message_delta", ["type": "message_delta", "delta": ["stop_reason": hasTools ? "tool_use" : "end_turn"],
                                      "usage": ["output_tokens": 7]])
            s += ev("message_stop", ["type": "message_stop"])
            // Send in odd-sized pieces to exercise line buffering.
            let data = Data(s.utf8)
            var i = 0
            while i < data.count {
                let end = min(i + 37, data.count)
                _ = await w.write(data.subdata(in: i..<end))
                i = end
            }
            await w.finish()
        } else {
            var content: [JSONObject] = [["type": "text", "text": text]]
            if hasTools { content.append(["type": "tool_use", "id": "toolu_1", "name": "get_weather", "input": ["city": "Sydney"]]) }
            await w.sendJSON(status: 200, ["id": "msg_1", "type": "message", "role": "assistant", "model": body["model"] ?? "",
                                           "content": content, "stop_reason": hasTools ? "tool_use" : "end_turn",
                                           "usage": ["input_tokens": 11, "output_tokens": 7]])
        }
        return
    }

    if req.path == "/openai/v1/chat/completions" {
        let key = (req.headers["authorization"] ?? "").replacingOccurrences(of: "Bearer ", with: "")
        let text = "key=\(key) said=\(lastUserText(body, api: .chat))"
        if stream {
            await w.startStream(status: 200, headers: [("Content-Type", "text/event-stream")])
            func chunk(_ delta: JSONObject, _ finish: String? = nil) -> String {
                "data: " + GatewayJSON.string(["id": "c1", "model": body["model"] ?? "", "choices": [["index": 0, "delta": delta, "finish_reason": finish.map { $0 as Any } ?? NSNull()]]] as JSONObject) + "\n\n"
            }
            var s = chunk(["role": "assistant", "content": ""]) + chunk(["content": text])
            if hasTools {
                s += chunk(["tool_calls": [["index": 0, "id": "call_1", "type": "function", "function": ["name": "get_weather", "arguments": ""]]]])
                s += chunk(["tool_calls": [["index": 0, "function": ["arguments": "{\"city\":\"Sydney\"}"]]]])
            }
            s += chunk([:], hasTools ? "tool_calls" : "stop")
            s += "data: " + GatewayJSON.string(["id": "c1", "choices": [Any](), "usage": ["prompt_tokens": 20, "completion_tokens": 5]]) + "\n\n"
            s += "data: [DONE]\n\n"
            _ = await w.write(s)
            await w.finish()
        } else {
            var msg: JSONObject = ["role": "assistant", "content": text]
            if hasTools {
                msg["tool_calls"] = [["id": "call_1", "type": "function", "function": ["name": "get_weather", "arguments": "{\"city\":\"Sydney\"}"]]]
            }
            await w.sendJSON(status: 200, ["id": "c1", "object": "chat.completion", "model": body["model"] ?? "",
                                           "choices": [["index": 0, "message": msg, "finish_reason": hasTools ? "tool_calls" : "stop"]],
                                           "usage": ["prompt_tokens": 20, "completion_tokens": 5]])
        }
        return
    }

    if req.path == "/openai/v1/responses" {
        let key = (req.headers["authorization"] ?? "").replacingOccurrences(of: "Bearer ", with: "")
        let hasReasoning = (body["input"] as? [Any] ?? []).contains { (($0 as? JSONObject)?["type"] as? String) == "reasoning" }
        if hasReasoning && key == "ok-personal" {
            await w.sendJSON(status: 400, ["error": ["message": "The encrypted content could not be verified.", "type": "invalid_request_error"]])
            return
        }
        await w.startStream(status: 200, headers: [("Content-Type", "text/event-stream")])
        _ = await w.write("event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_up\",\"status\":\"completed\",\"output\":[],\"note\":\"key=\(key)\"}}\n\n")
        await w.finish()
        return
    }

    await w.sendJSON(status: 404, ["error": ["message": "mock: no route \(req.path)"]])
}

// MARK: - HTTP client helpers

struct Reply {
    let status: Int
    let headers: [String: String]
    let body: String
    var json: JSONObject? { GatewayJSON.parse(Data(body.utf8)) }
}

func call(_ port: Int, _ method: String, _ path: String, _ body: Any? = nil, token: String? = nil,
          anthropicStyle: Bool = false, userAgent: String = "test-client/1.0") async -> Reply {
    var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    r.httpMethod = method
    r.timeoutInterval = 20
    if let body { r.httpBody = GatewayJSON.data(body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    if let token {
        if anthropicStyle {
            r.setValue(token, forHTTPHeaderField: "x-api-key")
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }
    r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    do {
        let (data, resp) = try await URLSession.shared.data(for: r)
        let http = resp as! HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headers["\(k)".lowercased()] = "\(v)" }
        return Reply(status: http.statusCode, headers: headers, body: String(decoding: data, as: UTF8.self))
    } catch {
        return Reply(status: -1, headers: [:], body: "\(error)")
    }
}

/// `data:` payloads of an SSE body.
func ssePayloads(_ body: String) -> [JSONObject] {
    var buf = SSELineBuffer()
    return buf.feed(Data((body + "\n").utf8)).compactMap { GatewayJSON.parse(Data($0.utf8)) }
}

func startServer(_ handler: @escaping GatewayServer.Handler) async -> (GatewayServer, Int) {
    for _ in 0..<20 {
        let port = Int.random(in: 20000...40000)
        let server = GatewayServer(handler: handler)
        let ready = AsyncStream<Bool> { cont in
            do {
                try server.start(port: port, allowLAN: false) { state in
                    switch state {
                    case .ready: cont.yield(true); cont.finish()
                    case .failed, .cancelled: cont.yield(false); cont.finish()
                    default: break
                    }
                }
            } catch {
                cont.yield(false); cont.finish()
            }
        }
        for await ok in ready {
            if ok { return (server, port) }
            break
        }
    }
    fatalError("no free port")
}

// MARK: - Tests

@main
struct GatewayTests {
    static func main() async {
        unitTests()
        await endToEnd()
        print("\n\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func sampleConfig(mockPort: Int) -> GatewayConfig {
        var work = GatewayIdentity(name: "Work", colorHex: "#3B82F6",
                                   credentials: [GatewayCredential(provider: .anthropic, baseURL: "http://127.0.0.1:\(mockPort)/anthropic"),
                                                 GatewayCredential(provider: .openai, baseURL: "http://127.0.0.1:\(mockPort)/openai/v1")],
                                   defaultModel: "claude-test-sonnet")
        work.id = "work-id"
        work.credentials[0].id = "work-anthropic"
        work.credentials[1].id = "work-openai"
        var personal = GatewayIdentity(name: "Personal", colorHex: "#F43F5E",
                                       credentials: [GatewayCredential(provider: .anthropic, baseURL: "http://127.0.0.1:\(mockPort)/anthropic"),
                                                     GatewayCredential(provider: .openai, baseURL: "http://127.0.0.1:\(mockPort)/openai/v1")],
                                       defaultModel: "gpt-test")
        personal.id = "personal-id"
        personal.credentials[0].id = "personal-anthropic"
        personal.credentials[1].id = "personal-openai"
        var cfg = GatewayConfig()
        cfg.enabled = true
        cfg.token = "prism-test-token"
        cfg.identities = [work, personal]
        cfg.activeIdentityID = "personal-id"
        cfg.rules = [GatewayRule(kind: .keyword, pattern: "invoice, standup", identityID: "work-id"),
                     GatewayRule(kind: .client, pattern: "codex", identityID: "work-id")]
        return cfg
    }

    // MARK: Unit

    static func unitTests() {
        print("Routing")
        let cfg = sampleConfig(mockPort: 1)
        let none: (GatewayCredential) -> [String] = { _ in [] }
        func route(_ model: String, _ texts: [String], client: String = "") -> GatewayRoute? {
            try? GatewayRouter.route(config: cfg, requestedModel: model, userTexts: texts, client: client, knownModels: none)
        }
        check(route("work/claude-x", ["hi"])?.identity.name == "Work", "model prefix picks identity")
        check(route("work/claude-x", ["hi"])?.model == "claude-x", "prefix is removed from model")
        check(route("work", ["hi"])?.model == "claude-test-sonnet", "bare identity uses its default model")
        check(route("claude-x", ["hi"])?.identity.name == "Personal", "plain model follows active identity")
        check(route("claude-x", ["@work hi"])?.identity.name == "Work", "@tag switches")
        check(route("claude-x", ["@work first", "then this"])?.identity.name == "Work", "earlier @tag sticks")
        check(route("claude-x", ["@work first", "@personal now"])?.identity.name == "Personal", "latest @tag wins")
        check(route("claude-x", ["mail me at bob@work.com"])?.identity.name == "Personal", "emails are not tags")
        check(route("claude-x", ["draft the invoice please"])?.identity.name == "Work", "keyword rule")
        check(route("claude-x", ["invoices"])?.identity.name == "Personal", "keyword matches whole words")
        check(route("gpt-5", ["hi"], client: "codex_cli_rs/0.9")?.identity.name == "Work", "client rule")
        check(route("claude-x", ["hi"])?.credential.provider == .anthropic, "claude → Anthropic key")
        check(route("gpt-5", ["hi"])?.credential.provider == .openai, "gpt → OpenAI key")
        check(route("prism", ["hi"])?.model == "gpt-test", "prism → active default model")
        check(GatewayRouter.stripTags(["work"], from: "@work  draft this") == "draft this", "tag stripped")
        check(GatewayRouter.stripTags(["work"], from: "email bob@work.com") == "email bob@work.com", "email untouched")

        var schedule = GatewayRule(kind: .schedule, identityID: "work-id")
        schedule.days = [1, 2, 3, 4, 5, 6, 7]
        schedule.startMinute = 22 * 60
        schedule.endMinute = 6 * 60
        var comps = DateComponents()
        comps.year = 2026; comps.month = 11; comps.day = 16; comps.hour = 23; comps.minute = 30
        let late = Calendar.current.date(from: comps)!
        comps.hour = 12
        let noon = Calendar.current.date(from: comps)!
        check(GatewayRouter.matches(schedule, latest: "", client: "", now: late), "overnight schedule matches 23:30")
        check(!GatewayRouter.matches(schedule, latest: "", client: "", now: noon), "overnight schedule skips noon")

        print("Translation")
        let chat: JSONObject = [
            "model": "x", "stream": true, "max_tokens": 100, "temperature": 1.5,
            "messages": [
                ["role": "system", "content": "be brief"],
                ["role": "user", "content": [["type": "text", "text": "look"],
                                             ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,AAAA"]]]],
                ["role": "assistant", "content": NSNull(), "tool_calls": [["id": "call.1", "type": "function",
                                                                           "function": ["name": "f", "arguments": "{\"a\":1}"]]]],
                ["role": "tool", "tool_call_id": "call.1", "content": "42"],
                ["role": "user", "content": "thanks"],
            ],
            "tools": [["type": "function", "function": ["name": "f", "parameters": ["type": "object"]]]],
            "tool_choice": "required",
        ]
        let a = CanonRequest(chat: chat).anthropicBody(model: "claude-x")
        let msgs = a["messages"] as? [JSONObject] ?? []
        check(a["system"] as? String == "be brief", "chat → anthropic: system")
        check(msgs.count == 3, "chat → anthropic: tool result merged into next user turn", "\(msgs.count)")
        let toolUse = (msgs[safe: 1]?["content"] as? [JSONObject])?.first
        check(toolUse?["type"] as? String == "tool_use" && toolUse?["id"] as? String == "call_1", "chat → anthropic: tool_use with safe id")
        let lastBlocks = msgs.last?["content"] as? [JSONObject] ?? []
        check(lastBlocks.first?["type"] as? String == "tool_result" && lastBlocks.last?["text"] as? String == "thanks",
              "chat → anthropic: tool_result leads the user turn")
        check(((msgs.first?["content"] as? [JSONObject])?.last?["source"] as? JSONObject)?["media_type"] as? String == "image/jpeg",
              "chat → anthropic: data-URL image")
        check(a["temperature"] as? Double == 1, "chat → anthropic: temperature clamped")
        check((a["tool_choice"] as? JSONObject)?["type"] as? String == "any", "chat → anthropic: required → any")

        let anth: JSONObject = [
            "model": "x", "max_tokens": 50, "system": [["type": "text", "text": "sys"]],
            "messages": [
                ["role": "user", "content": "hi"],
                ["role": "assistant", "content": [["type": "thinking", "thinking": "hmm", "signature": "s"],
                                                  ["type": "text", "text": "calling"],
                                                  ["type": "tool_use", "id": "toolu_9", "name": "f", "input": ["a": 1]]]],
                ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_9", "content": [["type": "text", "text": "ok"]]]]],
            ],
            "tools": [["name": "f", "input_schema": ["type": "object"]], ["type": "web_search_20250305", "name": "web_search"]],
        ]
        let c = CanonRequest(anthropic: anth).chatBody(model: "gpt-x", provider: .openai)
        let cm = c["messages"] as? [JSONObject] ?? []
        check(cm.map { $0["role"] as? String ?? "" } == ["system", "user", "assistant", "tool"], "anthropic → chat: roles",
              "\(cm.map { $0["role"] as? String ?? "" })")
        check((cm[safe: 2]?["tool_calls"] as? [JSONObject])?.first?["id"] as? String == "toolu_9", "anthropic → chat: tool call kept")
        check(cm[safe: 3]?["content"] as? String == "ok", "anthropic → chat: tool result text")
        check((c["tools"] as? [Any])?.count == 1, "anthropic → chat: server tools dropped")
        check(c["max_completion_tokens"] as? Int == 50 && c["max_tokens"] == nil, "anthropic → chat: OpenAI uses max_completion_tokens")

        let resp: JSONObject = [
            "model": "x", "instructions": "inst", "stream": true, "store": false,
            "input": [
                ["type": "message", "role": "developer", "content": "dev note"],
                ["type": "message", "role": "user", "content": [["type": "input_text", "text": "run ls"]]],
                ["type": "reasoning", "id": "rs_1", "encrypted_content": "zzz"],
                ["type": "function_call", "call_id": "call_a", "name": "shell", "arguments": "{\"cmd\":\"ls\"}"],
                ["type": "function_call_output", "call_id": "call_a", "output": "file.txt"],
                ["type": "custom_tool_call", "call_id": "call_b", "name": "apply_patch", "input": "*** Begin Patch"],
                ["type": "custom_tool_call_output", "call_id": "call_b", "output": "done"],
            ],
            "tools": [["type": "function", "name": "shell", "parameters": ["type": "object"]],
                      ["type": "custom", "name": "apply_patch", "description": "patch"],
                      ["type": "web_search"]],
        ]
        let rc = CanonRequest(responses: resp)
        check(rc.system == "inst\n\ndev note", "responses → canon: instructions + developer")
        check(rc.customToolNames == ["apply_patch"], "responses → canon: custom tool")
        let rb = rc.anthropicBody(model: "claude-x")
        let rm = rb["messages"] as? [JSONObject] ?? []
        check(rm.map { $0["role"] as? String ?? "" } == ["user", "assistant", "user", "assistant", "user"], "responses → anthropic: turns",
              "\(rm.map { $0["role"] as? String ?? "" })")
        let patchCall = (rm[safe: 3]?["content"] as? [JSONObject])?.first?["input"] as? JSONObject
        check(patchCall?["input"] as? String == "*** Begin Patch", "responses → anthropic: custom tool input wrapped")

        // Stream: anthropic upstream → responses client with a custom tool.
        let dec = AnthropicStreamDecoder()
        let enc = ResponsesStreamEncoder(model: "m", customTools: ["apply_patch"])
        var out = ""
        let events: [JSONObject] = [
            ["type": "message_start", "message": ["id": "m1", "model": "m", "usage": ["input_tokens": 3]]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Patching"]],
            ["type": "content_block_stop", "index": 0],
            ["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "t1", "name": "apply_patch", "input": [String: Any]()]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": "{\"input\":\"*** Begin"]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": " Patch\"}"]],
            ["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 4]],
            ["type": "message_stop"],
        ]
        for e in events { for ev in dec.decode(GatewayJSON.string(e)) { out += enc.encode(ev) } }
        let payloads = ssePayloads(out)
        let types = payloads.compactMap { $0["type"] as? String }
        check(types.first == "response.created" && types.last == "response.completed", "anthropic → responses stream: lifecycle", "\(types)")
        let done = payloads.last?["response"] as? JSONObject
        let outItems = done?["output"] as? [JSONObject] ?? []
        check(outItems.count == 2 && outItems[1]["type"] as? String == "custom_tool_call" && outItems[1]["input"] as? String == "*** Begin Patch",
              "anthropic → responses stream: custom_tool_call input", "\(outItems)")
        let seqs = payloads.compactMap { $0["sequence_number"] as? Int }
        check(seqs == Array(0..<seqs.count), "responses stream: sequence numbers")
    }

    // MARK: End to end

    static func endToEnd() async {
        print("End to end")
        let (mock, mockPort) = await startServer(mockHandler)
        let engine = GatewayEngine()
        engine.useKeychain = false
        engine.update(sampleConfig(mockPort: mockPort))
        engine.setKey("ak-work", for: "work-anthropic")
        engine.setKey("ok-work", for: "work-openai")
        engine.setKey("ak-personal", for: "personal-anthropic")
        engine.setKey("ok-personal", for: "personal-openai")
        let (gateway, port) = await startServer { req, w in await engine.handle(req, w) }
        let token = "prism-test-token"
        _ = mock; _ = gateway

        var r = await call(port, "POST", "/v1/chat/completions", ["model": "gpt-test", "messages": [["role": "user", "content": "hi"]]])
        check(r.status == 401, "no token → 401", "\(r.status)")

        r = await call(port, "GET", "/v1/models", token: token)
        let ids = (r.json?["data"] as? [JSONObject] ?? []).compactMap { $0["id"] as? String }
        check(ids.contains("work/claude-test-sonnet") && ids.contains("personal/gpt-test") && ids.contains("claude-test-sonnet"),
              "models: prefixed and plain ids", "\(ids)")
        check(!ids.contains("text-embedding-3-small") && !ids.contains { $0.hasSuffix("text-embedding-3-small") }, "models: OpenAI embeddings filtered")

        // Chat client → Anthropic, non-stream, explicit identity.
        r = await call(port, "POST", "/v1/chat/completions",
                       ["model": "work/claude-test-sonnet", "messages": [["role": "user", "content": "hello"]]], token: token)
        let content = ((r.json?["choices"] as? [JSONObject])?.first?["message"] as? JSONObject)?["content"] as? String
        check(r.status == 200 && content == "key=ak-work said=hello", "chat → anthropic (work)", "\(r.status) \(r.body.prefix(300))")
        check(r.headers["x-prism-identity"] == "Work", "X-Prism-Identity header")
        check(mockLog.last("/anthropic/v1/messages")?["model"] as? String == "claude-test-sonnet", "upstream got the real model id")

        // Chat client, streamed, @tag switch + tag stripped.
        r = await call(port, "POST", "/v1/chat/completions",
                       ["model": "claude-test-sonnet", "stream": true,
                        "messages": [["role": "user", "content": "@work go"]]], token: token)
        let deltas = ssePayloads(r.body).compactMap { ((($0["choices"] as? [JSONObject])?.first?["delta"]) as? JSONObject)?["content"] as? String }.joined()
        check(deltas == "key=ak-work said=go", "chat stream ← anthropic with @work stripped", "\(deltas) \(r.body.prefix(400))")
        check(r.body.hasSuffix("data: [DONE]\n\n"), "chat stream ends with [DONE]")

        // Same chat, now @personal.
        r = await call(port, "POST", "/v1/chat/completions",
                       ["model": "claude-test-sonnet",
                        "messages": [["role": "user", "content": "@work go"], ["role": "assistant", "content": "ok"],
                                     ["role": "user", "content": "@personal and now"]]], token: token)
        let c2 = ((r.json?["choices"] as? [JSONObject])?.first?["message"] as? JSONObject)?["content"] as? String
        check(c2 == "key=ak-personal said=and now", "switch identity mid-chat", "\(c2 ?? r.body)")

        // Anthropic client → OpenAI with tools, streamed.
        r = await call(port, "POST", "/v1/messages",
                       ["model": "work/gpt-test", "max_tokens": 100, "stream": true,
                        "messages": [["role": "user", "content": "weather?"]],
                        "tools": [["name": "get_weather", "input_schema": ["type": "object"]]]], token: token, anthropicStyle: true)
        let ap = ssePayloads(r.body)
        let text = ap.filter { $0["type"] as? String == "content_block_delta" }
            .compactMap { ($0["delta"] as? JSONObject)?["text"] as? String }.joined()
        let json = ap.filter { $0["type"] as? String == "content_block_delta" }
            .compactMap { ($0["delta"] as? JSONObject)?["partial_json"] as? String }.joined()
        let toolBlock = ap.first { ($0["content_block"] as? JSONObject)?["type"] as? String == "tool_use" }
        let stop = (ap.first { $0["type"] as? String == "message_delta" }?["delta"] as? JSONObject)?["stop_reason"] as? String
        check(text == "key=ok-work said=weather?", "anthropic stream ← openai text", "\(text) \(r.body.prefix(300))")
        check((toolBlock?["content_block"] as? JSONObject)?["name"] as? String == "get_weather" && json == "{\"city\":\"Sydney\"}",
              "anthropic stream ← openai tool call")
        check(stop == "tool_use" && ap.last?["type"] as? String == "message_stop", "anthropic stream: stop_reason tool_use")
        let upTools = mockLog.last("/openai/v1/chat/completions")?["tools"] as? [JSONObject]
        check((upTools?.first?["function"] as? JSONObject)?["name"] as? String == "get_weather", "openai upstream got function tools")

        // Anthropic client → Anthropic: passthrough keeps headers.
        r = await call(port, "POST", "/v1/messages?beta=true",
                       ["model": "claude-test-sonnet", "max_tokens": 10, "messages": [["role": "user", "content": "standup notes"]]],
                       token: token, anthropicStyle: true)
        check(r.status == 200 && ((r.json?["content"] as? [JSONObject])?.first?["text"] as? String) == "key=ak-work said=standup notes",
              "anthropic passthrough + keyword rule → work", "\(r.body.prefix(300))")

        // Thinking from another account → retried without it.
        r = await call(port, "POST", "/v1/messages",
                       ["model": "claude-test-sonnet", "max_tokens": 10, "thinking": ["type": "enabled", "budget_tokens": 1024],
                        "messages": [["role": "user", "content": "hi"],
                                     ["role": "assistant", "content": [["type": "thinking", "thinking": "x", "signature": "other"],
                                                                       ["type": "text", "text": "yo"]]],
                                     ["role": "user", "content": "again"]]], token: token, anthropicStyle: true)
        check(r.status == 200, "thinking from another account is dropped and retried", "\(r.status) \(r.body.prefix(200))")

        // Responses client → OpenAI passthrough (Codex) with reasoning from another account.
        r = await call(port, "POST", "/v1/responses",
                       ["model": "personal/gpt-test", "stream": true, "store": false,
                        "input": [["type": "message", "role": "user", "content": [["type": "input_text", "text": "hi"]]],
                                  ["type": "reasoning", "id": "rs", "encrypted_content": "from-work"]]],
                       token: token, userAgent: "codex_cli_rs/0.50")
        check(r.status == 200 && r.body.contains("key=ok-personal"), "responses passthrough + encrypted reasoning retry", "\(r.status) \(r.body.prefix(200))")

        // Responses client (Codex) → Anthropic with a custom tool.
        r = await call(port, "POST", "/v1/responses",
                       ["model": "work/claude-test-sonnet", "stream": true, "store": false,
                        "input": [["type": "message", "role": "user", "content": [["type": "input_text", "text": "patch it"]]]],
                        "tools": [["type": "function", "name": "get_weather", "parameters": ["type": "object"]]]],
                       token: token, userAgent: "codex_cli_rs/0.50")
        let rp = ssePayloads(r.body)
        let completed = rp.last { $0["type"] as? String == "response.completed" }?["response"] as? JSONObject
        let items = completed?["output"] as? [JSONObject] ?? []
        check(items.first?["type"] as? String == "message" && items.last?["type"] as? String == "function_call"
              && items.last?["arguments"] as? String == "{\"city\":\"Sydney\"}",
              "responses stream ← anthropic: message + function_call", "\(r.body.prefix(500))")

        // Non-stream responses ← anthropic.
        r = await call(port, "POST", "/v1/responses",
                       ["model": "work/claude-test-sonnet", "input": "plain string"], token: token)
        let outText = (((r.json?["output"] as? [JSONObject])?.first?["content"] as? [JSONObject])?.first)?["text"] as? String
        check(r.status == 200 && outText == "key=ak-work said=plain string", "responses non-stream ← anthropic", "\(r.status) \(r.body.prefix(300))")

        // Unknown route.
        r = await call(port, "GET", "/v1/nope", token: token)
        check(r.status == 404, "unknown path → 404")

        // Missing key.
        var cfg = sampleConfig(mockPort: mockPort)
        cfg.identities[1].credentials.append(GatewayCredential(provider: .xai))
        engine.update(cfg)
        r = await call(port, "POST", "/v1/chat/completions",
                       ["model": "personal/grok-4", "messages": [["role": "user", "content": "hi"]]], token: token)
        check(r.status == 401 && r.body.contains("No xAI key saved for Personal"), "missing key explains itself", "\(r.status) \(r.body)")
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

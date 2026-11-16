import Foundation

// MARK: - Prism endpoint: request handling
//
// Thread-safe and UI-free: GatewayController (main actor) feeds it the
// config, the server calls `handle` for every request.

final class GatewayEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var _config = GatewayConfig()
    private var keyCache: [String: String] = [:]
    private var modelCache: [String: (date: Date, models: [String])] = [:]
    private var _onLog: (@Sendable (GatewayLogEntry) -> Void)?

    /// Read keys from the Keychain on first use (tests turn this off).
    var useKeychain = true

    let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 600
        c.timeoutIntervalForResource = 4 * 3600
        c.httpMaximumConnectionsPerHost = 16
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    var config: GatewayConfig {
        lock.lock(); defer { lock.unlock() }
        return _config
    }

    func update(_ config: GatewayConfig) {
        lock.lock(); defer { lock.unlock() }
        _config = config
    }

    var onLog: (@Sendable (GatewayLogEntry) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onLog }
        set { lock.lock(); _onLog = newValue; lock.unlock() }
    }

    // MARK: Keys

    func setKey(_ key: String?, for credentialID: String) {
        lock.lock(); defer { lock.unlock() }
        keyCache[credentialID] = key
    }

    func key(for c: GatewayCredential) -> String? {
        lock.lock()
        if let k = keyCache[c.id] {
            lock.unlock()
            return k
        }
        lock.unlock()
        guard useKeychain, let k = GatewayKeychain.get(c.id) else { return nil }
        setKey(k, for: c.id)
        return k
    }

    // MARK: Models

    func knownModels(_ c: GatewayCredential) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return modelCache[c.id]?.models ?? []
    }

    func setModels(_ models: [String], for credentialID: String) {
        lock.lock(); defer { lock.unlock() }
        modelCache[credentialID] = (Date(), models)
    }

    private func isStale(_ c: GatewayCredential) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let entry = modelCache[c.id] else { return true }
        return Date().timeIntervalSince(entry.date) > 600
    }

    /// Ask the provider which models this key can use.
    func fetchModels(_ c: GatewayCredential) async throws -> [String] {
        let base = c.effectiveBaseURL
        guard !base.isEmpty else { throw GatewayRouteError(status: 400, message: "Enter the server's URL first.") }
        let urlString = c.provider == .anthropic ? base + "/v1/models?limit=1000" : base + "/models"
        guard let url = URL(string: urlString) else { throw GatewayRouteError(status: 400, message: "Invalid URL: \(urlString)") }
        var req = URLRequest(url: url, timeoutInterval: 15)
        let key = self.key(for: c) ?? ""
        if c.provider == .anthropic {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw GatewayRouteError(status: status, message: "\(c.provider.label): \(GatewayErrorBody.message(from: data)) (HTTP \(status))")
        }
        let ids = (GatewayJSON.parse(data)?["data"] as? [Any] ?? []).compactMap { ($0 as? JSONObject)?["id"] as? String }
        let models = Self.chatModels(ids, provider: c.provider)
        setModels(models, for: c.id)
        return models
    }

    /// OpenAI lists embeddings, audio, image and moderation models too.
    static func chatModels(_ ids: [String], provider: GatewayProvider) -> [String] {
        guard provider == .openai else { return ids.sorted() }
        let skip = ["embedding", "tts", "whisper", "dall-e", "moderation", "transcribe", "realtime", "audio",
                    "image", "search", "davinci", "babbage", "sora", "computer-use"]
        return ids.filter { id in
            let l = id.lowercased()
            return GatewayRouter.family(of: l) == .openai && !skip.contains { l.contains($0) }
        }.sorted()
    }

    func refreshStaleModels(timeout: TimeInterval = 6) async {
        let creds = config.identities.flatMap(\.credentials).filter { isStale($0) }
        guard !creds.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for c in creds {
                group.addTask { [self] in
                    _ = try? await withThrowingTimeout(timeout) { try await self.fetchModels(c) }
                }
            }
        }
    }

    // MARK: Handling

    private static func normalize(_ path: String) -> String {
        var p = path
        while p.hasPrefix("/v1/v1/") { p.removeFirst(3) }
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        if !p.hasPrefix("/v1/") && p != "/v1" && p != "/" { p = "/v1" + p }
        return p
    }

    private func authorized(_ req: GatewayHTTPRequest, _ cfg: GatewayConfig) -> Bool {
        guard cfg.requireToken || cfg.allowLAN else { return true }
        var presented = req.headers["x-api-key"] ?? req.headers["api-key"] ?? ""
        if let auth = req.headers["authorization"], auth.lowercased().hasPrefix("bearer ") {
            presented = String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        return !presented.isEmpty && presented == cfg.token
    }

    /// Anthropic-style clients identify themselves with these headers.
    private static func prefersAnthropic(_ req: GatewayHTTPRequest) -> Bool {
        req.headers["anthropic-version"] != nil || req.headers["x-api-key"] != nil
    }

    func handle(_ req: GatewayHTTPRequest, _ w: GatewayResponseWriter) async {
        if req.method == "OPTIONS" {
            await w.send(status: 204, body: Data())
            return
        }
        let path = Self.normalize(req.path)
        if req.method == "GET" && (path == "/" || path == "/v1" || path == "/v1/health") {
            await w.sendJSON(status: 200, ["name": "Prism endpoint", "ok": true])
            return
        }
        let cfg = config
        guard authorized(req, cfg) else {
            let api: GatewayAPI = Self.prefersAnthropic(req) ? .anthropic : .chat
            await w.sendJSON(status: 401, GatewayErrorBody.make(api, status: 401,
                message: "Use your Prism endpoint token as the API key (Prism → Settings → Endpoint)."))
            return
        }

        switch (req.method, path) {
        case ("GET", "/v1/models"):
            await refreshStaleModels()
            await w.sendJSON(status: 200, GatewayRouter.modelList(config: cfg, knownModels: knownModels))
        case ("GET", _) where path.hasPrefix("/v1/models/"):
            let id = String(path.dropFirst("/v1/models/".count)).removingPercentEncoding ?? ""
            let list = GatewayRouter.modelList(config: cfg, knownModels: knownModels)["data"] as? [JSONObject] ?? []
            if let m = list.first(where: { ($0["id"] as? String) == id }) {
                await w.sendJSON(status: 200, m)
            } else {
                await w.sendJSON(status: 404, GatewayErrorBody.make(Self.prefersAnthropic(req) ? .anthropic : .chat,
                                                                      status: 404, message: "Unknown model \(id)"))
            }
        case ("POST", "/v1/messages"):
            await proxy(.anthropic, req, w, cfg)
        case ("POST", "/v1/messages/count_tokens"):
            await countTokens(req, w, cfg)
        case ("POST", "/v1/chat/completions"):
            await proxy(.chat, req, w, cfg)
        case ("POST", "/v1/responses"):
            await proxy(.responses, req, w, cfg)
        default:
            await w.sendJSON(status: 404, GatewayErrorBody.make(Self.prefersAnthropic(req) ? .anthropic : .chat,
                                                                  status: 404, message: "Prism doesn't serve \(req.method) \(req.path)"))
        }
    }

    // MARK: Proxy

    private struct Upstream {
        var api: GatewayAPI
        var body: JSONObject
        var passthrough: Bool
        var canon: CanonRequest?
    }

    private func clientName(_ req: GatewayHTTPRequest) -> String {
        let ua = req.headers["user-agent"] ?? ""
        let first = ua.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "unknown" : String(first.prefix(40))
    }

    private func proxy(_ api: GatewayAPI, _ req: GatewayHTTPRequest, _ w: GatewayResponseWriter, _ cfg: GatewayConfig) async {
        let started = Date()
        guard var body = GatewayJSON.parse(req.body) else {
            await w.sendJSON(status: 400, GatewayErrorBody.make(api, status: 400, message: "Request body must be JSON."))
            return
        }
        let requestedModel = body["model"] as? String ?? ""
        let stream = body["stream"] as? Bool ?? false
        let client = req.headers["user-agent"] ?? ""

        func log(_ route: GatewayRoute?, status: Int, error: String? = nil) {
            onLog?(GatewayLogEntry(date: started, client: clientName(req), api: api.label,
                                   identity: route?.identity.name ?? "—", identityColor: route?.identity.colorHex ?? "#8E8E98",
                                   provider: route?.credential.provider.label ?? "—", model: route?.model ?? requestedModel,
                                   reason: route?.reason ?? "", status: status,
                                   milliseconds: Int(Date().timeIntervalSince(started) * 1000), stream: stream, error: error))
        }

        let route: GatewayRoute
        do {
            route = try GatewayRouter.route(config: cfg, requestedModel: requestedModel,
                                            userTexts: GatewayUserText.texts(in: body, api: api),
                                            client: client, knownModels: knownModels)
        } catch let e as GatewayRouteError {
            await w.sendJSON(status: e.status, GatewayErrorBody.make(api, status: e.status, message: e.message))
            log(nil, status: e.status, error: e.message)
            return
        } catch {
            await w.sendJSON(status: 500, GatewayErrorBody.make(api, status: 500, message: error.localizedDescription))
            return
        }

        if cfg.tagsEnabled {
            GatewayUserText.stripTags(cfg.identities.map(\.slug), in: &body, api: api)
        }
        let cred = route.credential
        let key = self.key(for: cred) ?? ""
        if key.isEmpty && cred.provider.keyRequired {
            let msg = "No \(cred.provider.label) key saved for \(route.identity.name). Add it in Prism → Settings → Endpoint."
            await w.sendJSON(status: 401, GatewayErrorBody.make(api, status: 401, message: msg))
            log(route, status: 401, error: msg)
            return
        }

        // Pick the provider's API and convert if it differs from the client's.
        let upstreamAPI: GatewayAPI = cred.provider == .anthropic ? .anthropic
            : (api == .responses && cred.provider == .openai ? .responses : .chat)
        var up: Upstream
        if upstreamAPI == api {
            var b = body
            b["model"] = route.model
            up = Upstream(api: api, body: b, passthrough: true, canon: nil)
        } else {
            if api == .responses, let prev = body["previous_response_id"], !(prev is NSNull) {
                let msg = "previous_response_id only works with OpenAI accounts. Turn off server-side storage (store: false) in your client to use \(cred.provider.label)."
                await w.sendJSON(status: 400, GatewayErrorBody.make(api, status: 400, message: msg))
                log(route, status: 400, error: msg)
                return
            }
            let canon: CanonRequest
            switch api {
            case .anthropic: canon = CanonRequest(anthropic: body)
            case .chat: canon = CanonRequest(chat: body)
            case .responses: canon = CanonRequest(responses: body)
            }
            let b = upstreamAPI == .anthropic ? canon.anthropicBody(model: route.model)
                                              : canon.chatBody(model: route.model, provider: cred.provider)
            up = Upstream(api: upstreamAPI, body: b, passthrough: false, canon: canon)
        }

        let routeHeaders = [("X-Prism-Identity", route.identity.name),
                            ("X-Prism-Upstream", "\(cred.provider.rawValue)/\(route.model)")]
        let echoModel = requestedModel.isEmpty ? route.model : requestedModel

        var retried = false
        while true {
            guard let request = makeRequest(up, cred: cred, key: key, client: req, stream: stream) else {
                await w.sendJSON(status: 500, GatewayErrorBody.make(api, status: 500, message: "Invalid provider URL for \(route.identity.name)."))
                log(route, status: 500, error: "invalid URL")
                return
            }
            do {
                if stream {
                    let (bytes, resp) = try await session.bytes(for: request)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 502
                    if status >= 400 {
                        var data = Data()
                        for try await b in bytes {
                            data.append(b)
                            if data.count > 1 << 20 { break }
                        }
                        if !retried, shouldRetryWithoutReasoning(status: status, data: data),
                           GatewayUserText.stripReasoning(in: &up.body, api: up.api) {
                            retried = true
                            continue
                        }
                        await sendUpstreamError(api: api, upstreamAPI: up.api, status: status, data: data, route: route, w: w, headers: routeHeaders)
                        log(route, status: status, error: GatewayErrorBody.message(from: data))
                        return
                    }
                    await w.startStream(status: 200, headers: [("Content-Type", "text/event-stream; charset=utf-8")] + routeHeaders)
                    if up.passthrough {
                        await pipe(bytes, to: w)
                    } else {
                        await translate(bytes, from: up.api, to: api, model: echoModel, canon: up.canon, clientBody: body, w: w)
                    }
                    await w.finish()
                    log(route, status: 200)
                } else {
                    let (data, resp) = try await session.data(for: request)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 502
                    if status >= 400 {
                        if !retried, shouldRetryWithoutReasoning(status: status, data: data),
                           GatewayUserText.stripReasoning(in: &up.body, api: up.api) {
                            retried = true
                            continue
                        }
                        await sendUpstreamError(api: api, upstreamAPI: up.api, status: status, data: data, route: route, w: w, headers: routeHeaders)
                        log(route, status: status, error: GatewayErrorBody.message(from: data))
                        return
                    }
                    if up.passthrough {
                        let type = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
                        await w.send(status: 200, headers: [("Content-Type", type)] + routeHeaders, body: data)
                    } else {
                        guard let j = GatewayJSON.parse(data) else {
                            await w.sendJSON(status: 502, GatewayErrorBody.make(api, status: 502, message: "Provider sent an unreadable reply."))
                            log(route, status: 502, error: "unreadable reply")
                            return
                        }
                        let canonResp = up.api == .anthropic ? CanonResponse(anthropic: j) : CanonResponse(chat: j)
                        let out: JSONObject
                        switch api {
                        case .anthropic: out = canonResp.anthropicJSON(model: echoModel)
                        case .chat: out = canonResp.chatJSON(model: echoModel)
                        case .responses: out = canonResp.responsesJSON(model: echoModel, customTools: up.canon?.customToolNames ?? [])
                        }
                        await w.sendJSON(status: 200, out, headers: routeHeaders)
                    }
                    log(route, status: 200)
                }
            } catch {
                let msg = "Couldn't reach \(cred.provider.label) for \(route.identity.name): \(error.localizedDescription)"
                await w.sendJSON(status: 502, GatewayErrorBody.make(api, status: 502, message: msg))
                log(route, status: 502, error: msg)
            }
            return
        }
    }

    private func makeRequest(_ up: Upstream, cred: GatewayCredential, key: String,
                             client: GatewayHTTPRequest, stream: Bool) -> URLRequest? {
        let base = cred.effectiveBaseURL
        var urlString: String
        switch up.api {
        case .anthropic:
            urlString = base + "/v1/messages"
            if up.passthrough, !client.query.isEmpty { urlString += "?" + client.query }
        case .chat:
            urlString = base + "/chat/completions"
        case .responses:
            urlString = base + "/responses"
        }
        guard let url = URL(string: urlString) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.httpBody = GatewayJSON.data(up.body)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        r.setValue("Prism/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")",
                   forHTTPHeaderField: "User-Agent")
        if cred.provider == .anthropic {
            r.setValue(key, forHTTPHeaderField: "x-api-key")
            r.setValue(up.passthrough ? (client.headers["anthropic-version"] ?? "2023-06-01") : "2023-06-01",
                       forHTTPHeaderField: "anthropic-version")
            if up.passthrough, let beta = client.headers["anthropic-beta"] {
                r.setValue(beta, forHTTPHeaderField: "anthropic-beta")
            }
        } else {
            if !key.isEmpty { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            if up.passthrough, let beta = client.headers["openai-beta"] {
                r.setValue(beta, forHTTPHeaderField: "OpenAI-Beta")
            }
        }
        return r
    }

    /// A conversation that switched accounts can carry reasoning the new
    /// account can't verify; retry once without it.
    private func shouldRetryWithoutReasoning(status: Int, data: Data) -> Bool {
        guard status == 400 else { return false }
        let m = GatewayErrorBody.message(from: data).lowercased()
        return m.contains("signature") || m.contains("encrypted") || m.contains("thinking") || m.contains("reasoning")
    }

    private func sendUpstreamError(api: GatewayAPI, upstreamAPI: GatewayAPI, status: Int, data: Data,
                                   route: GatewayRoute, w: GatewayResponseWriter, headers: [(String, String)]) async {
        let sameFamily = (api == .anthropic) == (upstreamAPI == .anthropic)
        if sameFamily, GatewayJSON.parse(data) != nil {
            await w.send(status: status, headers: [("Content-Type", "application/json")] + headers, body: data)
            return
        }
        let msg = "\(route.identity.name) · \(route.credential.provider.label): \(GatewayErrorBody.message(from: data))"
        await w.sendJSON(status: status, GatewayErrorBody.make(api, status: status, message: msg), headers: headers)
    }

    /// Same API on both sides: forward the bytes as they arrive.
    private func pipe(_ bytes: URLSession.AsyncBytes, to w: GatewayResponseWriter) async {
        var chunk = Data()
        do {
            for try await b in bytes {
                chunk.append(b)
                if b == 0x0A {
                    guard await w.write(chunk) else {
                        bytes.task.cancel()
                        return
                    }
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty { _ = await w.write(chunk) }
        } catch {
            _ = await w.write("\n")
        }
    }

    private func translate(_ bytes: URLSession.AsyncBytes, from upstreamAPI: GatewayAPI, to api: GatewayAPI,
                           model: String, canon: CanonRequest?, clientBody: JSONObject, w: GatewayResponseWriter) async {
        let decoder: GatewayStreamDecoder = upstreamAPI == .anthropic ? AnthropicStreamDecoder() : ChatStreamDecoder()
        let encoder: GatewayStreamEncoder
        switch api {
        case .anthropic:
            encoder = AnthropicStreamEncoder(model: model)
        case .chat:
            let includeUsage = (clientBody["stream_options"] as? JSONObject)?["include_usage"] as? Bool ?? false
            encoder = ChatStreamEncoder(model: model, includeUsage: includeUsage)
        case .responses:
            encoder = ResponsesStreamEncoder(model: model, customTools: canon?.customToolNames ?? [])
        }
        var lines = SSELineBuffer()
        var pending = Data()
        func emit(_ payloads: [String]) async -> Bool {
            var out = ""
            for p in payloads {
                for e in decoder.decode(p) { out += encoder.encode(e) }
            }
            return out.isEmpty ? true : await w.write(out)
        }
        do {
            for try await b in bytes {
                pending.append(b)
                if b == 0x0A {
                    guard await emit(lines.feed(pending)) else {
                        bytes.task.cancel()
                        return
                    }
                    pending.removeAll(keepingCapacity: true)
                }
            }
            _ = await emit(lines.feed(pending) + lines.flush())
            _ = await w.write(decoder.end().map { encoder.encode($0) }.joined())
        } catch {
            _ = await w.write(encoder.encode(.error("Connection to the provider dropped: \(error.localizedDescription)")))
        }
    }

    // MARK: count_tokens

    private func countTokens(_ req: GatewayHTTPRequest, _ w: GatewayResponseWriter, _ cfg: GatewayConfig) async {
        guard var body = GatewayJSON.parse(req.body) else {
            await w.sendJSON(status: 400, GatewayErrorBody.make(.anthropic, status: 400, message: "Request body must be JSON."))
            return
        }
        let estimate = ["input_tokens": max(1, req.body.count / 4)]
        guard let route = try? GatewayRouter.route(config: cfg, requestedModel: body["model"] as? String ?? "",
                                                   userTexts: GatewayUserText.texts(in: body, api: .anthropic),
                                                   client: req.headers["user-agent"] ?? "", knownModels: knownModels),
              route.credential.provider == .anthropic,
              let key = key(for: route.credential), !key.isEmpty,
              let url = URL(string: route.credential.effectiveBaseURL + "/v1/messages/count_tokens") else {
            await w.sendJSON(status: 200, estimate)
            return
        }
        if cfg.tagsEnabled { GatewayUserText.stripTags(cfg.identities.map(\.slug), in: &body, api: .anthropic) }
        body["model"] = route.model
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.httpBody = GatewayJSON.data(body)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue(req.headers["anthropic-version"] ?? "2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let beta = req.headers["anthropic-beta"] { r.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        if let (data, resp) = try? await session.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 {
            await w.send(status: 200, headers: [("Content-Type", "application/json")], body: data)
        } else {
            await w.sendJSON(status: 200, estimate)
        }
    }
}

/// Run `work`, giving up after `seconds`.
func withThrowingTimeout<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw GatewayRouteError(status: 504, message: "Timed out")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

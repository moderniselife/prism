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

    /// Token counts and estimated spend per identity.
    let usage: GatewayUsageStore

    init(usage: GatewayUsageStore = GatewayUsageStore(fileURL: nil)) {
        self.usage = usage
    }

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

    /// Providers list embeddings, audio, image and moderation models too.
    static func chatModels(_ ids: [String], provider: GatewayProvider) -> [String] {
        let notChat = ["embed", "tts", "whisper", "dall-e", "moderation", "transcribe", "rerank"]
        let chat = ids.filter { id in !notChat.contains { id.lowercased().contains($0) } }
        guard provider == .openai else { return chat.sorted() }
        let skip = ["realtime", "audio", "image", "search", "davinci", "babbage", "sora", "computer-use"]
        return chat.filter { id in
            let l = id.lowercased()
            return GatewayRouter.family(of: l) == .openai && !skip.contains { l.contains($0) }
        }.sorted()
    }

    /// Re-list models for providers whose list is old. Providers without
    /// a key are skipped, and a failure is remembered for the same ten
    /// minutes, so apps aren't kept waiting on every /v1/models call.
    func refreshStaleModels(timeout: TimeInterval = 3) async {
        let creds = config.identities.flatMap(\.credentials).filter { c in
            isStale(c) && (!c.provider.keyRequired || !(key(for: c) ?? "").isEmpty)
                && !(c.provider == .compatible && c.baseURL.isEmpty)
        }
        guard !creds.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for c in creds {
                group.addTask { [self] in
                    do {
                        _ = try await withThrowingTimeout(timeout) { try await self.fetchModels(c) }
                    } catch {
                        setModels(knownModels(c), for: c.id)
                    }
                }
            }
        }
    }

    // MARK: Limits (rate limits, credit, budgets)

    /// Identity + provider pairs that recently said "slow down" or "out of
    /// credit", until when.
    private var cooldowns: [String: Date] = [:]

    private static func cooldownKey(_ identityID: String, _ provider: GatewayProvider) -> String {
        "\(identityID)|\(provider.rawValue)"
    }

    func coolDown(_ identityID: String, _ provider: GatewayProvider, for seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        cooldowns[Self.cooldownKey(identityID, provider)] = Date().addingTimeInterval(seconds)
    }

    /// Until when this identity's provider is cooling down, if it is.
    func cooldown(_ identityID: String, _ provider: GatewayProvider) -> Date? {
        lock.lock(); defer { lock.unlock() }
        guard let until = cooldowns[Self.cooldownKey(identityID, provider)], until > Date() else { return nil }
        return until
    }

    /// Every identity id that is cooling down for any provider, with the time.
    func cooldownSnapshot() -> [String: Date] {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        var out: [String: Date] = [:]
        for (key, until) in cooldowns where until > now {
            let id = String(key.split(separator: "|").first ?? "")
            out[id] = max(out[id] ?? until, until)
        }
        return out
    }

    func monthSpend(_ identityID: String) -> Double {
        usage.month(identityID).cost
    }

    private func overBudget(_ identity: GatewayIdentity) -> Bool {
        guard let budget = identity.monthlyBudget, budget > 0 else { return false }
        return monthSpend(identity.id) >= budget
    }

    /// Why this route shouldn't be used right now, if anything.
    private func limitReason(_ route: GatewayRoute) -> String? {
        if overBudget(route.identity), route.identity.budgetAction != .warn {
            return "is over its $\(Self.money(route.identity.monthlyBudget ?? 0)) monthly budget"
        }
        if let until = cooldown(route.identity.id, route.credential.provider) {
            return "is rate-limited until \(Self.clock(until))"
        }
        return nil
    }

    /// Move to the fallback identity while the chosen one is limited.
    /// Returns nil (with an error) when a budget blocks the request.
    private func applyLimits(_ route: GatewayRoute, _ cfg: GatewayConfig, visited: inout Set<String>,
                             notes: inout [String]) -> Result<GatewayRoute, GatewayRouteError> {
        var r = route
        while let reason = limitReason(r) {
            if let fbID = r.identity.fallbackIdentityID, !visited.contains(fbID),
               let fb = cfg.identity(id: fbID),
               let cred = GatewayRouter.credential(for: r.model, in: fb, knownModels: knownModels) {
                notes.append("\(r.identity.name) \(reason) → \(fb.name)")
                visited.insert(fb.id)
                r = GatewayRoute(identity: fb, credential: cred, model: r.model, reason: r.reason)
                continue
            }
            if overBudget(r.identity), r.identity.budgetAction != .warn {
                return .failure(GatewayRouteError(status: 429,
                    message: "\(r.identity.name) \(reason)\(r.identity.fallbackIdentityID == nil ? "" : " and its fallback can't take this model"). Raise the budget in Prism → Settings → Endpoint."))
            }
            break // rate-limited with nowhere to go: try anyway
        }
        return .success(r)
    }

    /// Whether a failed reply means "this account can't right now" — so
    /// another identity could answer — and for how long to stay away.
    static func limitCooldown(status: Int, data: Data, retryAfter: String?) -> TimeInterval? {
        let message = GatewayErrorBody.message(from: data).lowercased()
        let credit = ["credit", "billing", "quota", "insufficient", "balance", "payment"].contains { message.contains($0) }
        if status == 402 || ((status == 400 || status == 403 || status == 429) && credit) { return 15 * 60 }
        if status == 429 {
            if let s = retryAfter.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) { return min(max(s, 5), 3600) }
            return 60
        }
        return nil
    }

    static func money(_ v: Double) -> String {
        v >= 100 ? String(format: "%.0f", v) : String(format: "%.2f", v)
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    // MARK: Handling

    private static func normalize(_ path: String) -> String {
        var p = path
        while p.hasPrefix("/v1/v1/") { p.removeFirst(3) }
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        if !p.hasPrefix("/v1/") && p != "/v1" && p != "/" { p = "/v1" + p }
        return p
    }

    private enum Caller {
        case denied
        case anyIdentity
        case pinned(String)
    }

    private func caller(_ req: GatewayHTTPRequest, _ cfg: GatewayConfig) -> Caller {
        var presented = req.headers["x-api-key"] ?? req.headers["api-key"] ?? ""
        if let auth = req.headers["authorization"], auth.lowercased().hasPrefix("bearer ") {
            presented = String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        if !presented.isEmpty, let identity = cfg.identities.first(where: { $0.token == presented }) {
            return .pinned(identity.id)
        }
        if !presented.isEmpty && presented == cfg.token { return .anyIdentity }
        return (cfg.requireToken || cfg.allowLAN) ? .denied : .anyIdentity
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
        let who = caller(req, cfg)
        if case .denied = who {
            let api: GatewayAPI = Self.prefersAnthropic(req) ? .anthropic : .chat
            await w.sendJSON(status: 401, GatewayErrorBody.make(api, status: 401,
                message: "Use your Prism endpoint token as the API key (Prism → Settings → Endpoint)."))
            return
        }
        var pinned: String?
        if case .pinned(let id) = who { pinned = id }

        switch (req.method, path) {
        case ("GET", "/v1/models"):
            await refreshStaleModels()
            var listCfg = cfg
            if let pinned { listCfg.identities = cfg.identities.filter { $0.id == pinned }; listCfg.activeIdentityID = pinned }
            await w.sendJSON(status: 200, GatewayRouter.modelList(config: listCfg, knownModels: knownModels))
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
            await proxy(.anthropic, req, w, cfg, pinned: pinned)
        case ("POST", "/v1/messages/count_tokens"):
            await countTokens(req, w, cfg, pinned: pinned)
        case ("POST", "/v1/chat/completions"):
            await proxy(.chat, req, w, cfg, pinned: pinned)
        case ("POST", "/v1/responses"):
            await proxy(.responses, req, w, cfg, pinned: pinned)
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

    /// The request as the route's provider expects it.
    private func upstream(for api: GatewayAPI, body: JSONObject, route: GatewayRoute) -> Result<Upstream, GatewayRouteError> {
        let cred = route.credential
        let upstreamAPI: GatewayAPI = cred.provider == .anthropic ? .anthropic
            : (api == .responses && cred.provider == .openai ? .responses : .chat)
        if upstreamAPI == api {
            var b = body
            b["model"] = route.model
            return .success(Upstream(api: api, body: b, passthrough: true, canon: nil))
        }
        if api == .responses, let prev = body["previous_response_id"], !(prev is NSNull) {
            return .failure(GatewayRouteError(status: 400,
                message: "previous_response_id only works with OpenAI accounts. Turn off server-side storage (store: false) in your client to use \(cred.provider.label)."))
        }
        let canon: CanonRequest
        switch api {
        case .anthropic: canon = CanonRequest(anthropic: body)
        case .chat: canon = CanonRequest(chat: body)
        case .responses: canon = CanonRequest(responses: body)
        }
        let b = upstreamAPI == .anthropic ? canon.anthropicBody(model: route.model)
                                          : canon.chatBody(model: route.model, provider: cred.provider)
        return .success(Upstream(api: upstreamAPI, body: b, passthrough: false, canon: canon))
    }

    private func proxy(_ api: GatewayAPI, _ req: GatewayHTTPRequest, _ w: GatewayResponseWriter,
                       _ cfg: GatewayConfig, pinned: String?) async {
        let started = Date()
        guard var body = GatewayJSON.parse(req.body) else {
            await w.sendJSON(status: 400, GatewayErrorBody.make(api, status: 400, message: "Request body must be JSON."))
            return
        }
        let requestedModel = body["model"] as? String ?? ""
        let stream = body["stream"] as? Bool ?? false
        let client = req.headers["user-agent"] ?? ""
        var notes: [String] = []

        func log(_ route: GatewayRoute?, status: Int, usage: CanonUsage? = nil, error: String? = nil) {
            var cost: Double?
            if let route, let usage {
                cost = GatewayPricing.price(for: route.model, provider: route.credential.provider, overrides: cfg.priceOverrides)?.cost(usage)
                self.usage.record(identityID: route.identity.id, model: route.model, usage: usage, cost: cost)
            }
            onLog?(GatewayLogEntry(inputTokens: usage?.totalInput ?? 0, outputTokens: usage?.output ?? 0, cost: cost,
                                   note: notes.isEmpty ? nil : notes.joined(separator: "; "),
                                   date: started, client: clientName(req), api: api.label,
                                   identity: route?.identity.name ?? "—", identityColor: route?.identity.colorHex ?? "#8E8E98",
                                   provider: route?.credential.provider.label ?? "—", model: route?.model ?? requestedModel,
                                   reason: route?.reason ?? "", status: status,
                                   milliseconds: Int(Date().timeIntervalSince(started) * 1000), stream: stream, error: error))
        }

        var route: GatewayRoute
        do {
            route = try GatewayRouter.route(config: cfg, requestedModel: requestedModel,
                                            userTexts: GatewayUserText.texts(in: body, api: api),
                                            client: client, pinnedIdentityID: pinned, knownModels: knownModels)
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

        var visited: Set<String> = [route.identity.id]
        switch applyLimits(route, cfg, visited: &visited, notes: &notes) {
        case .success(let r): route = r
        case .failure(let e):
            await w.sendJSON(status: e.status, GatewayErrorBody.make(api, status: e.status, message: e.message))
            log(route, status: e.status, error: e.message)
            return
        }

        let echoModel = requestedModel.isEmpty ? route.model : requestedModel
        var strippedReasoning = false
        var attempts = 0

        while attempts < 2 + cfg.identities.count {
            attempts += 1
            let cred = route.credential
            let key = self.key(for: cred) ?? ""
            if key.isEmpty && cred.provider.keyRequired {
                let msg = "No \(cred.provider.label) key saved for \(route.identity.name). Add it in Prism → Settings → Endpoint."
                await w.sendJSON(status: 401, GatewayErrorBody.make(api, status: 401, message: msg))
                log(route, status: 401, error: msg)
                return
            }
            var up: Upstream
            switch upstream(for: api, body: body, route: route) {
            case .success(let u): up = u
            case .failure(let e):
                await w.sendJSON(status: e.status, GatewayErrorBody.make(api, status: e.status, message: e.message))
                log(route, status: e.status, error: e.message)
                return
            }
            if strippedReasoning { GatewayUserText.stripReasoning(in: &up.body, api: up.api) }
            let routeHeaders = [("X-Prism-Identity", route.identity.name),
                                ("X-Prism-Upstream", "\(cred.provider.rawValue)/\(route.model)")]
            guard let request = makeRequest(up, cred: cred, key: key, client: req, stream: stream) else {
                await w.sendJSON(status: 500, GatewayErrorBody.make(api, status: 500, message: "Invalid provider URL for \(route.identity.name)."))
                log(route, status: 500, error: "invalid URL")
                return
            }

            /// After an error reply: try again (true) or report it.
            func handleFailure(status: Int, data: Data, response: URLResponse?) -> Bool {
                if !strippedReasoning, shouldRetryWithoutReasoning(status: status, data: data),
                   GatewayUserText.stripReasoning(in: &up.body, api: up.api) {
                    strippedReasoning = true
                    return true
                }
                let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                if let wait = Self.limitCooldown(status: status, data: data, retryAfter: retryAfter) {
                    coolDown(route.identity.id, cred.provider, for: wait)
                    if let fbID = route.identity.fallbackIdentityID, !visited.contains(fbID),
                       let fb = cfg.identity(id: fbID),
                       let fbCred = GatewayRouter.credential(for: route.model, in: fb, knownModels: knownModels) {
                        let why = status == 429 ? "rate-limited" : "out of credit"
                        notes.append("\(route.identity.name) \(why) (\(status)) → \(fb.name)")
                        visited.insert(fb.id)
                        route = GatewayRoute(identity: fb, credential: fbCred, model: route.model, reason: route.reason)
                        return true
                    }
                }
                return false
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
                        if handleFailure(status: status, data: data, response: resp) { continue }
                        await sendUpstreamError(api: api, upstreamAPI: up.api, status: status, data: data, route: route, w: w, headers: routeHeaders)
                        log(route, status: status, error: GatewayErrorBody.message(from: data))
                        return
                    }
                    await w.startStream(status: 200, headers: [("Content-Type", "text/event-stream; charset=utf-8")] + routeHeaders)
                    let used: CanonUsage
                    if up.passthrough {
                        used = await pipe(bytes, api: up.api, to: w)
                    } else {
                        used = await translate(bytes, from: up.api, to: api, model: echoModel, canon: up.canon, clientBody: body, w: w)
                    }
                    await w.finish()
                    log(route, status: 200, usage: used)
                } else {
                    let (data, resp) = try await session.data(for: request)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 502
                    if status >= 400 {
                        if handleFailure(status: status, data: data, response: resp) { continue }
                        await sendUpstreamError(api: api, upstreamAPI: up.api, status: status, data: data, route: route, w: w, headers: routeHeaders)
                        log(route, status: status, error: GatewayErrorBody.message(from: data))
                        return
                    }
                    guard let j = GatewayJSON.parse(data) else {
                        if up.passthrough {
                            let type = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
                            await w.send(status: 200, headers: [("Content-Type", type)] + routeHeaders, body: data)
                            log(route, status: 200)
                        } else {
                            await w.sendJSON(status: 502, GatewayErrorBody.make(api, status: 502, message: "Provider sent an unreadable reply."))
                            log(route, status: 502, error: "unreadable reply")
                        }
                        return
                    }
                    if up.passthrough {
                        let type = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
                        await w.send(status: 200, headers: [("Content-Type", type)] + routeHeaders, body: data)
                        log(route, status: 200, usage: CanonUsage(reply: j, api: up.api))
                    } else {
                        let canonResp = up.api == .anthropic ? CanonResponse(anthropic: j) : CanonResponse(chat: j)
                        let out: JSONObject
                        switch api {
                        case .anthropic: out = canonResp.anthropicJSON(model: echoModel)
                        case .chat: out = canonResp.chatJSON(model: echoModel)
                        case .responses: out = canonResp.responsesJSON(model: echoModel, customTools: up.canon?.customToolNames ?? [])
                        }
                        await w.sendJSON(status: 200, out, headers: routeHeaders)
                        log(route, status: 200, usage: canonResp.usage)
                    }
                }
            } catch {
                let msg = "Couldn't reach \(cred.provider.label) for \(route.identity.name): \(error.localizedDescription)"
                await w.sendJSON(status: 502, GatewayErrorBody.make(api, status: 502, message: msg))
                log(route, status: 502, error: msg)
            }
            return
        }
        await w.sendJSON(status: 502, GatewayErrorBody.make(api, status: 502, message: "Every identity Prism tried was unavailable."))
        log(route, status: 502, error: "no identity available")
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

    /// Same API on both sides: forward the bytes as they arrive, noting
    /// token counts on the way.
    private func pipe(_ bytes: URLSession.AsyncBytes, api: GatewayAPI, to w: GatewayResponseWriter) async -> CanonUsage {
        let sniffer = UsageSniffer(api: api)
        var chunk = Data()
        do {
            for try await b in bytes {
                chunk.append(b)
                if b == 0x0A {
                    sniffer.feed(chunk)
                    guard await w.write(chunk) else {
                        bytes.task.cancel()
                        return sniffer.usage
                    }
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty {
                sniffer.feed(chunk)
                _ = await w.write(chunk)
            }
        } catch {
            _ = await w.write("\n")
        }
        return sniffer.usage
    }

    private func translate(_ bytes: URLSession.AsyncBytes, from upstreamAPI: GatewayAPI, to api: GatewayAPI,
                           model: String, canon: CanonRequest?, clientBody: JSONObject, w: GatewayResponseWriter) async -> CanonUsage {
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
        var usage = CanonUsage()
        func encode(_ events: [StreamEvent]) -> String {
            var out = ""
            for e in events {
                switch e {
                case .start(_, _, let u) where u.totalInput > 0: usage = u
                case .finish(_, let u): usage = u
                default: break
                }
                out += encoder.encode(e)
            }
            return out
        }
        var lines = SSELineBuffer()
        var pending = Data()
        func emit(_ payloads: [String]) async -> Bool {
            let out = encode(payloads.flatMap { decoder.decode($0) })
            return out.isEmpty ? true : await w.write(out)
        }
        do {
            for try await b in bytes {
                pending.append(b)
                if b == 0x0A {
                    guard await emit(lines.feed(pending)) else {
                        bytes.task.cancel()
                        return usage
                    }
                    pending.removeAll(keepingCapacity: true)
                }
            }
            _ = await emit(lines.feed(pending) + lines.flush())
            _ = await w.write(encode(decoder.end()))
        } catch {
            _ = await w.write(encoder.encode(.error("Connection to the provider dropped: \(error.localizedDescription)")))
        }
        return usage
    }

    // MARK: count_tokens

    private func countTokens(_ req: GatewayHTTPRequest, _ w: GatewayResponseWriter, _ cfg: GatewayConfig, pinned: String?) async {
        guard var body = GatewayJSON.parse(req.body) else {
            await w.sendJSON(status: 400, GatewayErrorBody.make(.anthropic, status: 400, message: "Request body must be JSON."))
            return
        }
        let estimate = ["input_tokens": max(1, req.body.count / 4)]
        guard let route = try? GatewayRouter.route(config: cfg, requestedModel: body["model"] as? String ?? "",
                                                   userTexts: GatewayUserText.texts(in: body, api: .anthropic),
                                                   client: req.headers["user-agent"] ?? "", pinnedIdentityID: pinned,
                                                   knownModels: knownModels),
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

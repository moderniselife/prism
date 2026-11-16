import Foundation

// MARK: - Prism endpoint: which identity answers a request
//
// In order:
//   1. An identity-prefixed model ("work/claude-sonnet-4-5", or just "work")
//   2. The latest @tag in the conversation ("@personal what's for dinner")
//   3. An identity's own access token (the app is pinned to it)
//   4. The first matching auto-switch rule
//   5. The active identity (Prism's toggle)
// Then the identity's provider that serves the model is chosen.

struct GatewayRoute {
    let identity: GatewayIdentity
    let credential: GatewayCredential
    let model: String
    let reason: String
}

struct GatewayRouteError: Error {
    let status: Int
    let message: String
}

enum GatewayRouter {
    /// Models that mean "the identity's default".
    static let autoNames: Set<String> = ["prism", "auto", "default", "prism-auto"]

    static func route(config: GatewayConfig,
                      requestedModel: String,
                      userTexts: [String],
                      client: String,
                      now: Date = Date(),
                      pinnedIdentityID: String? = nil,
                      knownModels: (GatewayCredential) -> [String]) throws -> GatewayRoute {
        guard !config.identities.isEmpty else {
            throw GatewayRouteError(status: 503, message: "Prism has no identities yet. Add one in Prism → Settings → Endpoint.")
        }
        var model: String? = requestedModel.trimmingCharacters(in: .whitespaces)
        var chosen: GatewayIdentity?
        var reason = ""

        // 1. Prefix
        let lowered = model!.lowercased()
        if let slash = lowered.firstIndex(of: "/") {
            let prefix = String(lowered[..<slash])
            if let identity = config.identities.first(where: { $0.slug == prefix }) {
                chosen = identity
                reason = "model prefix"
                model = String(model![model!.index(after: slash)...])
            } else if prefix == "prism" {
                model = String(model![model!.index(after: slash)...])
            }
        } else if let identity = config.identities.first(where: { $0.slug == lowered }) {
            chosen = identity
            reason = "model prefix"
            model = nil
        }
        if let m = model, m.isEmpty || autoNames.contains(m.lowercased()) { model = nil }

        // 2. Tags
        if chosen == nil, config.tagsEnabled {
            outer: for text in userTexts.reversed() {
                // The tag nearest the end of the message wins within it.
                var best: (GatewayIdentity, String.Index)?
                for identity in config.identities where !identity.slug.isEmpty {
                    if let r = lastTagRange(identity.slug, in: text), best == nil || r.lowerBound > best!.1 {
                        best = (identity, r.lowerBound)
                    }
                }
                if let best {
                    chosen = best.0
                    reason = "@\(best.0.slug)"
                    break outer
                }
            }
        }

        // 3. Identity token
        if chosen == nil, let pinned = pinnedIdentityID, let identity = config.identity(id: pinned) {
            chosen = identity
            reason = "\(identity.name) token"
        }

        // 4. Rules
        if chosen == nil {
            let latest = userTexts.last ?? ""
            for rule in config.rules where rule.enabled {
                guard let identity = config.identity(id: rule.identityID) else { continue }
                if matches(rule, latest: latest, client: client, now: now) {
                    chosen = identity
                    reason = ruleReason(rule)
                    break
                }
            }
        }

        // 5. Active
        if chosen == nil {
            chosen = config.activeIdentity
            reason = "active"
        }
        guard let identity = chosen else {
            throw GatewayRouteError(status: 503, message: "No identity selected in Prism.")
        }

        let finalModel = model ?? identity.defaultModel
        guard !finalModel.isEmpty else {
            throw GatewayRouteError(status: 400, message: "Pick a model, or set a default model for \(identity.name) in Prism.")
        }
        guard let credential = credential(for: finalModel, in: identity, knownModels: knownModels) else {
            throw GatewayRouteError(status: 400, message: "\(identity.name) has no provider for “\(finalModel)”. Add one in Prism → Settings → Endpoint.")
        }
        return GatewayRoute(identity: identity, credential: credential, model: finalModel, reason: reason)
    }

    /// Which of the identity's providers serves `model`.
    static func credential(for model: String, in identity: GatewayIdentity,
                           knownModels: (GatewayCredential) -> [String]) -> GatewayCredential? {
        let creds = identity.credentials
        if let c = creds.first(where: { knownModels($0).contains(model) }) { return c }
        if let family = family(of: model), let c = creds.first(where: { $0.provider == family }) { return c }
        if let c = creds.first(where: { $0.provider == .compatible }) { return c }
        return creds.count == 1 ? creds[0] : nil
    }

    static func family(of model: String) -> GatewayProvider? {
        let m = model.lowercased()
        if m.hasPrefix("claude") || m.contains("anthropic") { return .anthropic }
        if m.hasPrefix("grok") { return .xai }
        let openAIPrefixes = ["gpt", "o1", "o3", "o4", "chatgpt", "codex", "davinci", "omni"]
        if openAIPrefixes.contains(where: { m.hasPrefix($0) }) { return .openai }
        return nil
    }

    // MARK: Tags

    /// Last "@slug" in `text` as a whole word (not part of an email or
    /// a longer word).
    static func lastTagRange(_ slug: String, in text: String) -> Range<String.Index>? {
        guard let re = tagRegex(slug) else { return nil }
        let ns = text as NSString
        guard let m = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        return Range(m.range, in: text)
    }

    static func stripTags(_ slugs: [String], from text: String) -> String {
        var out = text
        for slug in slugs where !slug.isEmpty {
            guard let re = tagRegex(slug) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: "")
        }
        guard out != text else { return text }
        // Tidy the space a removed tag leaves behind.
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func tagRegex(_ slug: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: slug)
        return try? NSRegularExpression(pattern: "(?<![\\w@.])@\(escaped)(?![\\w-])", options: [.caseInsensitive])
    }

    // MARK: Rules

    static func matches(_ rule: GatewayRule, latest: String, client: String, now: Date) -> Bool {
        let pattern = rule.pattern.trimmingCharacters(in: .whitespaces)
        switch rule.kind {
        case .keyword:
            let words = pattern.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return words.contains { word in
                guard let re = try? NSRegularExpression(pattern: "(?<![\\w])\(NSRegularExpression.escapedPattern(for: word))(?![\\w])",
                                                        options: [.caseInsensitive]) else { return false }
                return re.firstMatch(in: latest, range: NSRange(location: 0, length: (latest as NSString).length)) != nil
            }
        case .regex:
            guard !pattern.isEmpty, let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
            return re.firstMatch(in: latest, range: NSRange(location: 0, length: (latest as NSString).length)) != nil
        case .client:
            let needles = pattern.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return needles.contains { client.localizedCaseInsensitiveContains($0) }
        case .schedule:
            let cal = Calendar.current
            let weekday = cal.component(.weekday, from: now)
            guard rule.days.contains(weekday) else { return false }
            let minute = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
            if rule.startMinute <= rule.endMinute {
                return minute >= rule.startMinute && minute < rule.endMinute
            }
            return minute >= rule.startMinute || minute < rule.endMinute
        }
    }

    static func ruleReason(_ rule: GatewayRule) -> String {
        switch rule.kind {
        case .keyword: return "mentions “\(rule.pattern)”"
        case .regex: return "matches /\(rule.pattern)/"
        case .client: return "from \(rule.pattern)"
        case .schedule: return "schedule"
        }
    }

    // MARK: Model list

    /// `/v1/models`, in a shape both OpenAI and Anthropic clients accept.
    static func modelList(config: GatewayConfig, knownModels: (GatewayCredential) -> [String]) -> JSONObject {
        var data: [JSONObject] = []
        var seen = Set<String>()
        let created = Int(Date().timeIntervalSince1970)
        func add(_ id: String, display: String, owner: String) {
            guard seen.insert(id).inserted else { return }
            var o: JSONObject = ["id": id, "object": "model", "type": "model", "created": created,
                                 "created_at": "1970-01-01T00:00:00Z", "owned_by": owner, "display_name": display]
            let lower = id.lowercased()
            if lower.contains("claude") {
                for tier in ["opus", "sonnet", "haiku"] where lower.contains(tier) {
                    o["anthropic_family_tier"] = tier
                }
            }
            data.append(o)
        }
        let active = config.activeIdentity
        if config.modelList != .prefixed {
            add("prism", display: "Prism · \(active?.name ?? "active")", owner: "prism")
            // Plain ids follow the active identity: list the ones it serves first.
            let ordered = (active.map { [$0] } ?? []) + config.identities.filter { $0.id != active?.id }
            for identity in ordered {
                for c in identity.credentials {
                    for m in knownModels(c) { add(m, display: m, owner: "prism") }
                }
            }
        }
        if config.modelList != .plain {
            for identity in config.identities {
                add(identity.slug, display: "\(identity.name) · default", owner: "prism:\(identity.slug)")
                for c in identity.credentials {
                    for m in knownModels(c) {
                        add("\(identity.slug)/\(m)", display: "\(identity.name) · \(m)", owner: "prism:\(identity.slug)")
                    }
                }
            }
        }
        return ["object": "list", "data": data, "has_more": false,
                "first_id": data.first?["id"] ?? NSNull(), "last_id": data.last?["id"] ?? NSNull()]
    }
}

// MARK: - Reading and editing user text in raw requests

enum GatewayUserText {
    /// The user's own words, oldest first (tool output excluded).
    static func texts(in body: JSONObject, api: GatewayAPI) -> [String] {
        var out: [String] = []
        switch api {
        case .anthropic, .chat:
            for case let m as JSONObject in (body["messages"] as? [Any] ?? []) where (m["role"] as? String) == "user" {
                if let s = m["content"] as? String {
                    out.append(s)
                } else {
                    let t = (m["content"] as? [Any] ?? []).compactMap { b -> String? in
                        guard let b = b as? JSONObject, (b["type"] as? String) == "text" else { return nil }
                        return b["text"] as? String
                    }.joined(separator: "\n")
                    if !t.isEmpty { out.append(t) }
                }
            }
        case .responses:
            if let s = body["input"] as? String { out.append(s) }
            for case let item as JSONObject in (body["input"] as? [Any] ?? []) where (item["role"] as? String) == "user" {
                if let s = item["content"] as? String {
                    out.append(s)
                } else {
                    let t = (item["content"] as? [Any] ?? []).compactMap { b -> String? in
                        guard let b = b as? JSONObject, ["input_text", "text"].contains(b["type"] as? String ?? "") else { return nil }
                        return b["text"] as? String
                    }.joined(separator: "\n")
                    if !t.isEmpty { out.append(t) }
                }
            }
        }
        return out
    }

    /// Remove @tags from the user's messages before they leave the Mac.
    static func stripTags(_ slugs: [String], in body: inout JSONObject, api: GatewayAPI) {
        func clean(_ s: String) -> String { GatewayRouter.stripTags(slugs, from: s) }
        func cleanBlocks(_ blocks: [Any], textTypes: Set<String>) -> [Any] {
            blocks.map { b in
                guard var o = b as? JSONObject, textTypes.contains(o["type"] as? String ?? ""),
                      let t = o["text"] as? String else { return b }
                o["text"] = clean(t)
                return o
            }
        }
        switch api {
        case .anthropic, .chat:
            guard var msgs = body["messages"] as? [Any] else { return }
            for i in msgs.indices {
                guard var m = msgs[i] as? JSONObject, (m["role"] as? String) == "user" else { continue }
                if let s = m["content"] as? String {
                    m["content"] = clean(s)
                } else if let blocks = m["content"] as? [Any] {
                    m["content"] = cleanBlocks(blocks, textTypes: ["text"])
                }
                msgs[i] = m
            }
            body["messages"] = msgs
        case .responses:
            if let s = body["input"] as? String {
                body["input"] = clean(s)
                return
            }
            guard var items = body["input"] as? [Any] else { return }
            for i in items.indices {
                guard var item = items[i] as? JSONObject, (item["role"] as? String) == "user" else { continue }
                if let s = item["content"] as? String {
                    item["content"] = clean(s)
                } else if let blocks = item["content"] as? [Any] {
                    item["content"] = cleanBlocks(blocks, textTypes: ["input_text", "text"])
                }
                items[i] = item
            }
            body["input"] = items
        }
    }

    /// Drop provider-bound reasoning (Anthropic thinking signatures,
    /// OpenAI encrypted reasoning) that another account cannot verify.
    /// Returns whether anything was removed.
    @discardableResult
    static func stripReasoning(in body: inout JSONObject, api: GatewayAPI) -> Bool {
        var removed = false
        switch api {
        case .anthropic:
            guard var msgs = body["messages"] as? [Any] else { return false }
            for i in msgs.indices {
                guard var m = msgs[i] as? JSONObject, let blocks = m["content"] as? [Any] else { continue }
                let kept = blocks.filter { b in
                    let t = (b as? JSONObject)?["type"] as? String
                    return t != "thinking" && t != "redacted_thinking"
                }
                if kept.count != blocks.count {
                    removed = true
                    m["content"] = kept.isEmpty ? [["type": "text", "text": " "]] : kept
                    msgs[i] = m
                }
            }
            body["messages"] = msgs
            if removed { body.removeValue(forKey: "thinking") }
        case .responses:
            guard let items = body["input"] as? [Any] else { return false }
            let kept = items.filter { ((($0 as? JSONObject)?["type"] as? String) ?? "") != "reasoning" }
            removed = kept.count != items.count
            body["input"] = kept
        case .chat:
            break
        }
        return removed
    }
}

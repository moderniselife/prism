import Foundation

// MARK: - Prism endpoint: configuration
//
// Prism can serve a local OpenAI- and Anthropic-compatible API. Requests are
// sent with the API keys of an *identity* (for example "Work" or
// "Personal"), so a chat can switch whose account pays for it without
// changing app, model or conversation. An identity holds one key per
// provider; the requested model picks which of them is used.
//
// Keys live in the macOS Keychain (GatewayKeychain), never in this file.
// Everything here is Foundation-only so the gateway tests can build it
// without the app.

enum GatewayProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case anthropic
    case openai
    case xai
    case compatible

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .xai: return "xAI"
        case .compatible: return "OpenAI-compatible"
        }
    }

    var detail: String {
        switch self {
        case .anthropic: return "Claude models"
        case .openai: return "GPT and o-series models"
        case .xai: return "Grok models"
        case .compatible: return "Bonsai, Ollama, LM Studio, vLLM or any /v1 server"
        }
    }

    /// Anthropic's base is the host root (paths add /v1/…); the OpenAI
    /// family's base already ends in /v1.
    var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openai: return "https://api.openai.com/v1"
        case .xai: return "https://api.x.ai/v1"
        case .compatible: return ""
        }
    }

    var keyRequired: Bool { self != .compatible }
}

/// One provider account inside an identity.
struct GatewayCredential: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var provider: GatewayProvider
    /// Empty = the provider's default.
    var baseURL: String = ""

    init(provider: GatewayProvider, baseURL: String = "") {
        self.provider = provider
        self.baseURL = baseURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        provider = try c.decodeIfPresent(GatewayProvider.self, forKey: .provider) ?? .compatible
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
    }

    /// Base URL without a trailing slash. A bare host for an OpenAI-style
    /// server gets /v1 appended.
    var effectiveBaseURL: String {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = provider.defaultBaseURL }
        while s.hasSuffix("/") { s.removeLast() }
        if provider == .anthropic {
            if s.hasSuffix("/v1") { s.removeLast(3) }
            return s
        }
        if let url = URL(string: s), url.path.isEmpty || url.path == "/" {
            s += "/v1"
        }
        return s
    }
}

struct GatewayIdentity: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var colorHex: String
    var credentials: [GatewayCredential] = []
    /// Used when a client asks for "prism", "work" or similar without a model.
    var defaultModel: String = ""

    init(name: String, colorHex: String, credentials: [GatewayCredential] = [], defaultModel: String = "") {
        self.name = name
        self.colorHex = colorHex
        self.credentials = credentials
        self.defaultModel = defaultModel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Identity"
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#6366F1"
        credentials = try c.decodeIfPresent([GatewayCredential].self, forKey: .credentials) ?? []
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel) ?? ""
    }

    /// "Work Stuff" → "work-stuff": the model prefix and @tag.
    var slug: String { Self.slugify(name) }

    static func slugify(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        var lastDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastDash = false
            } else if !lastDash && !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}

enum GatewayRuleKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case keyword
    case regex
    case client
    case schedule

    var id: String { rawValue }

    var label: String {
        switch self {
        case .keyword: return "Message mentions"
        case .regex: return "Message matches regex"
        case .client: return "Request comes from app"
        case .schedule: return "Time of day"
        }
    }
}

/// An automatic switch: when it matches, the request uses `identityID`.
struct GatewayRule: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var enabled = true
    var kind: GatewayRuleKind
    /// keyword: comma-separated words; regex: a pattern; client: text the
    /// app's User-Agent contains (e.g. "claude-cli", "codex", "OpenWebUI").
    var pattern: String = ""
    /// schedule: Calendar weekdays (1 = Sunday … 7 = Saturday).
    var days: [Int] = [2, 3, 4, 5, 6]
    /// schedule: minutes after midnight, local time; end may be < start
    /// for a window that crosses midnight.
    var startMinute = 9 * 60
    var endMinute = 17 * 60
    var identityID: String

    init(kind: GatewayRuleKind, pattern: String = "", identityID: String) {
        self.kind = kind
        self.pattern = pattern
        self.identityID = identityID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        kind = try c.decodeIfPresent(GatewayRuleKind.self, forKey: .kind) ?? .keyword
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        days = try c.decodeIfPresent([Int].self, forKey: .days) ?? [2, 3, 4, 5, 6]
        startMinute = try c.decodeIfPresent(Int.self, forKey: .startMinute) ?? 9 * 60
        endMinute = try c.decodeIfPresent(Int.self, forKey: .endMinute) ?? 17 * 60
        identityID = try c.decodeIfPresent(String.self, forKey: .identityID) ?? ""
    }
}

/// Which model ids /v1/models lists.
enum GatewayModelList: String, Codable, CaseIterable, Identifiable, Sendable {
    /// "work/claude-sonnet-4-5" and "claude-sonnet-4-5".
    case both
    /// Only identity-prefixed ids.
    case prefixed
    /// Only plain ids, which follow the active identity and rules.
    case plain

    var id: String { rawValue }

    var label: String {
        switch self {
        case .both: return "Both"
        case .prefixed: return "Per identity"
        case .plain: return "Follow active"
        }
    }
}

struct GatewayConfig: Codable, Equatable, Sendable {
    static let defaultPort = 4848

    var enabled = false
    var port = GatewayConfig.defaultPort
    /// Listen on every interface instead of 127.0.0.1 only.
    var allowLAN = false
    var requireToken = true
    var token = GatewayConfig.newToken()
    var identities: [GatewayIdentity] = []
    var activeIdentityID: String?
    var tagsEnabled = true
    var rules: [GatewayRule] = []
    var modelList: GatewayModelList = .both

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? GatewayConfig.defaultPort
        allowLAN = try c.decodeIfPresent(Bool.self, forKey: .allowLAN) ?? false
        requireToken = try c.decodeIfPresent(Bool.self, forKey: .requireToken) ?? true
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? GatewayConfig.newToken()
        identities = try c.decodeIfPresent([GatewayIdentity].self, forKey: .identities) ?? []
        activeIdentityID = try c.decodeIfPresent(String.self, forKey: .activeIdentityID)
        tagsEnabled = try c.decodeIfPresent(Bool.self, forKey: .tagsEnabled) ?? true
        rules = try c.decodeIfPresent([GatewayRule].self, forKey: .rules) ?? []
        modelList = try c.decodeIfPresent(GatewayModelList.self, forKey: .modelList) ?? .both
    }

    static func newToken() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var rng = SystemRandomNumberGenerator()
        return "prism-" + String((0..<32).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })
    }

    var activeIdentity: GatewayIdentity? {
        identities.first { $0.id == activeIdentityID } ?? identities.first
    }

    func identity(id: String) -> GatewayIdentity? {
        identities.first { $0.id == id }
    }

    // MARK: Persistence

    static var fileURL: URL {
        if let override = ProcessInfo.processInfo.environment["PRISM_ENDPOINT_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Prism", isDirectory: true).appendingPathComponent("endpoint.json")
    }

    static func load(from url: URL = fileURL) -> GatewayConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(GatewayConfig.self, from: data) else {
            return GatewayConfig()
        }
        return config
    }

    func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        // The file holds the local access token: keep it private to the user.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// One line in the endpoint's recent-requests list. No message content.
struct GatewayLogEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let client: String
    let api: String
    let identity: String
    let identityColor: String
    let provider: String
    let model: String
    let reason: String
    let status: Int
    let milliseconds: Int
    let stream: Bool
    let error: String?
}

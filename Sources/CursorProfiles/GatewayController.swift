import AppKit
import Network
import SwiftUI
import UserNotifications

// MARK: - Prism endpoint: app-side state
//
// Owns the server, the saved config and the Keychain writes. The engine
// does the request work off the main thread.

@MainActor
final class GatewayController: ObservableObject {
    static let shared = GatewayController()

    enum ServerState: Equatable {
        case off
        case starting
        case running
        case failed(String)
    }

    @Published private(set) var config: GatewayConfig
    @Published private(set) var state: ServerState = .off
    @Published private(set) var log: [GatewayLogEntry] = []
    /// Credential id → models its key can use.
    @Published private(set) var models: [String: [String]] = [:]
    @Published private(set) var modelErrors: [String: String] = [:]
    /// Credential ids with a key in the Keychain.
    @Published private(set) var storedKeys: Set<String> = []

    /// Identity id → until when it's rate-limited or out of credit.
    @Published private(set) var cooldowns: [String: Date] = [:]
    /// Bumped whenever usage changes, so usage views refresh.
    @Published private(set) var usageVersion = 0

    let engine = GatewayEngine(usage: GatewayUsageStore(fileURL: GatewayUsageStore.defaultURL))
    private var cooldownTimer: Timer?
    private var server: GatewayServer?
    private var runningPort: Int?
    private var runningLAN: Bool?

    private init() {
        config = GatewayConfig.load()
        engine.update(config)
        engine.onLog = { entry in
            Task { @MainActor in GatewayController.shared.append(entry) }
        }
        storedKeys = Set(config.identities.flatMap(\.credentials).map(\.id).filter { GatewayKeychain.exists($0) })
        // Identities from older versions get their own token now: keep it.
        if config.enabled || !config.identities.isEmpty { try? config.save() }
        applyServerState()
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in GatewayController.shared.refreshCooldowns() }
        }
        if config.enabled {
            Task { await refreshAllModels() }
        }
    }

    var baseURL: String { "http://127.0.0.1:\(config.port)" }
    var activeIdentity: GatewayIdentity? { config.activeIdentity }
    var isRunning: Bool { state == .running }

    // MARK: Config

    func update(_ change: (inout GatewayConfig) -> Void) {
        var c = config
        change(&c)
        guard c != config else { return }
        config = c
        do {
            try c.save()
        } catch {
            NSLog("Prism endpoint: couldn't save settings: \(error.localizedDescription)")
        }
        engine.update(c)
        applyServerState()
    }

    func setEnabled(_ on: Bool) {
        update { $0.enabled = on }
        if on { Task { await refreshAllModels() } }
    }

    func setActive(_ id: String) {
        update { $0.activeIdentityID = id }
    }

    /// Next identity, for the shortcut and menu-bar cycling.
    func cycleActive() {
        let ids = config.identities.map(\.id)
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex(of: config.activeIdentity?.id ?? "") ?? -1
        setActive(ids[(current + 1) % ids.count])
    }

    func regenerateToken() {
        update { $0.token = GatewayConfig.newToken() }
    }

    func regenerateToken(identityID: String) {
        update { c in
            if let i = c.identities.firstIndex(where: { $0.id == identityID }) {
                c.identities[i].token = GatewayConfig.newToken()
            }
        }
    }

    // MARK: Usage and limits

    func monthUsage(_ identityID: String) -> UsageTotals {
        engine.usage.month(identityID)
    }

    func todayUsage(_ identityID: String) -> UsageTotals {
        engine.usage.today(identityID)
    }

    func monthByModel(_ identityID: String) -> [(model: String, totals: UsageTotals)] {
        engine.usage.monthByModel(identityID)
    }

    func dailyCost(_ identityID: String) -> [(day: String, cost: Double, tokens: Int)] {
        engine.usage.dailyCost(identityID)
    }

    var unpricedModels: [String] { engine.usage.unpricedModels() }

    func setPrice(_ price: GatewayPrice?, for prefix: String) {
        let key = prefix.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        update { $0.priceOverrides[key] = price }
    }

    func refreshCooldowns() {
        let snap = engine.cooldownSnapshot()
        if snap != cooldowns { cooldowns = snap }
    }

    /// Warn once a month at 80% and 100% of an identity's budget.
    private func checkBudget(_ identityName: String) {
        guard let identity = config.identities.first(where: { $0.name == identityName }),
              let budget = identity.monthlyBudget, budget > 0 else { return }
        let spent = monthUsage(identity.id).cost
        let month = GatewayUsageStore.monthKey(Date())
        for level in [100, 80] where spent >= budget * Double(level) / 100 {
            let key = "endpointBudgetNotice-\(identity.id)-\(month)-\(level)"
            guard !UserDefaults.standard.bool(forKey: key) else { return }
            UserDefaults.standard.set(true, forKey: key)
            let action: String
            switch identity.budgetAction {
            case .warn: action = "Requests continue."
            case .fallback: action = identity.fallbackIdentityID.flatMap { config.identity(id: $0)?.name }.map { "Requests now go to \($0)." } ?? "Requests are stopped."
            case .block: action = "Requests are stopped."
            }
            notify(title: level == 100 ? "\(identity.name) reached its budget" : "\(identity.name) is at 80% of its budget",
                   body: "About $\(GatewayEngine.money(spent)) of $\(GatewayEngine.money(budget)) this month." + (level == 100 ? " " + action : ""))
            return
        }
    }

    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            // Fetch the shared centre here rather than capturing the
            // non-Sendable one from outside the callback.
            UNUserNotificationCenter.current()
                .add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: Profiles

    /// Environment that points a Claude Code profile at the endpoint, or
    /// nil if the profile uses its own sign-in (or the endpoint is off).
    func claudeCodeEnvironment(for setting: String?) -> [String: String]? {
        guard let setting, !setting.isEmpty, config.enabled else { return nil }
        let token: String
        if setting == "*" {
            token = tokenForSnippets
        } else if let identity = config.identity(id: setting) {
            token = identity.token
        } else {
            return nil
        }
        return ["ANTHROPIC_BASE_URL": baseURL, "ANTHROPIC_AUTH_TOKEN": token]
    }

    func restartServer() {
        server?.stop()
        server = nil
        runningPort = nil
        applyServerState()
    }

    // MARK: Identities

    /// Save an identity and any keys typed for it. An empty key leaves the
    /// stored one alone.
    func saveIdentity(_ identity: GatewayIdentity, keys: [String: String]) {
        let previous = config.identity(id: identity.id)
        let kept = Set(identity.credentials.map(\.id))
        for c in previous?.credentials ?? [] where !kept.contains(c.id) {
            GatewayKeychain.delete(c.id)
            engine.setKey(nil, for: c.id)
            storedKeys.remove(c.id)
        }
        for (credID, key) in keys {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if GatewayKeychain.set(trimmed, for: credID) { storedKeys.insert(credID) }
            engine.setKey(trimmed, for: credID)
        }
        update { c in
            if let i = c.identities.firstIndex(where: { $0.id == identity.id }) {
                c.identities[i] = identity
            } else {
                c.identities.append(identity)
            }
            if c.activeIdentityID == nil || c.identity(id: c.activeIdentityID ?? "") == nil {
                c.activeIdentityID = identity.id
            }
        }
        Task { await refreshModels(for: identity) }
    }

    func deleteIdentity(_ id: String) {
        guard let identity = config.identity(id: id) else { return }
        for c in identity.credentials {
            GatewayKeychain.delete(c.id)
            engine.setKey(nil, for: c.id)
            storedKeys.remove(c.id)
        }
        update { c in
            c.identities.removeAll { $0.id == id }
            c.rules.removeAll { $0.identityID == id }
            if c.activeIdentityID == id { c.activeIdentityID = c.identities.first?.id }
        }
    }

    /// Two empty identities to start from.
    func addStarterIdentities() {
        let work = GatewayIdentity(name: "Work", colorHex: "#3B82F6")
        let personal = GatewayIdentity(name: "Personal", colorHex: "#F43F5E")
        update { c in
            c.identities.append(contentsOf: [work, personal])
            if c.activeIdentityID == nil { c.activeIdentityID = work.id }
        }
    }

    func moveIdentity(_ id: String, by offset: Int) {
        update { c in
            guard let i = c.identities.firstIndex(where: { $0.id == id }) else { return }
            let j = i + offset
            guard c.identities.indices.contains(j) else { return }
            c.identities.swapAt(i, j)
        }
    }

    // MARK: Rules

    func saveRule(_ rule: GatewayRule) {
        update { c in
            if let i = c.rules.firstIndex(where: { $0.id == rule.id }) {
                c.rules[i] = rule
            } else {
                c.rules.append(rule)
            }
        }
    }

    func deleteRule(_ id: String) {
        update { $0.rules.removeAll { $0.id == id } }
    }

    func moveRule(_ id: String, by offset: Int) {
        update { c in
            guard let i = c.rules.firstIndex(where: { $0.id == id }) else { return }
            let j = i + offset
            guard c.rules.indices.contains(j) else { return }
            c.rules.swapAt(i, j)
        }
    }

    // MARK: Models

    /// Check a key the user just typed (not yet saved) by listing models.
    func checkCredential(_ credential: GatewayCredential, draftKey: String?) async -> Result<[String], GatewayRouteError> {
        if let draftKey, !draftKey.trimmingCharacters(in: .whitespaces).isEmpty {
            engine.setKey(draftKey.trimmingCharacters(in: .whitespacesAndNewlines), for: credential.id)
        }
        do {
            let list = try await engine.fetchModels(credential)
            models[credential.id] = list
            modelErrors[credential.id] = nil
            return .success(list)
        } catch let e as GatewayRouteError {
            modelErrors[credential.id] = e.message
            return .failure(e)
        } catch {
            let e = GatewayRouteError(status: 0, message: error.localizedDescription)
            modelErrors[credential.id] = e.message
            return .failure(e)
        }
    }

    /// Forget a typed-but-unsaved key (the editor was cancelled).
    func discardDraftKey(_ credentialID: String) {
        engine.setKey(nil, for: credentialID)
    }

    func refreshModels(for identity: GatewayIdentity) async {
        for c in identity.credentials {
            _ = await checkCredential(c, draftKey: nil)
        }
    }

    func refreshAllModels() async {
        for identity in config.identities {
            await refreshModels(for: identity)
        }
    }

    func models(for identity: GatewayIdentity) -> [String] {
        var seen = Set<String>()
        return identity.credentials.flatMap { models[$0.id] ?? [] }.filter { seen.insert($0).inserted }
    }

    // MARK: Log

    private func append(_ entry: GatewayLogEntry) {
        log.insert(entry, at: 0)
        if log.count > 100 { log.removeLast(log.count - 100) }
        usageVersion += 1
        refreshCooldowns()
        if entry.cost != nil { checkBudget(entry.identity) }
    }

    func clearLog() {
        log.removeAll()
    }

    // MARK: Server

    private func applyServerState() {
        guard config.enabled else {
            server?.stop()
            server = nil
            runningPort = nil
            runningLAN = nil
            state = .off
            return
        }
        if server != nil, runningPort == config.port, runningLAN == config.allowLAN { return }
        server?.stop()
        let engine = self.engine
        let s = GatewayServer { req, w in await engine.handle(req, w) }
        let port = config.port
        state = .starting
        do {
            try s.start(port: port, allowLAN: config.allowLAN) { [weak self] st in
                Task { @MainActor in self?.listenerChanged(st, port: port) }
            }
            server = s
            runningPort = config.port
            runningLAN = config.allowLAN
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func listenerChanged(_ st: NWListener.State, port: Int) {
        guard port == runningPort else { return }
        switch st {
        case .ready:
            state = .running
        case .failed(let e), .waiting(let e):
            if case .posix(let code) = e, code == .EADDRINUSE {
                state = .failed("Port \(port) is already in use. Pick another port.")
            } else {
                state = .failed(e.localizedDescription)
            }
            server?.stop()
            server = nil
            runningPort = nil
        default:
            break
        }
    }

    // MARK: Setup snippets

    var tokenForSnippets: String { config.requireToken || config.allowLAN ? config.token : "prism" }

    /// The token the setup snippets show: any identity, or one pinned.
    @Published var snippetIdentityID: String?

    private var snippetToken: String {
        snippetIdentityID.flatMap { config.identity(id: $0)?.token } ?? tokenForSnippets
    }

    var chatAppsSnippet: String {
        """
        Base URL   \(baseURL)/v1
        API key    \(snippetToken)
        Model      prism  (follows the active identity)
                   or work/…, personal/… to pin one

        Open WebUI in Docker: http://host.docker.internal:\(config.port)/v1
        """
    }

    var claudeCodeSnippet: String {
        """
        export ANTHROPIC_BASE_URL=\(baseURL)
        export ANTHROPIC_AUTH_TOKEN=\(snippetToken)
        """
    }

    var codexSnippet: String {
        let model = config.activeIdentity?.defaultModel.isEmpty == false ? config.activeIdentity!.defaultModel : "gpt-5-codex"
        return """
        # ~/.codex/config.toml
        model = "\(model)"
        model_provider = "prism"

        [model_providers.prism]
        name = "Prism"
        base_url = "\(baseURL)/v1"
        env_key = "PRISM_API_KEY"
        wire_api = "responses"

        # and in your shell profile:
        export PRISM_API_KEY=\(snippetToken)
        """
    }

    var claudeDesktopSnippet: String {
        """
        Developer → Configure Third-Party Inference…
        Inference provider   Gateway
        Gateway base URL     \(baseURL)
        Gateway API key      \(snippetToken)
        Gateway auth scheme  Bearer
        """
    }

    var sdkSnippet: String {
        """
        # OpenAI SDK
        OpenAI(base_url="\(baseURL)/v1", api_key="\(snippetToken)")

        # Anthropic SDK
        Anthropic(base_url="\(baseURL)", api_key="\(snippetToken)")
        """
    }
}

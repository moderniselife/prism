import AppKit
import SwiftUI

// MARK: - Settings → Endpoint

@MainActor
struct EndpointSettingsView: View {
    @ObservedObject private var gateway = GatewayController.shared

    @State private var editingIdentity: GatewayIdentity?
    @State private var editingRule: GatewayRule?
    @State private var showToken = false
    @State private var portText = ""

    private var config: GatewayConfig { gateway.config }

    var body: some View {
        Form {
            serverSection
            identitiesSection
            if !config.identities.isEmpty {
                switchingSection
                // Spend stays visible with the server off.
                usageSection
            }
            if config.enabled {
                connectSection
                activitySection
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(item: $editingIdentity) { identity in
            IdentityEditorSheet(identity: identity,
                                isNew: config.identity(id: identity.id) == nil,
                                onClose: { editingIdentity = nil })
        }
        .sheet(item: $editingRule) { rule in
            RuleEditorSheet(rule: rule,
                            isNew: !config.rules.contains { $0.id == rule.id },
                            onClose: { editingRule = nil })
        }
        .onAppear { portText = "\(config.port)" }
    }

    // MARK: Server

    private var serverSection: some View {
        Section {
            Toggle(isOn: Binding(get: { config.enabled }, set: { gateway.setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Serve an OpenAI- and Anthropic-compatible API")
                    Text("Point any app at Prism. Each request goes out with the API keys of the identity you choose, so one chat can switch between work and personal.")
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if config.enabled {
                LabeledContent("Status") { statusView }
                LabeledContent("Address") {
                    HStack(spacing: 6) {
                        Text("\(gateway.baseURL)/v1")
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                        CopyButton(text: "\(gateway.baseURL)/v1")
                    }
                }
                LabeledContent("Port") {
                    HStack(spacing: 6) {
                        TextField("", text: $portText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .onSubmit(applyPort)
                        if portText != "\(config.port)" {
                            Button("Apply", action: applyPort)
                        }
                    }
                }
                LabeledContent("Access token") {
                    HStack(spacing: 6) {
                        Text(showToken ? config.token : String(repeating: "•", count: 18))
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                        Button {
                            showToken.toggle()
                        } label: {
                            Image(systemName: showToken ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(showToken ? "Hide" : "Show")
                        CopyButton(text: config.token)
                        Button("New") { gateway.regenerateToken() }
                            .help("Make a new token. Apps using the old one stop working.")
                    }
                }
                Toggle("Require the token", isOn: Binding(get: { config.requireToken || config.allowLAN },
                                                         set: { v in gateway.update { $0.requireToken = v } }))
                    .disabled(config.allowLAN)
                Toggle(isOn: Binding(get: { config.allowLAN }, set: { v in gateway.update { $0.allowLAN = v } })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Allow other devices on my network")
                        Text("Anyone on your network with the token can spend your keys. The token is always required when this is on.")
                            .font(.system(size: 11))
                            .foregroundStyle(PrismTheme.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } header: {
            Text("Endpoint")
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch gateway.state {
        case .running:
            HStack(spacing: 6) {
                Circle().fill(PrismTheme.Colors.live).frame(width: 7, height: 7)
                Text(config.allowLAN ? "Running on your network" : "Running on this Mac")
                    .foregroundStyle(PrismTheme.Colors.textSecondary)
            }
        case .starting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Starting…").foregroundStyle(PrismTheme.Colors.textTertiary)
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PrismTheme.Colors.amber)
                Text(message)
                    .foregroundStyle(PrismTheme.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") { gateway.restartServer() }
            }
        case .off:
            Text("Off").foregroundStyle(PrismTheme.Colors.textTertiary)
        }
    }

    private func applyPort() {
        guard let p = Int(portText.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(p) else {
            portText = "\(config.port)"
            return
        }
        gateway.update { $0.port = p }
    }

    // MARK: Identities

    private var identitiesSection: some View {
        Section {
            if config.identities.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Add an identity for each account you switch between. Each one holds your API keys for Anthropic, OpenAI, xAI or a local server.")
                        .font(.system(size: 12))
                        .foregroundStyle(PrismTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Add Work and Personal") { gateway.addStarterIdentities() }
                        Button("Add Identity…") { editingIdentity = newIdentity() }
                    }
                }
                .padding(.vertical, 4)
            } else {
                if config.identities.count > 1 {
                    LabeledContent("Active") {
                        IdentityPicker(compact: false)
                    }
                }
                ForEach(config.identities) { identity in
                    identityRow(identity)
                }
                HStack {
                    Button("Add Identity…") { editingIdentity = newIdentity() }
                    Spacer()
                    Button("Refresh Models") { Task { await gateway.refreshAllModels() } }
                }
            }
        } header: {
            Text("Identities")
        }
    }

    /// "Rate-limited until 13:42 → using Personal" / "Over budget".
    private func limitStatus(_ identity: GatewayIdentity) -> String? {
        _ = gateway.usageVersion
        let fallback = identity.fallbackIdentityID.flatMap { config.identity(id: $0)?.name }
        if let budget = identity.monthlyBudget, budget > 0, gateway.monthUsage(identity.id).cost >= budget {
            switch identity.budgetAction {
            case .warn: return "Over its $\(GatewayEngine.money(budget)) budget this month"
            case .fallback: return "Over budget" + (fallback.map { " → using \($0)" } ?? " → stopped")
            case .block: return "Over budget → stopped"
            }
        }
        if let until = gateway.cooldowns[identity.id] {
            return "Rate-limited until \(GatewayEngine.clock(until))" + (fallback.map { " → using \($0)" } ?? "")
        }
        return nil
    }

    private func newIdentity() -> GatewayIdentity {
        let used = Set(config.identities.map(\.colorHex))
        let color = AccentPalette.all.first { !used.contains($0.hex) }?.hex ?? AccentPalette.random().hex
        return GatewayIdentity(name: "", colorHex: color)
    }

    private func identityRow(_ identity: GatewayIdentity) -> some View {
        let isActive = identity.id == config.activeIdentity?.id
        let providers = identity.credentials.map { c -> String in
            let hasKey = gateway.storedKeys.contains(c.id) || !c.provider.keyRequired
            return hasKey ? c.provider.label : "\(c.provider.label) (no key)"
        }
        return HStack(spacing: 10) {
            Circle()
                .fill(Color(hex: identity.colorHex) ?? .accentColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(identity.name).font(.system(size: 13, weight: .medium))
                    Text("@\(identity.slug)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                    if isActive {
                        Text("Active")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(PrismTheme.Colors.accentText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(PrismTheme.Colors.accent.opacity(0.12), in: Capsule())
                    }
                }
                Text(providers.isEmpty ? "No providers yet" : providers.joined(separator: " · ")
                     + (identity.defaultModel.isEmpty ? "" : " · default \(identity.defaultModel)"))
                    .font(.system(size: 11))
                    .foregroundStyle(providers.isEmpty ? PrismTheme.Colors.amber : PrismTheme.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let status = limitStatus(identity) {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.Colors.amber)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button("Edit…") { editingIdentity = identity }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Make Active") { gateway.setActive(identity.id) }
            Button("Move Up") { gateway.moveIdentity(identity.id, by: -1) }
            Button("Move Down") { gateway.moveIdentity(identity.id, by: 1) }
        }
    }

    // MARK: Switching

    private var switchingSection: some View {
        Section {
            Toggle(isOn: Binding(get: { config.tagsEnabled }, set: { v in gateway.update { $0.tagsEnabled = v } })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Switch with @tags")
                    Text("Type \(config.identities.prefix(2).map { "@\($0.slug)" }.joined(separator: " or ")) in a message. It applies from then on in that chat, and Prism removes the tag before sending.")
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Picker("Models listed for apps", selection: Binding(get: { config.modelList },
                                                                set: { v in gateway.update { $0.modelList = v } })) {
                ForEach(GatewayModelList.allCases) { Text($0.label).tag($0) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Rules")
                Text("Checked in order when a request has no @tag or identity in its model name. Without a match, the active identity answers.")
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(config.rules.enumerated()), id: \.element.id) { index, rule in
                ruleRow(rule, index: index)
            }
            Menu("Add Rule") {
                ForEach(GatewayRuleKind.allCases) { kind in
                    Button(kind.label) {
                        editingRule = GatewayRule(kind: kind,
                                                  identityID: config.identities.first { $0.id != config.activeIdentity?.id }?.id
                                                      ?? config.identities[0].id)
                    }
                }
            }
            .fixedSize()
        } header: {
            Text("Switching")
        }
    }

    private func ruleRow(_ rule: GatewayRule, index: Int) -> some View {
        let identity = config.identity(id: rule.identityID)
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { v in
                var r = rule
                r.enabled = v
                gateway.saveRule(r)
            }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(RuleText.summary(rule))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 5) {
                    Text("→")
                    Circle().fill(Color(hex: identity?.colorHex ?? "") ?? .gray).frame(width: 7, height: 7)
                    Text(identity?.name ?? "Missing identity")
                }
                .font(.system(size: 11))
                .foregroundStyle(PrismTheme.Colors.textTertiary)
            }
            .opacity(rule.enabled ? 1 : 0.5)
            Spacer(minLength: 8)
            Button {
                gateway.moveRule(rule.id, by: -1)
            } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .help("Check earlier")
            Button {
                gateway.moveRule(rule.id, by: 1)
            } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(index == config.rules.count - 1)
                .help("Check later")
            Button("Edit…") { editingRule = rule }
        }
    }

    // MARK: Usage

    private var usageSection: some View {
        Section {
            ForEach(config.identities) { identity in
                UsageRow(identity: identity)
            }
            let unpriced = gateway.unpricedModels
            if !unpriced.isEmpty {
                Text("No price for \(unpriced.prefix(3).joined(separator: ", "))\(unpriced.count > 3 ? " and \(unpriced.count - 3) more" : "") — their tokens are counted but not costed. Add prices below.")
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PriceList()
        } header: {
            Text("This month")
        } footer: {
            Text("Estimated from list prices, before discounts, surcharges and tool fees. Your local servers count as free unless you give them a price.")
                .font(.system(size: 11))
                .foregroundStyle(PrismTheme.Colors.textTertiary)
        }
    }

    // MARK: Connect apps

    private var connectSection: some View {
        Section {
            Picker("Token in these snippets", selection: Binding(get: { gateway.snippetIdentityID ?? "" },
                                                                set: { gateway.snippetIdentityID = $0.isEmpty ? nil : $0 })) {
                Text("Any identity (follows the switch)").tag("")
                ForEach(config.identities) { identity in
                    Text("Always \(identity.name)").tag(identity.id)
                }
            }
            if gateway.snippetIdentityID != nil {
                Text("This token pins the app to one identity — handy for apps that keep a single setting, like Claude Desktop. @tags still work.")
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SnippetDisclosure(title: "Chat apps",
                              detail: "Open WebUI, LibreChat, TypingMind, BoltAI, Msty, Chatbox: add an OpenAI-compatible connection.",
                              snippet: gateway.chatAppsSnippet)
            SnippetDisclosure(title: "Claude Code",
                              detail: "Add to your shell profile, or to a profile's environment.",
                              snippet: gateway.claudeCodeSnippet)
            SnippetDisclosure(title: "Codex",
                              detail: "Codex talks the Responses API; Prism translates it for Claude, Grok and local models too.",
                              snippet: gateway.codexSnippet)
            SnippetDisclosure(title: "Claude Desktop",
                              detail: "Claude Desktop lists models whose ids contain “claude”.",
                              snippet: gateway.claudeDesktopSnippet)
            SnippetDisclosure(title: "SDKs and scripts",
                              detail: "Any OpenAI or Anthropic client library.",
                              snippet: gateway.sdkSnippet)
        } header: {
            Text("Connect apps")
        }
    }

    // MARK: Activity

    private var activitySection: some View {
        Section {
            if gateway.log.isEmpty {
                Text("Requests appear here with the identity that answered them.")
                    .font(.system(size: 12))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
            } else {
                ForEach(gateway.log.prefix(15)) { entry in
                    LogRow(entry: entry)
                }
                Button("Clear") { gateway.clearLog() }
            }
        } header: {
            Text("Recent requests")
        }
    }
}

// MARK: - Pieces

/// Work | Personal | … — used in Settings, the sidebar and the menu bar.
@MainActor
struct IdentityPicker: View {
    @ObservedObject private var gateway = GatewayController.shared
    var compact: Bool

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            ForEach(gateway.config.identities) { identity in
                let selected = identity.id == gateway.activeIdentity?.id
                Button {
                    gateway.setActive(identity.id)
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color(hex: identity.colorHex) ?? .accentColor)
                            .frame(width: 7, height: 7)
                        Text(identity.name)
                            .font(.system(size: compact ? 11 : 12, weight: selected ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .foregroundStyle(selected ? PrismTheme.Colors.textPrimary : PrismTheme.Colors.textSecondary)
                    .padding(.horizontal, compact ? 7 : 9)
                    .frame(height: compact ? 22 : 26)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? PrismTheme.Colors.surfaceHigh : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(selected ? PrismTheme.Colors.borderMed : PrismTheme.Colors.border, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Send requests with \(identity.name)'s keys")
            }
        }
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .frame(width: 14)
        }
        .buttonStyle(.borderless)
        .help("Copy")
    }
}

private struct SnippetDisclosure: View {
    let title: String
    let detail: String
    let snippet: String
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 8) {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                ZStack(alignment: .topTrailing) {
                    Text(snippet)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .padding(.trailing, 24)
                        .background(PrismTheme.Colors.surfaceAlt, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    CopyButton(text: snippet).padding(8)
                }
            }
            .padding(.top, 6)
        } label: {
            Text(title)
        }
    }
}

private struct LogRow: View {
    let entry: GatewayLogEntry

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.time.string(from: entry.date))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(PrismTheme.Colors.textTertiary)
            Circle()
                .fill(Color(hex: entry.identityColor) ?? .gray)
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.identity) · \(entry.model)")
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(entry.error != nil ? PrismTheme.Colors.red : (entry.note != nil ? PrismTheme.Colors.amber : PrismTheme.Colors.textTertiary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Text("\(entry.status)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(entry.status < 400 ? PrismTheme.Colors.emerald : PrismTheme.Colors.red)
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let note = entry.note { parts.append(note) }
        if let e = entry.error {
            parts.append(e)
            return parts.joined(separator: " · ")
        }
        parts += [entry.client, entry.api, entry.provider]
        if !entry.reason.isEmpty { parts.append("via \(entry.reason)") }
        if entry.inputTokens + entry.outputTokens > 0 {
            parts.append("\(Format.tokens(entry.inputTokens)) in / \(Format.tokens(entry.outputTokens)) out")
        }
        if let cost = entry.cost, cost > 0 { parts.append(Format.dollars(cost)) }
        parts.append("\(entry.milliseconds) ms")
        return parts.joined(separator: " · ")
    }
}

enum RuleText {
    static let dayLetters = ["S", "M", "T", "W", "T", "F", "S"]

    static func time(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    static func summary(_ rule: GatewayRule) -> String {
        let p = rule.pattern.trimmingCharacters(in: .whitespaces)
        switch rule.kind {
        case .keyword: return p.isEmpty ? "Message mentions …" : "Message mentions \(p)"
        case .regex: return p.isEmpty ? "Message matches …" : "Message matches /\(p)/"
        case .client: return p.isEmpty ? "Request from …" : "Request from \(p)"
        case .schedule:
            let days = (1...7).filter { rule.days.contains($0) }
            let dayText: String
            if days == [2, 3, 4, 5, 6] {
                dayText = "Weekdays"
            } else if days.count == 7 {
                dayText = "Every day"
            } else if days == [1, 7] {
                dayText = "Weekends"
            } else {
                let names = Calendar.current.shortWeekdaySymbols
                dayText = days.map { names[$0 - 1] }.joined(separator: ", ")
            }
            return "\(dayText) \(time(rule.startMinute))–\(time(rule.endMinute))"
        }
    }
}

// MARK: - Identity editor

@MainActor
struct IdentityEditorSheet: View {
    @ObservedObject private var gateway = GatewayController.shared
    let isNew: Bool
    let onClose: () -> Void

    @State private var identity: GatewayIdentity
    @State private var keys: [String: String] = [:]
    @State private var checking: Set<String> = []
    @State private var checkResult: [String: String] = [:]
    @State private var confirmDelete = false

    init(identity: GatewayIdentity, isNew: Bool, onClose: @escaping () -> Void) {
        _identity = State(initialValue: identity)
        self.isNew = isNew
        self.onClose = onClose
    }

    private var nameTaken: Bool {
        let slug = identity.slug
        return gateway.config.identities.contains { $0.id != identity.id && $0.slug == slug }
    }

    private var canSave: Bool {
        !identity.name.trimmingCharacters(in: .whitespaces).isEmpty && !identity.slug.isEmpty && !nameTaken
    }

    private var availableModels: [String] {
        var seen = Set<String>()
        return identity.credentials.flatMap { gateway.models[$0.id] ?? [] }.filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "New identity" : "Edit \(identity.name)")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 6)

            Form {
                Section {
                    TextField("Name", text: $identity.name, prompt: Text("Work"))
                    if nameTaken {
                        Text("Another identity already uses @\(identity.slug).")
                            .font(.system(size: 11))
                            .foregroundStyle(PrismTheme.Colors.red)
                    } else if !identity.slug.isEmpty {
                        Text("Model prefix \(identity.slug)/…   Tag @\(identity.slug)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(PrismTheme.Colors.textTertiary)
                    }
                    LabeledContent("Color") {
                        HStack(spacing: 6) {
                            ForEach(AccentPalette.all) { p in
                                Circle()
                                    .fill(p.color)
                                    .frame(width: 16, height: 16)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(identity.colorHex == p.hex ? 0.7 : 0), lineWidth: 2))
                                    .onTapGesture { identity.colorHex = p.hex }
                                    .help(p.name)
                            }
                        }
                    }
                }

                Section {
                    if identity.credentials.isEmpty {
                        Text("Add the providers this identity has API keys for.")
                            .font(.system(size: 12))
                            .foregroundStyle(PrismTheme.Colors.textTertiary)
                    }
                    ForEach($identity.credentials) { $cred in
                        credentialRow($cred)
                    }
                    Menu("Add Provider") {
                        ForEach(GatewayProvider.allCases) { p in
                            Button("\(p.label) — \(p.detail)") {
                                identity.credentials.append(GatewayCredential(provider: p))
                            }
                            .disabled(p != .compatible && identity.credentials.contains { $0.provider == p })
                        }
                    }
                    .fixedSize()
                } header: {
                    Text("Providers")
                } footer: {
                    Text("Keys are stored in your macOS Keychain. Claude Pro/Max and ChatGPT sign-ins can't be used here — providers only allow those in their own apps.")
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                }

                Section {
                    Picker("Fall back to", selection: Binding(get: { identity.fallbackIdentityID ?? "" },
                                                              set: { identity.fallbackIdentityID = $0.isEmpty ? nil : $0 })) {
                        Text("Nothing — show the error").tag("")
                        ForEach(gateway.config.identities.filter { $0.id != identity.id }) { other in
                            Text(other.name).tag(other.id)
                        }
                    }
                    HStack(spacing: 6) {
                        Text("Monthly budget")
                        Spacer()
                        Text("$").foregroundStyle(PrismTheme.Colors.textTertiary)
                        TextField("", text: Binding(get: { identity.monthlyBudget.map { GatewayEngine.money($0) } ?? "" },
                                                    set: { identity.monthlyBudget = Double($0.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil } }),
                                  prompt: Text("No limit"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .labelsHidden()
                    }
                    if identity.monthlyBudget != nil {
                        Picker("When it's reached", selection: $identity.budgetAction) {
                            ForEach(GatewayBudgetAction.allCases) { Text($0.label).tag($0) }
                        }
                    }
                } header: {
                    Text("Limits")
                } footer: {
                    Text("When this identity is rate-limited or out of credit, requests move to the fallback until it recovers. Budgets are estimates and reset each month.")
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                }

                if !isNew {
                    Section {
                        LabeledContent("Token") {
                            HStack(spacing: 6) {
                                Text(String(identity.token.prefix(12)) + "…")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(PrismTheme.Colors.textSecondary)
                                CopyButton(text: identity.token)
                                Button("New") { identity.token = GatewayConfig.newToken() }
                            }
                        }
                    } footer: {
                        Text("Apps using this token always get \(identity.name.isEmpty ? "this identity" : identity.name), whatever the switch says.")
                            .font(.system(size: 11))
                            .foregroundStyle(PrismTheme.Colors.textTertiary)
                    }
                }

                Section {
                    HStack(spacing: 6) {
                        TextField("Default model", text: $identity.defaultModel, prompt: Text("claude-sonnet-4-5"))
                        if !availableModels.isEmpty {
                            Menu {
                                ForEach(availableModels, id: \.self) { m in
                                    Button(m) { identity.defaultModel = m }
                                }
                            } label: {
                                Image(systemName: "list.bullet")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Choose from this identity's models")
                        }
                    }
                } footer: {
                    Text("Used when an app asks for “prism” or “\(identity.slug.isEmpty ? "work" : identity.slug)” instead of a specific model.")
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if !isNew {
                    Button("Delete Identity…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Identity" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 680)
        .confirmationDialog("Delete \(identity.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                gateway.deleteIdentity(identity.id)
                onClose()
            }
        } message: {
            Text("Its keys are removed from the Keychain, along with any rules that switch to it.")
        }
    }

    private func credentialRow(_ cred: Binding<GatewayCredential>) -> some View {
        let c = cred.wrappedValue
        let stored = gateway.storedKeys.contains(c.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(c.provider.label).font(.system(size: 13, weight: .medium))
                Text(c.provider.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                    .lineLimit(1)
                Spacer()
                Button {
                    identity.credentials.removeAll { $0.id == c.id }
                    keys[c.id] = nil
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove \(c.provider.label)")
            }
            if c.provider == .compatible {
                TextField("Server URL", text: cred.baseURL, prompt: Text("Server URL, e.g. http://bonsai.local:8080/v1"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            HStack(spacing: 6) {
                SecureField("API key", text: Binding(get: { keys[c.id] ?? "" }, set: { keys[c.id] = $0 }),
                            prompt: Text(stored ? "Saved in Keychain — type to replace" : (c.provider.keyRequired ? "API key" : "API key (optional)")))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Button {
                    check(c)
                } label: {
                    if checking.contains(c.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Check")
                    }
                }
                .disabled(checking.contains(c.id) || (c.provider == .compatible && c.baseURL.isEmpty)
                          || (c.provider.keyRequired && !stored && (keys[c.id] ?? "").isEmpty))
            }
            if let result = checkResult[c.id] {
                Text(result)
                    .font(.system(size: 11))
                    .foregroundStyle(result.hasPrefix("✓") ? PrismTheme.Colors.emerald : PrismTheme.Colors.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func check(_ c: GatewayCredential) {
        checking.insert(c.id)
        checkResult[c.id] = nil
        Task {
            let result = await gateway.checkCredential(c, draftKey: keys[c.id])
            checking.remove(c.id)
            switch result {
            case .success(let models):
                checkResult[c.id] = "✓ Works — \(models.count) model\(models.count == 1 ? "" : "s")"
                if identity.defaultModel.isEmpty, let first = preferredDefault(models) {
                    identity.defaultModel = first
                }
            case .failure(let e):
                checkResult[c.id] = e.message
            }
        }
    }

    /// A sensible default from a fresh model list.
    private func preferredDefault(_ models: [String]) -> String? {
        let prefs = ["claude-sonnet", "gpt-5", "grok-4", "claude"]
        for p in prefs {
            if let m = models.filter({ $0.hasPrefix(p) }).sorted(by: >).first { return m }
        }
        return models.first
    }

    private func cancel() {
        for c in identity.credentials where keys[c.id] != nil {
            gateway.discardDraftKey(c.id)
        }
        onClose()
    }

    private func save() {
        identity.name = identity.name.trimmingCharacters(in: .whitespaces)
        identity.defaultModel = identity.defaultModel.trimmingCharacters(in: .whitespaces)
        gateway.saveIdentity(identity, keys: keys)
        onClose()
    }
}

// MARK: - Rule editor

@MainActor
struct RuleEditorSheet: View {
    @ObservedObject private var gateway = GatewayController.shared
    let isNew: Bool
    let onClose: () -> Void
    @State private var rule: GatewayRule

    init(rule: GatewayRule, isNew: Bool, onClose: @escaping () -> Void) {
        _rule = State(initialValue: rule)
        self.isNew = isNew
        self.onClose = onClose
    }

    private var regexError: String? {
        guard rule.kind == .regex, !rule.pattern.isEmpty else { return nil }
        do {
            _ = try NSRegularExpression(pattern: rule.pattern)
            return nil
        } catch {
            return "Not a valid regular expression."
        }
    }

    private var canSave: Bool {
        (rule.kind == .schedule ? !rule.days.isEmpty : !rule.pattern.trimmingCharacters(in: .whitespaces).isEmpty)
            && regexError == nil && gateway.config.identity(id: rule.identityID) != nil
    }

    /// Clients seen recently, to fill in a client rule.
    private var recentClients: [String] {
        var seen = Set<String>()
        return gateway.log.map(\.client).filter { $0 != "unknown" && seen.insert($0).inserted }.prefix(6).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "New rule" : "Edit rule").font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 6)

            Form {
                Section {
                    Picker("When", selection: $rule.kind) {
                        ForEach(GatewayRuleKind.allCases) { Text($0.label).tag($0) }
                    }
                    switch rule.kind {
                    case .keyword:
                        TextField("Words", text: $rule.pattern, prompt: Text("invoice, standup, Acme"))
                        hint("Any of these words in your latest message, as whole words, ignoring case.")
                    case .regex:
                        TextField("Pattern", text: $rule.pattern, prompt: Text("(?i)\\bticket-\\d+"))
                            .font(.system(size: 12, design: .monospaced))
                        if let regexError {
                            hint(regexError, color: PrismTheme.Colors.red)
                        } else {
                            hint("Tested against your latest message, ignoring case.")
                        }
                    case .client:
                        TextField("App", text: $rule.pattern, prompt: Text("codex, claude-cli, OpenWebUI"))
                        hint("Matches the app's User-Agent. Separate several with commas.")
                        if !recentClients.isEmpty {
                            HStack(spacing: 6) {
                                Text("Seen:").font(.system(size: 11)).foregroundStyle(PrismTheme.Colors.textTertiary)
                                ForEach(recentClients, id: \.self) { c in
                                    Button(c) {
                                        let existing = rule.pattern.trimmingCharacters(in: .whitespaces)
                                        rule.pattern = existing.isEmpty ? c : existing + ", " + c
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    case .schedule:
                        LabeledContent("Days") {
                            HStack(spacing: 4) {
                                ForEach(1...7, id: \.self) { d in
                                    let on = rule.days.contains(d)
                                    Button {
                                        if on { rule.days.removeAll { $0 == d } } else { rule.days.append(d) }
                                    } label: {
                                        Text(RuleText.dayLetters[d - 1])
                                            .font(.system(size: 11, weight: .medium))
                                            .frame(width: 24, height: 22)
                                            .foregroundStyle(on ? Color.white : PrismTheme.Colors.textSecondary)
                                            .background(RoundedRectangle(cornerRadius: 5).fill(on ? PrismTheme.Colors.accent : PrismTheme.Colors.surfaceAlt))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        DatePicker("From", selection: timeBinding(\.startMinute), displayedComponents: .hourAndMinute)
                        DatePicker("Until", selection: timeBinding(\.endMinute), displayedComponents: .hourAndMinute)
                        hint(rule.endMinute <= rule.startMinute ? "Runs overnight, past midnight." : "Local time on this Mac.")
                    }
                }
                Section {
                    Picker("Use", selection: $rule.identityID) {
                        ForEach(gateway.config.identities) { identity in
                            Text(identity.name).tag(identity.id)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if !isNew {
                    Button("Delete Rule", role: .destructive) {
                        gateway.deleteRule(rule.id)
                        onClose()
                    }
                }
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Rule" : "Save") {
                    rule.pattern = rule.pattern.trimmingCharacters(in: .whitespaces)
                    gateway.saveRule(rule)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 500, height: 430)
    }

    private func hint(_ text: String, color: Color = PrismTheme.Colors.textTertiary) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func timeBinding(_ key: WritableKeyPath<GatewayRule, Int>) -> Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: rule[keyPath: key] / 60, minute: rule[keyPath: key] % 60, second: 0, of: Date()) ?? Date()
        } set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            rule[keyPath: key] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
    }
}

// MARK: - Sidebar card

/// The endpoint at a glance, with the identity switch, above the
/// second-brain card in the hub sidebar.
@MainActor
struct EndpointCard: View {
    @ObservedObject private var gateway = GatewayController.shared

    private var on: Bool { gateway.config.enabled && gateway.isRunning }

    private var detail: String {
        switch gateway.state {
        case .off: return "Off — one API for all your accounts"
        case .starting: return "Starting…"
        case .failed(let m): return m
        case .running:
            guard let active = gateway.activeIdentity else { return "Add an identity in Settings" }
            _ = gateway.usageVersion
            let spent = gateway.monthUsage(active.id)
            if spent.requests > 0 {
                return "\(active.name) · \(Format.dollars(spent.cost)) this month"
            }
            return "127.0.0.1:\(gateway.config.port)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { PrismSettings.open(.endpoint) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 12))
                            .foregroundStyle(PrismTheme.Colors.textSecondary)
                        Text("Endpoint")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(PrismTheme.Colors.textPrimary)
                        Spacer(minLength: 4)
                        Circle()
                            .fill(on ? PrismTheme.Colors.live : PrismTheme.Colors.textMuted)
                            .frame(width: 6, height: 6)
                        Text(on ? "On" : "Off")
                            .font(.system(size: 11))
                            .foregroundStyle(PrismTheme.Colors.textTertiary)
                    }
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Endpoint settings")

            if on && gateway.config.identities.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    IdentityPicker(compact: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PrismTheme.Colors.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(PrismTheme.Colors.border, lineWidth: 1))
    }
}


// MARK: - Usage pieces

private struct UsageRow: View {
    @ObservedObject private var gateway = GatewayController.shared
    let identity: GatewayIdentity
    @State private var open = false

    var body: some View {
        let _ = gateway.usageVersion
        let month = gateway.monthUsage(identity.id)
        let today = gateway.todayUsage(identity.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: identity.colorHex) ?? .accentColor).frame(width: 8, height: 8)
                Text(identity.name).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(Format.dollars(month.cost))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                if let budget = identity.monthlyBudget {
                    Text("of $\(GatewayEngine.money(budget))")
                        .font(.system(size: 12))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                }
                Button {
                    open.toggle()
                } label: {
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(month.requests == 0)
            }
            if let budget = identity.monthlyBudget, budget > 0 {
                BudgetBar(fraction: month.cost / budget, color: Color(hex: identity.colorHex) ?? .accentColor)
            }
            Text("\(month.requests) request\(month.requests == 1 ? "" : "s") · \(Format.tokens(month.input + month.cacheRead + month.cacheWrite)) in · \(Format.tokens(month.output)) out · today \(Format.dollars(today.cost))")
                .font(.system(size: 11))
                .foregroundStyle(PrismTheme.Colors.textTertiary)
            if open {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(gateway.monthByModel(identity.id).prefix(8), id: \.model) { row in
                        HStack {
                            Text(row.model)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("\(Format.tokens(row.totals.tokens)) tok")
                                .foregroundStyle(PrismTheme.Colors.textTertiary)
                            Text(row.totals.unpriced > 0 && row.totals.cost == 0 ? "—" : Format.dollars(row.totals.cost))
                                .frame(width: 64, alignment: .trailing)
                        }
                        .font(.system(size: 11))
                        .monospacedDigit()
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct BudgetBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(PrismTheme.Colors.surfaceHigh)
                Capsule()
                    .fill(fraction >= 1 ? PrismTheme.Colors.red : (fraction >= 0.8 ? PrismTheme.Colors.amber : color))
                    .frame(width: max(4, geo.size.width * min(fraction, 1)))
            }
        }
        .frame(height: 5)
    }
}

/// Your own prices, over the built-in list.
private struct PriceList: View {
    @ObservedObject private var gateway = GatewayController.shared
    @State private var open = false
    @State private var newPrefix = ""
    @State private var newInput = ""
    @State private var newOutput = ""
    @State private var newCache = ""

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Prices are US dollars per million tokens and match the start of a model id, so “gpt-5.4” covers gpt-5.4-2026-03-01. Yours override the built-in list.")
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(gateway.config.priceOverrides.keys.sorted(), id: \.self) { prefix in
                    let p = gateway.config.priceOverrides[prefix]!
                    HStack {
                        Text(prefix).font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Text("in $\(fmt(p.input)) · out $\(fmt(p.output)) · cached $\(fmt(p.cacheRead))")
                            .font(.system(size: 11))
                            .foregroundStyle(PrismTheme.Colors.textSecondary)
                        Button {
                            gateway.setPrice(nil, for: prefix)
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack(spacing: 6) {
                    TextField("Model id or prefix", text: $newPrefix)
                    TextField("In", text: $newInput).frame(width: 56)
                    TextField("Out", text: $newOutput).frame(width: 56)
                    TextField("Cached", text: $newCache).frame(width: 60)
                    Button("Add") {
                        guard let i = Double(newInput), let o = Double(newOutput) else { return }
                        gateway.setPrice(GatewayPrice(input: i, output: o, cacheRead: Double(newCache)), for: newPrefix)
                        newPrefix = ""; newInput = ""; newOutput = ""; newCache = ""
                    }
                    .disabled(newPrefix.trimmingCharacters(in: .whitespaces).isEmpty || Double(newInput) == nil || Double(newOutput) == nil)
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .font(.system(size: 12))
                if let model = gateway.unpricedModels.first, newPrefix.isEmpty {
                    Button("Use “\(model)”") { newPrefix = model }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Prices")
        }
    }

    private func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%g", v)
    }
}

extension Format {
    /// 1234 → "1.2k", 2_500_000 → "2.5M"
    static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    static func dollars(_ v: Double) -> String {
        if v == 0 { return "$0" }
        if v < 0.01 { return "<$0.01" }
        return v >= 100 ? String(format: "$%.0f", v) : String(format: "$%.2f", v)
    }
}

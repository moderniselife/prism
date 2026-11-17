import AppKit
import SwiftUI

// MARK: - Settings → Brains & agents, Routines (Brainium 0.3+)
//
// A brain is a git repo with shared/ (what every agent knows), agents/<name>/
// (each agent's own notes and supporting docs) and routines/ (scheduled
// jobs). Prism lists them, lets each group or profile pick its brain, and
// shows, approves and runs routines. Brainium's CLI does the work.

// MARK: Shared pieces

/// Shown instead of a pane until Brainium is installed, new enough and has a personal brain.
@MainActor
struct BrainiumNotReady: View {
    @EnvironmentObject var store: ProfileStore

    var body: some View {
        SettingsGroup(title: "Second brain") {
            SettingsRow(title: title, detail: detail) {
                HStack(spacing: 8) {
                    if let update = updateAction {
                        Button("Update Brainium", action: update)
                            .buttonStyle(PrismButtonStyle(kind: .primary, height: 26))
                            .disabled(store.brainSetupStep != nil)
                    }
                    Button("Open Second brain") { PrismSettings.open(.secondBrain) }
                        .buttonStyle(PrismButtonStyle(kind: .secondary, height: 26))
                }
            }
        }
    }

    private var status: BrainiumBridge.Status? { store.brainStatus }

    private var title: String {
        if store.brainium == nil { return "Brainium isn't set up yet" }
        if status == nil { return "Checking Brainium…" }
        if status?.supportsTeams != true { return "Brainium needs an update" }
        return "Create your personal brain first"
    }

    private var detail: String {
        if store.brainium == nil { return "Install it in Settings → Second brain." }
        if status?.supportsTeams != true {
            return "Brains, agents and routines need Brainium 0.3 or newer (you have \(status?.version ?? "an older version"))."
        }
        return "Brains and routines sit alongside your personal brain."
    }

    private var updateAction: (() -> Void)? {
        guard store.brainium != nil, status != nil, status?.supportsTeams != true,
              let cli = BrainiumBridge.findCLI(custom: store.brainiumPath) else { return nil }
        let dir = BrainiumSetup.checkoutDir(forCLI: cli)
        guard FileManager.default.fileExists(atPath: dir + "/.git") else { return nil }
        let store = self.store
        return { store.updateBrainium(at: dir) }
    }
}

extension ProfileStore {
    /// Brainium is installed, 0.3+, and has a personal brain.
    var teamsReady: Bool {
        brainium != nil && brainStatus?.supportsTeams == true && brainStatus?.personalExists == true
    }
}

/// The last thing Brainium said, with a spinner while it works.
@MainActor
struct BrainMessageRow: View {
    @EnvironmentObject var store: ProfileStore

    var body: some View {
        if store.brainBusy || store.brainMessage != nil {
            HStack(spacing: 8) {
                if store.brainBusy { ProgressView().controlSize(.small) }
                Text(store.brainMessage ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, 4)
        }
    }
}

/// Pick a brain: an inherited choice ("Group's — mojo-layers") or a named brain.
@MainActor
struct BrainMenu: View {
    @EnvironmentObject var store: ProfileStore
    let selection: String?
    let inheritedLabel: String
    let onPick: (String?) -> Void

    var body: some View {
        Menu {
            Button(inheritedLabel) { onPick(nil) }
            if !store.brainNames.isEmpty { Divider() }
            ForEach(store.brainNames, id: \.self) { name in
                Button {
                    onPick(name)
                } label: {
                    if name == selection { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
            Divider()
            Button("New Brain…") { BrainPrompts.newBrain(store: store) }
        } label: {
            (Text(selection ?? inheritedLabel)
                + Text("  ")
                + Text(Image(systemName: "chevron.up.chevron.down")).font(.system(size: 8, weight: .semibold)))
                .font(.system(size: 12))
                .foregroundStyle(selection == nil ? PrismTheme.Colors.textTertiary : PrismTheme.Colors.textPrimary)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

@MainActor
enum BrainPrompts {
    /// Brain names are lowercase words joined by dashes ("Mojo Layers" → "mojo-layers").
    static func slug(_ s: String) -> String {
        let lowered = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let parts = lowered.split(whereSeparator: { !($0.isLetter || $0.isNumber) || !$0.isASCII })
        return String(parts.joined(separator: "-").prefix(40))
    }

    static let reserved: Set<String> = ["personal", "project", "all", "everyone", "auto", "shared"]

    /// Ask for a name, then where to put it; creates <folder>/<name> as a new brain.
    static func newBrain(store: ProfileStore) {
        guard let raw = GroupPrompt.ask(title: "New brain",
                                        info: "One brain per team, group, profile or project. Its agents share what's in it and keep their own notes too.",
                                        placeholder: "e.g. Mojo Layers, Research"),
              let name = validName(raw, store: store) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Create Here"
        panel.message = "Choose where to create the \"\(name)\" brain. Prism makes a \(name) folder inside with shared/, agents/ and routines/, as its own git repo."
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Brainium")
        if !FileManager.default.fileExists(atPath: panel.directoryURL!.path) {
            panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        }
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        // Picking the personal brain's own folder would nest a repo inside it.
        store.createBrain(name: name, at: parent.appendingPathComponent(name), makeDefault: store.brainList.count <= 1)
    }

    /// Use a folder you already have (a cloned team brain, say).
    static func addExisting(store: ProfileStore) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use This Brain"
        panel.message = "Choose a brain folder (one with shared/ and agents/, or any folder of notes)."
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let raw = GroupPrompt.ask(title: "Name this brain", initial: url.lastPathComponent, confirm: "Add",
                                        info: "Agents and routines refer to it by this name.",
                                        placeholder: "e.g. mojo-layers"),
              let name = validName(raw, store: store) else { return }
        store.addExistingBrain(name: name, at: url)
    }

    private static func validName(_ raw: String, store: ProfileStore) -> String? {
        let name = slug(raw)
        if name.isEmpty || reserved.contains(name) {
            store.brainMessage = "Choose another name (not \(reserved.sorted().joined(separator: ", ")))."
            return nil
        }
        if store.brainNames.contains(name) {
            store.brainMessage = "There's already a brain called \(name)."
            return nil
        }
        return name
    }
}

// MARK: - Brains & agents

@MainActor
struct BrainsSettingsPane: View {
    @EnvironmentObject var store: ProfileStore

    var body: some View {
        SettingsPage {
            if store.teamsReady {
                brainsGroup
                agentsGroups
                bindingsGroup
                BrainMessageRow()
            } else {
                BrainiumNotReady()
            }
        }
        .task {
            store.refreshBrainStatus()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                store.refreshTeams()
            }
        }
    }

    private var brainsGroup: some View {
        SettingsGroup(title: "Brains",
                      footer: "Each brain is its own git repo: shared/ for what every agent knows, agents/<name>/ for each agent's own notes and docs, routines/ for scheduled jobs. Push one to a private GitHub repo to share it between Macs or with other people.",
                      accessory: {
                          Menu {
                              Button("New Brain…") { BrainPrompts.newBrain(store: store) }
                              Button("Use an Existing Folder…") { BrainPrompts.addExisting(store: store) }
                          } label: {
                              Label("Add brain", systemImage: "plus")
                                  .font(.system(size: 12))
                          }
                          .menuStyle(.borderlessButton)
                          .fixedSize()
                      }) {
            ForEach(Array(store.brainList.enumerated()), id: \.element.id) { index, brain in
                if index > 0 { SettingsDivider() }
                BrainRow(brain: brain)
            }
        }
    }

    @ViewBuilder
    private var agentsGroups: some View {
        let withAgents = store.brainList.filter { !$0.agents.isEmpty }
        if withAgents.isEmpty {
            SettingsGroup(title: "Agents") {
                SettingsRow(title: "No agents yet",
                            detail: "An agent is a folder in a brain's agents/ — make one by hand with its docs inside, or let the agent save its card (agent_card_save). Then copy its instructions from here so it logs to its own folder.") {
                    EmptyView()
                }
            }
        } else {
            ForEach(withAgents) { brain in
                SettingsGroup(title: "Agents in \(brain.name)",
                              footer: brain.id == withAgents.first?.id
                                ? "An agent keeps its own notes in its folder and reads shared/ too. Copy its instructions into the agent (a Claude Code subagent, a Desktop project, a Grok Bot agent) so it names itself on every brain call."
                                : nil) {
                    ForEach(Array(brain.agents.enumerated()), id: \.element.id) { index, agent in
                        if index > 0 { SettingsDivider() }
                        AgentRow(agent: agent, brain: brain)
                    }
                }
            }
        }
    }

    private var defaultBrain: String { store.brainList.first(where: \.isDefault)?.name ?? "personal" }

    private var bindingsGroup: some View {
        SettingsGroup(title: "Which brain each group uses",
                      footer: "A profile uses its group's brain unless you pick one in its detail panel; profiles with no group use the default (\(defaultBrain)). Agents can still name another brain on any call.") {
            if store.groups.isEmpty {
                SettingsRow(title: "No groups yet",
                            detail: "Every profile uses the default brain. Make groups in Settings → Groups to give a project or client its own brain.") {
                    EmptyView()
                }
            } else {
                ForEach(Array(store.groups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 { SettingsDivider() }
                    HStack(spacing: 10) {
                        GroupSwatch(colorHex: group.colorHex, size: 9)
                        Text(group.name)
                            .font(.system(size: 13))
                            .foregroundStyle(PrismTheme.Colors.textPrimary)
                        Text(profileCount(group.id))
                            .font(.system(size: 11))
                            .foregroundStyle(PrismTheme.Colors.textTertiary)
                        Spacer()
                        BrainMenu(selection: group.brain, inheritedLabel: "Default (\(defaultBrain))") { picked in
                            store.setBrain(picked, forGroup: group.id)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                }
            }
        }
    }

    private func profileCount(_ groupID: String) -> String {
        let n = store.profiles(in: groupID).count
        return n == 1 ? "1 profile" : "\(n) profiles"
    }
}

@MainActor
private struct BrainRow: View {
    @EnvironmentObject var store: ProfileStore
    let brain: BrainiumBridge.BrainInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: brain.name == "personal" ? "person.crop.circle" : "brain")
                .font(.system(size: 15))
                .foregroundStyle(PrismTheme.Colors.accentText)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(brain.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PrismTheme.Colors.textPrimary)
                    if brain.isDefault {
                        Text("Default")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(PrismTheme.Colors.accentText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(PrismTheme.Colors.accent.opacity(0.12), in: Capsule())
                    }
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(brain.exists ? PrismTheme.Colors.textTertiary : PrismTheme.Colors.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(brain.path)
            }
            Spacer(minLength: 8)
            Menu {
                if !brain.isDefault {
                    Button("Make Default") { store.makeDefaultBrain(brain.name) }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: brain.path)])
                }
                .disabled(!brain.exists)
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(brain.path, forType: .string)
                }
                if brain.name != "personal" {
                    Divider()
                    Button("Forget Brain…") { confirmForget() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var detail: String {
        if !brain.exists { return "Missing: \(BrainiumSetup.tilde(brain.path))" }
        var parts = [BrainiumSetup.tilde(brain.path)]
        let a = brain.agents.count
        if a > 0 { parts.append(a == 1 ? "1 agent" : "\(a) agents") }
        if brain.routines > 0 { parts.append(brain.routines == 1 ? "1 routine" : "\(brain.routines) routines") }
        if let remote = brain.remote, !remote.isEmpty {
            parts.append(remote.replacingOccurrences(of: "git@github.com:", with: "github.com/")
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: ".git", with: ""))
        } else if brain.isRepo == true {
            parts.append("only on this Mac")
        }
        return parts.joined(separator: " · ")
    }

    private func confirmForget() {
        let alert = NSAlert()
        alert.messageText = "Forget the \"\(brain.name)\" brain?"
        alert.informativeText = "Prism and Brainium stop using it. Its folder and everything in it stay where they are; profiles and groups that used it go back to the default brain."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { store.forgetBrain(brain.name) }
    }
}

@MainActor
private struct AgentRow: View {
    @EnvironmentObject var store: ProfileStore
    let agent: BrainiumBridge.AgentInfo
    let brain: BrainiumBridge.BrainInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.fill")
                .font(.system(size: 12))
                .foregroundStyle(PrismTheme.Colors.textTertiary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.system(size: 13))
                    .foregroundStyle(PrismTheme.Colors.textPrimary)
                Text((agent.tldr ?? "").isEmpty ? (agent.card == nil ? "No card yet" : "No TLDR in its card") : agent.tldr!)
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Menu {
                Button("Copy Instructions for Claude / Cursor") { store.copyAgentSnippet(agent: agent.name, brain: brain.name) }
                Button("Copy Instructions for Grok Bot") { store.copyAgentSnippet(agent: agent.name, brain: brain.name, grok: true) }
                Divider()
                Button("Show Folder") { reveal(agent.folder ?? agent.card) }
                    .disabled(agent.folder == nil && agent.card == nil)
                Button("Open Card") { open(agent.card) }
                    .disabled(agent.card == nil)
            } label: {
                Label("Instructions", systemImage: "doc.on.doc")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// "mojo-layers:agents/x/card.md" → a file URL inside the brain.
    private func url(_ ref: String?) -> URL? {
        guard let ref, let colon = ref.firstIndex(of: ":") else { return nil }
        return URL(fileURLWithPath: brain.path).appendingPathComponent(String(ref[ref.index(after: colon)...]))
    }

    private func reveal(_ ref: String?) {
        if let u = url(ref) { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    private func open(_ ref: String?) {
        if let u = url(ref) { NSWorkspace.shared.open(u) }
    }
}

// MARK: - Routines

@MainActor
struct RoutinesSettingsPane: View {
    @EnvironmentObject var store: ProfileStore
    @State private var reviewing: BrainiumBridge.RoutineInfo?

    var body: some View {
        SettingsPage {
            if store.teamsReady {
                schedulerGroup
                routinesGroup
                BrainMessageRow()
            } else {
                BrainiumNotReady()
            }
        }
        .sheet(item: $reviewing) { r in
            RoutineApprovalSheet(routine: r) { reviewing = nil }
                .environmentObject(store)
        }
        .task {
            store.refreshBrainStatus()
            // Keep "running" and last results fresh while the pane is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(store.routineList.contains { $0.running != nil } ? 3 : 15))
                store.refreshTeams()
            }
        }
    }

    private var mode: String { store.brainStatus?.scheduler?.mode ?? "off" }

    private var schedulerGroup: some View {
        SettingsGroup(title: "Run routines", footer: schedulerFooter) {
            SettingsRow(title: "Run on schedule", detail: schedulerDetail) {
                Picker("", selection: Binding(get: { mode }, set: { store.setSchedulerMode($0) })) {
                    Text("Off").tag("off")
                    Text("While Prism is open").tag("prism")
                    Text("Always").tag("os")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(store.brainBusy)
            }
        }
    }

    private var schedulerDetail: String {
        switch mode {
        case "os":
            let s = store.brainStatus?.scheduler
            if s?.loaded == true { return "A background job (launchd) checks every minute, even when Prism is closed." }
            return "The background job isn't running. Choose Always again to reinstall it."
        case "prism": return "Prism checks every minute while it's open."
        default: return "Routines only run when you click Run."
        }
    }

    private var schedulerFooter: String {
        "Each brain's routines/ folder syncs through git, so prompts and shell commands only run on this Mac after you approve them here. Changing a routine's file needs approving again."
    }

    private var routinesGroup: some View {
        SettingsGroup(title: "Routines",
                      footer: store.routineList.isEmpty ? nil : "A run is logged to its agent's sessions (or shared/sessions) in the brain; the full output stays on this Mac in ~/.brainium-raw/routines.",
                      accessory: { newMenu }) {
            if store.routineList.isEmpty {
                SettingsRow(title: "No routines yet",
                            detail: "A routine runs a prompt through Claude Code or Codex, a built-in job (sync the brain, file captured sessions, a weekly digest) or a shell command on a schedule. Add one, or ask an agent to make one (routine_save).") {
                    EmptyView()
                }
            } else {
                ForEach(Array(store.routineList.enumerated()), id: \.element.id) { index, routine in
                    if index > 0 { SettingsDivider() }
                    RoutineRow(routine: routine) { reviewing = routine }
                }
            }
        }
    }

    private var newMenu: some View {
        Menu {
            ForEach(store.brainList.filter(\.exists)) { brain in
                Menu(brain.name) {
                    let claudeProfiles = store.profiles.filter { $0.normalizedApp == CursorProfile.appClaudeCode }
                    if claudeProfiles.isEmpty {
                        Button("Prompt (Claude Code or Codex)…") { ask(brain.name, "prompt") }
                    } else {
                        Menu("Prompt in a Claude Code profile") {
                            ForEach(claudeProfiles) { profile in
                                Button(profile.displayName) { ask(brain.name, "prompt", profile: profile) }
                            }
                        }
                    }
                    Button("Upkeep job…") { ask(brain.name, "upkeep") }
                    Button("Shell command…") { ask(brain.name, "shell") }
                }
            }
        } label: {
            Label("New routine", systemImage: "plus")
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func ask(_ brain: String, _ type: String, profile: CursorProfile? = nil) {
        guard let name = GroupPrompt.ask(title: "New routine in \(brain)",
                                         info: "Prism creates it switched off and opens it so you can set the schedule and what it does.",
                                         placeholder: "e.g. Morning brief, Nightly sync"),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.newRoutine(name: name, brain: brain, type: type, profile: profile)
    }
}

@MainActor
private struct RoutineRow: View {
    @EnvironmentObject var store: ProfileStore
    let routine: BrainiumBridge.RoutineInfo
    let review: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(get: { routine.enabled }, set: { store.setRoutineEnabled(routine, $0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(routine.blockedByApproval || !routine.errors.isEmpty || store.brainBusy)
                .help(routine.blockedByApproval ? "Approve it first" : (routine.enabled ? "On" : "Off"))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(routine.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PrismTheme.Colors.textPrimary)
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                    .lineLimit(1)
                statusLine
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if routine.blockedByApproval && routine.errors.isEmpty {
                    Button(routine.changedSinceApproval ? "Review Changes" : "Review & Approve", action: review)
                        .buttonStyle(PrismButtonStyle(kind: .primary, height: 24))
                }
                Button { store.runRoutineNow(routine) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless)
                    .disabled(routine.blockedByApproval || !routine.errors.isEmpty || routine.running != nil)
                    .help("Run now")
                Menu {
                    Button("Edit…") { NSWorkspace.shared.open(URL(fileURLWithPath: routine.file)) }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: routine.file)])
                    }
                    if let raw = lastRawLog {
                        Button("Show Last Output") { NSWorkspace.shared.open(raw) }
                    }
                    if routine.needsApproval && routine.approved {
                        Divider()
                        Button("Revoke Approval") { store.revokeRoutine(routine) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var summary: String {
        var parts = [routine.brain, routine.agent ?? "shared", typeLabel, RoutineText.schedule(routine.schedule)]
        if routine.type == "prompt", let profile = routine.profile { parts.append("in \(store.routineProfileLabel(profile))") }
        return parts.joined(separator: " · ")
    }

    private var typeLabel: String {
        switch routine.type {
        case "prompt": return routine.app == "codex" ? "Codex prompt" : "Claude Code prompt"
        case "upkeep": return "upkeep: \(routine.job ?? "")"
        default: return "shell"
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if !routine.errors.isEmpty {
            Text(routine.errors.joined(separator: "; "))
                .foregroundStyle(PrismTheme.Colors.red)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        } else if routine.running != nil {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Running…")
            }
            .font(.system(size: 11))
            .foregroundStyle(PrismTheme.Colors.accentText)
        } else if routine.blockedByApproval {
            Text(routine.changedSinceApproval ? "Changed since you approved it — review before it runs again" : "Needs your approval to run on this Mac")
                .font(.system(size: 11))
                .foregroundStyle(PrismTheme.Colors.amber)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if let last = routine.lastStatus {
                        Image(systemName: last == "ok" ? "checkmark.circle.fill" : last == "missed" ? "moon.zzz" : "xmark.circle.fill")
                            .foregroundStyle(last == "ok" ? PrismTheme.Colors.emerald : last == "missed" ? PrismTheme.Colors.textTertiary : PrismTheme.Colors.red)
                    }
                    Text(RoutineText.status(routine))
                        .foregroundStyle(PrismTheme.Colors.textSecondary)
                }
                // Why it failed, without hunting for the log.
                if ["failed", "timed out"].contains(routine.lastStatus ?? ""), let reason = failureLine {
                    Text(reason)
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 11))
            .help(routine.lastOutput ?? "")
        }
    }

    /// The last non-empty line of a failed run's output.
    private var failureLine: String? {
        routine.lastOutput?.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last(where: { !$0.isEmpty })
    }

    /// Newest raw log for this routine on this Mac.
    private var lastRawLog: URL? {
        let parts = routine.ref.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".brainium-raw/routines/\(parts[0])/\(parts[1])")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".log") }.sorted()
        return files?.last.map { dir.appendingPathComponent($0) }
    }
}

enum RoutineText {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    static func status(_ r: BrainiumBridge.RoutineInfo) -> String {
        var parts: [String] = []
        if let last = date(r.lastRun) {
            let what = r.lastStatus == "ok" ? "Ran" : r.lastStatus == "timed out" ? "Timed out" : r.lastStatus == "failed" ? "Failed" : "Last run"
            parts.append("\(what) \(relative(last))")
        } else if r.lastStatus == "missed" {
            parts.append("Missed its last time")
        }
        if !r.enabled {
            parts.append("off")
        } else if let next = date(r.nextRun) {
            parts.append("next \(relative(next))")
        }
        return parts.isEmpty ? "Not run yet" : parts.joined(separator: " · ")
    }

    /// "0 8 * * 1-5" → "Weekdays at 8:00"; anything unusual stays as written.
    static func schedule(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        switch t.lowercased() {
        case "@hourly": return "Hourly"
        case "@daily", "@midnight": return "Daily at midnight"
        case "@weekly": return "Sundays at midnight"
        case "@monthly": return "Monthly"
        default: break
        }
        if t.lowercased().hasPrefix("every ") { return t.prefix(1).uppercased() + t.dropFirst() }
        let f = t.split(separator: " ").map(String.init)
        guard f.count == 5, let m = Int(f[0]), let h = Int(f[1]), f[2] == "*", f[3] == "*" else { return t }
        let time = String(format: "%d:%02d", h, m)
        switch f[4] {
        case "*": return "Daily at \(time)"
        case "1-5": return "Weekdays at \(time)"
        case "0,6", "6,0", "6-7", "sat,sun": return "Weekends at \(time)"
        default:
            let names = ["sun": "Sundays", "mon": "Mondays", "tue": "Tuesdays", "wed": "Wednesdays", "thu": "Thursdays", "fri": "Fridays", "sat": "Saturdays",
                         "0": "Sundays", "1": "Mondays", "2": "Tuesdays", "3": "Wednesdays", "4": "Thursdays", "5": "Fridays", "6": "Saturdays", "7": "Sundays"]
            if let day = names[f[4].lowercased()] { return "\(day) at \(time)" }
            return t
        }
    }
}

// MARK: - Approving a routine

/// Shows exactly what will run, then approves it on this Mac.
@MainActor
struct RoutineApprovalSheet: View {
    @EnvironmentObject var store: ProfileStore
    let routine: BrainiumBridge.RoutineInfo
    let dismiss: () -> Void

    private var fileText: String {
        (try? String(contentsOfFile: routine.file, encoding: .utf8)) ?? "(couldn't read \(routine.file))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(routine.changedSinceApproval ? "Review changes to \(routine.name)" : "Approve \(routine.name)?")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PrismTheme.Colors.textPrimary)
                Text(what)
                    .font(.system(size: 12))
                    .foregroundStyle(PrismTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                Text(fileText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(PrismTheme.Colors.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 180, maxHeight: 320)
            .background(PrismTheme.Colors.surfaceAlt, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(PrismTheme.Colors.border, lineWidth: 1))
            Text("Approval is for this Mac only and for this exact file: if it changes (say, after a git pull), it won't run until you approve it again.")
                .font(.system(size: 11))
                .foregroundStyle(PrismTheme.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Edit…") { NSWorkspace.shared.open(URL(fileURLWithPath: routine.file)) }
                    .buttonStyle(PrismButtonStyle(kind: .plain, height: 28))
                Spacer()
                Button("Cancel", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(PrismButtonStyle(kind: .secondary, height: 28))
                Button(routine.enabled ? "Approve" : "Approve and Turn On") {
                    store.approveRoutine(routine, enable: !routine.enabled)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PrismButtonStyle(kind: .primary, height: 28))
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var what: String {
        let who = routine.agent.map { " as \($0)" } ?? ""
        switch routine.type {
        case "prompt":
            let app = routine.app == "codex" ? "Codex (codex exec)" : "Claude Code (claude -p)"
            let profile = routine.profile.map { " in the \(($0 as NSString).lastPathComponent) profile" } ?? ""
            return "Runs this prompt through \(app)\(profile)\(who), \(RoutineText.schedule(routine.schedule).lowercased()). It can use whatever that profile is allowed to."
        default:
            return "Runs this command with your login shell\(who), \(RoutineText.schedule(routine.schedule).lowercased()). It can do anything you can."
        }
    }
}

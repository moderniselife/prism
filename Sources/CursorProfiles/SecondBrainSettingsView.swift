import AppKit
import SwiftUI

// MARK: - Settings → Second brain (Brainium)

@MainActor
struct SecondBrainSettingsView: View {
    @EnvironmentObject var store: ProfileStore

    @State private var provider = "agent"
    @State private var url = ""
    @State private var model = ""
    @State private var apiKeyEnv = ""
    @State private var apiKey = ""
    @State private var capture = false

    private var status: BrainiumBridge.Status? { store.brainStatus }
    private var usesAPI: Bool { !["agent", "none"].contains(provider) }

    /// Self-hosted servers have no default address: the user must enter one
    /// (unless this provider already has a saved URL).
    private var needsURL: Bool {
        guard ["bonsai", "openai-compatible"].contains(provider),
              url.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return status?.summarizer?.provider != provider || (status?.summarizer?.url ?? "").isEmpty
    }

    var body: some View {
        Form {
            Section {
                Text("Brainium keeps a git-backed memory outside every account — a personal brain that follows you, plus a project brain in each repo — so agents keep their knowledge when you switch apps or accounts.")
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Brainium") {
                LabeledContent("Brainium") {
                    setupRow(found: cliPath.map(BrainiumSetup.checkoutDir(forCLI:)),
                             step: .brainium,
                             install: { store.installBrainium() },
                             useExisting: pickBrainium,
                             update: brainiumUpdate)
                }
                LabeledContent("Node.js") {
                    setupRow(found: nodePath,
                             step: .node,
                             install: { store.installNode() },
                             useExisting: pickNode,
                             update: nil)
                }
                if cliPath == nil || nodePath == nil {
                    HStack(alignment: .firstTextBaseline) {
                        Text(setupHint)
                            .font(.system(size: 11))
                            .foregroundStyle(PrismTheme.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Check Again") {
                            store.objectWillChange.send()
                            store.refreshBrainStatus()
                        }
                        .disabled(store.brainSetupStep != nil)
                    }
                }
            }

            Section("Personal brain") {
                LabeledContent("Location") {
                    HStack(spacing: 6) {
                        Text(status?.personalExists == true
                             ? ((status?.personalBrain ?? "") as NSString).abbreviatingWithTildeInPath
                             : "Not created yet")
                            .foregroundStyle(status?.personalExists == true ? PrismTheme.Colors.textSecondary : PrismTheme.Colors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(status?.personalExists == true ? "Change…" : "Create…") { pickPersonalBrain() }
                            .disabled(store.brainium == nil)
                    }
                }
                if status?.personalExists == true && (status?.personalRemote ?? "").isEmpty {
                    Text("Tip: push it to a private GitHub repo to use it on other machines — and so Grok Bot agents can reach it.")
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Profiles") {
                Toggle("Wire new profiles automatically", isOn: store.binding(\.brainAutoWire))
                Toggle("Capture Claude Code sessions", isOn: $capture)
                    .onChange(of: capture) { _, on in
                        if on != (status?.capture ?? false) { store.setBrainConfig([("capture", on ? "true" : "false")]) }
                    }
                Text("Capture stores each Claude Code session redacted and private (outside git) and queues it to be filed into the brain.")
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Wire All Profiles") { store.wireAllBrains() }
                    Button("Unwire All") { store.wireAllBrains(enable: false) }
                    Spacer()
                    Button("Copy Grok Bot Snippet") { store.copyGrokBrainSnippet() }
                        .help("Grok Bot agents run in the cloud: paste this into an agent's instructions so it uses your brain via its GitHub connector.")
                }
                .disabled(store.brainium == nil || store.brainBusy)
            }

            Section("Summarizing captures") {
                Picker("Summarize with", selection: $provider) {
                    ForEach(BrainiumBridge.providers) { p in
                        Text(p.label).tag(p.id)
                    }
                }
                Text(providerHelp)
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if usesAPI {
                    TextField("URL", text: $url, prompt: Text(urlPlaceholder))
                    TextField("Model", text: $model, prompt: Text(modelPlaceholder))
                    TextField("API key env var", text: $apiKeyEnv, prompt: Text(keyEnvPlaceholder))
                    SecureField("API key", text: $apiKey, prompt: Text(status?.summarizer?.hasKey == true ? "Saved — leave empty to keep" : "Optional if the env var is set"))
                    if needsURL {
                        Text(provider == "bonsai"
                             ? "Enter your Bonsai server's URL — its OpenAI-compatible API, usually ending in /v1."
                             : "Enter the server's OpenAI-compatible base URL, usually ending in /v1.")
                            .font(.system(size: 11))
                            .foregroundStyle(PrismTheme.Colors.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Spacer()
                    Button("Save Summarizer") { saveSummarizer() }
                        .disabled(store.brainium == nil || store.brainBusy || needsURL)
                }
            }

            if store.brainBusy || store.brainMessage != nil || (status?.pending ?? 0) > 0 {
                Section {
                    HStack(spacing: 8) {
                        if store.brainBusy { ProgressView().controlSize(.small) }
                        Text(store.brainMessage ?? "")
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if let pending = status?.pending, pending > 0 {
                            Text("\(pending) capture\(pending == 1 ? "" : "s") waiting")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(PrismTheme.Colors.textSecondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            store.refreshBrainStatus()
            syncFromStatus()
        }
        .onChange(of: store.brainStatus?.summarizer?.provider) { _, _ in syncFromStatus() }
        .onChange(of: store.brainStatus?.capture) { _, _ in syncFromStatus() }
    }

    // MARK: Pieces

    private var cliPath: String? { BrainiumBridge.findCLI(custom: store.brainiumPath) }

    /// Update action for a git checkout of Brainium; nil otherwise.
    private var brainiumUpdate: (() -> Void)? {
        guard let cli = cliPath else { return nil }
        let dir = BrainiumSetup.checkoutDir(forCLI: cli)
        guard FileManager.default.fileExists(atPath: dir + "/.git") else { return nil }
        let store = self.store
        return { store.updateBrainium(at: dir) }
    }
    private var nodePath: String? { BrainiumBridge.findNode(custom: store.brainiumNodePath) }

    private var setupHint: String {
        switch (cliPath == nil, nodePath == nil) {
        case (true, true):
            return "Brainium runs on Node.js. Install both, or point Prism at copies you already have."
        case (false, true):
            return BrainiumSetup.homebrew != nil
                ? "Brainium needs Node.js 18 or newer. Install uses Homebrew."
                : "Brainium needs Node.js 18 or newer. Install downloads the official installer from nodejs.org."
        default:
            return BrainiumSetup.hasGit
                ? "Install clones Brainium from GitHub into ~/brainium."
                : "Install downloads Brainium from GitHub into ~/brainium."
        }
    }

    /// Found: its path plus Change… (and Update for git checkouts).
    /// Missing: Install and Use existing…. Installing: a spinner.
    @ViewBuilder
    private func setupRow(found: String?, step: BrainSetupStep,
                          install: @escaping () -> Void,
                          useExisting: @escaping () -> Void,
                          update: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            if store.brainSetupStep == step {
                ProgressView().controlSize(.small)
                Text(step == .brainium ? "Installing…" : "Installing Node.js…")
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
            } else if let found {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(PrismTheme.Colors.emerald)
                Text(BrainiumSetup.tilde(found))
                    .foregroundStyle(PrismTheme.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(found)
                    .textSelection(.enabled)
                if let update {
                    Button("Update", action: update)
                        .disabled(store.brainSetupStep != nil)
                }
                Button("Change…", action: useExisting)
            } else {
                Text("Not installed")
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                Button("Install", action: install)
                    .buttonStyle(.borderedProminent)
                    .disabled(store.brainSetupStep != nil)
                Button("Use existing…", action: useExisting)
            }
        }
    }

    private func pickBrainium() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Use"
        panel.message = "Choose your Brainium folder (the one containing bin/brainium.mjs)."
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        if panel.runModal() == .OK, let picked = panel.url {
            guard BrainiumBridge.findCLI(custom: picked.path) != nil else {
                store.brainMessage = "That folder doesn't contain bin/brainium.mjs."
                return
            }
            store.brainiumPath = picked.path
            store.objectWillChange.send()
            store.refreshBrainStatus()
        }
    }

    private func pickNode() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Use"
        panel.message = "Choose the node executable (for example /usr/local/bin/node or ~/.nvm/versions/node/…/bin/node)."
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        if panel.runModal() == .OK, let picked = panel.url {
            store.brainiumNodePath = picked.path
            store.objectWillChange.send()
            store.refreshBrainStatus()
        }
    }

    private var providerHelp: String {
        switch provider {
        case "agent": return "Your own AI files captured sessions itself through the Brainium MCP server — no extra API calls or tokens."
        case "none": return "Files a plain mechanical summary (prompts, files, commands). No AI involved."
        case "anthropic": return "Uses the Anthropic Messages API. Default model claude-haiku-5-5; key from ANTHROPIC_API_KEY unless you save one."
        case "openai": return "Uses the OpenAI Chat Completions API. Set a model; key from OPENAI_API_KEY unless you save one."
        case "bonsai": return "Uses your self-hosted Bonsai server through its OpenAI-compatible API. Enter its URL below; default model solo-quick."
        default: return "Any OpenAI-compatible endpoint: set its base URL (ending in /v1 where needed) and model."
        }
    }

    private var urlPlaceholder: String {
        switch provider {
        case "anthropic": return "https://api.anthropic.com"
        case "openai": return "https://api.openai.com/v1"
        case "bonsai": return "Your Bonsai server, e.g. http://<host>:<port>/v1"
        default: return "http://<host>:<port>/v1"
        }
    }

    private var modelPlaceholder: String {
        switch provider {
        case "anthropic": return "claude-haiku-5-5"
        case "bonsai": return "solo-quick"
        default: return "model name"
        }
    }

    private var keyEnvPlaceholder: String {
        switch provider {
        case "anthropic": return "ANTHROPIC_API_KEY"
        case "openai": return "OPENAI_API_KEY"
        default: return "optional"
        }
    }

    private func syncFromStatus() {
        guard let s = status else { return }
        capture = s.capture ?? false
        provider = s.summarizer?.provider ?? "agent"
        // Show only what the user set, not provider defaults.
        url = ""
        model = ""
        apiKeyEnv = ""
    }

    private func saveSummarizer() {
        var pairs: [(String, String)] = [("summarizer.provider", provider)]
        if usesAPI {
            if !url.isEmpty { pairs.append(("summarizer.url", url)) }
            if !model.isEmpty { pairs.append(("summarizer.model", model)) }
            if !apiKeyEnv.isEmpty { pairs.append(("summarizer.apiKeyEnv", apiKeyEnv)) }
            if !apiKey.isEmpty { pairs.append(("summarizer.apiKey", apiKey)) }
        }
        store.setBrainConfig(pairs)
        apiKey = ""
    }

    private func pickPersonalBrain() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use as Personal Brain"
        panel.message = "Pick an empty folder (or an existing personal brain). Brainium creates the folders and a git repo."
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        if panel.runModal() == .OK, let picked = panel.url {
            store.createPersonalBrain(at: picked)
        }
    }
}

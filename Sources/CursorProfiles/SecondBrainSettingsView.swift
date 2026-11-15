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
                    pathRow(detected: store.brainium?.cli, binding: store.binding(\.brainiumPath),
                            placeholder: "Auto-detect (~/brainium)", pickFolder: true)
                }
                LabeledContent("Node.js") {
                    pathRow(detected: store.brainium?.node, binding: store.binding(\.brainiumNodePath),
                            placeholder: "Auto-detect", pickFolder: false)
                }
                if store.brainium == nil {
                    Text(BrainiumBridge.notFoundMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.Colors.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
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
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            store.refreshBrainStatus()
            syncFromStatus()
        }
        .onChange(of: store.brainStatus?.summarizer?.provider) { _, _ in syncFromStatus() }
        .onChange(of: store.brainStatus?.capture) { _, _ in syncFromStatus() }
    }

    // MARK: Pieces

    private func pathRow(detected: String?, binding: Binding<String>, placeholder: String, pickFolder: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                TextField(placeholder, text: binding)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { store.refreshBrainStatus() }
                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = !pickFolder
                    panel.canChooseDirectories = pickFolder
                    panel.prompt = "Use"
                    if panel.runModal() == .OK, let picked = panel.url {
                        binding.wrappedValue = picked.path
                        store.refreshBrainStatus()
                    }
                }
            }
            Text(detected.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not found")
                .font(.system(size: 10))
                .foregroundStyle(detected == nil ? PrismTheme.Colors.red : PrismTheme.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
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

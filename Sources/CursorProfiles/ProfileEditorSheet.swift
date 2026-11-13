import SwiftUI

// MARK: - Create / edit sheet
//
// Only real, persisted fields: name, icon, accent color, memory limit,
// project folder. No fake engines, no decorative toggles, no daemons.

@MainActor
struct ProfileEditorSheet: View {
    enum Mode {
        case create
        case edit(CursorProfile)
    }

    @EnvironmentObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    /// Explicit closer from the presenter. Environment `dismiss()` is kept
    /// as fallback, but state-driven closing can't silently no-op.
    var onClose: (() -> Void)? = nil

    @State private var name = ""
    @State private var app: String = CursorProfile.appCursor
    @State private var colorHex = AccentPalette.all[0].hex
    @State private var memoryMB = 16384
    @State private var projectPath = ""
    /// Start empty, or carry another same-app profile's config over into a
    /// second account ("overflow"). Never its sign-in.
    @State private var accountSetup: AccountSetup = .fresh
    @State private var sourceFolder = ""

    enum AccountSetup: Hashable {
        case fresh
        case overflow
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var previewColor: Color { Color(hex: colorHex) ?? .accentColor }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var isGrok: Bool { app == CursorProfile.appGrokBot }
    private var overflowSources: [CursorProfile] {
        store.profiles.filter { $0.normalizedApp == app }
    }
    private var overflowSource: CursorProfile? {
        overflowSources.first { $0.folderName == sourceFolder }
    }
    private var isOverflow: Bool { !isEditing && accountSetup == .overflow }
    private var canSave: Bool {
        !trimmedName.isEmpty && (!isOverflow || overflowSource != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    previewStrip
                    detailsSection
                    if !isEditing {
                        accountSection
                    }
                    resourcesSection
                    if !isGrok {
                        projectSection
                    }
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(width: 560, height: 600)
        .background(PrismTheme.Colors.bg)
        .onAppear(perform: populate)
        .onChange(of: app) { _, _ in defaultSource() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "Edit Profile" : "New Profile")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PrismTheme.Colors.textPrimary)
                Text("Each profile is an isolated instance — own settings, login and history.")
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
            }

            Spacer()

            Button(role: .cancel) {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(PrismTheme.Colors.textSecondary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Live preview

    private var previewInitial: String {
        guard let first = trimmedName.first else { return "?" }
        return String(first).uppercased()
    }

    private var previewSubtitle: String {
        let project = projectPath.isEmpty ? "" : " · \((projectPath as NSString).abbreviatingWithTildeInPath)"
        switch app {
        case CursorProfile.appClaudeCode: return "Claude Code\(project)\(overflowNote)"
        case CursorProfile.appClaudeDesktop: return "Claude Desktop\(overflowNote)"
        case CursorProfile.appGrokBot: return "Grok Bot\(overflowNote)"
        default: return "\(formatGB(memoryMB)) limit\(project)\(overflowNote)"
        }
    }

    private var overflowNote: String {
        guard isOverflow, let source = overflowSource else { return "" }
        return " · overflow of \(source.displayName)"
    }

    /// Pick the app's built-in profile as the default overflow source.
    private func defaultSource() {
        if overflowSource == nil {
            sourceFolder = (overflowSources.first { $0.isSystem } ?? overflowSources.first)?.folderName ?? ""
        }
    }

    private var previewStrip: some View {
        HStack(spacing: 12) {
            Text(previewInitial)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(previewColor)
                .frame(width: 50, height: 50)
                .background(previewColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text(trimmedName.isEmpty ? "Profile name" : trimmedName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(trimmedName.isEmpty
                                      ? PrismTheme.Colors.textMuted
                                      : PrismTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(previewSubtitle)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Circle()
                .fill(previewColor)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(PrismTheme.Colors.borderMed, lineWidth: 1))
                .help("Accent color")
        }
        .padding(12)
        .background(PrismTheme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerMedium))
        .overlay(RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerMedium)
            .stroke(previewColor.opacity(0.35), lineWidth: 1)
            .allowsHitTesting(false))
    }

    // MARK: - Sections

    private var detailsSection: some View {
        section(title: "Details") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PrismTheme.Colors.textSecondary)
                    TextField("e.g. Work, Personal, Experiments", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("App")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PrismTheme.Colors.textSecondary)
                    Picker("", selection: $app) {
                        Text("Cursor (editor)").tag(CursorProfile.appCursor)
                        Text("Claude Code (CLI)").tag(CursorProfile.appClaudeCode)
                        Text("Claude Desktop").tag(CursorProfile.appClaudeDesktop)
                        Text("Grok Bot").tag(CursorProfile.appGrokBot)
                    }
                    .pickerStyle(.segmented)
                    .disabled(isEditing)
                    .help(isEditing ? "The app is fixed after creation." : "Which app this profile belongs to.")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Accent color")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PrismTheme.Colors.textSecondary)
                    HStack(spacing: 8) {
                        ForEach(AccentPalette.all) { swatch in
                            Button {
                                colorHex = swatch.hex
                            } label: {
                                Circle()
                                    .fill(swatch.color)
                                    .frame(width: 22, height: 22)
                                    .overlay(
                                        Circle().strokeBorder(
                                            colorHex == swatch.hex ? PrismTheme.Colors.textPrimary : .clear,
                                            lineWidth: 2)
                                    )
                                    .shadow(color: swatch.color.opacity(colorHex == swatch.hex ? 0.5 : 0), radius: 4)
                            }
                            .buttonStyle(.plain)
                            .help(swatch.name)
                        }
                    }
                }
            }
        }
    }

    private var accountSection: some View {
        section(title: "Account") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $accountSetup) {
                    Text("Fresh account").tag(AccountSetup.fresh)
                    Text("Overflow account").tag(AccountSetup.overflow)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch accountSetup {
                case .fresh:
                    Text("Starts empty — no settings, config or sign-in. Sign in with any account on first launch.")
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                case .overflow:
                    if overflowSources.isEmpty {
                        Text("No \(CursorProfile.label(for: app)) profile to carry over from yet. Open \(CursorProfile.label(for: app)) once, then come back.")
                            .font(.system(size: 11))
                            .foregroundStyle(PrismTheme.Colors.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack(spacing: 8) {
                            Text("Carry over from")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(PrismTheme.Colors.textSecondary)
                            Picker("", selection: $sourceFolder) {
                                ForEach(overflowSources) { source in
                                    Text(source.displayName).tag(source.folderName)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: 240)
                        }
                        Text(Self.overflowExplainer(for: app))
                            .font(.system(size: 11))
                            .foregroundStyle(PrismTheme.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .onAppear(perform: defaultSource)
    }

    /// What an overflow copies for each app — kept honest and specific.
    private static func overflowExplainer(for app: String) -> String {
        let tail = " Sign in with your other account on first launch."
        switch CursorProfile.normalizeApp(app) {
        case CursorProfile.appClaudeCode:
            return "Copies settings, CLAUDE.md, agents, commands, skills, output styles, hooks, plugins and your user-level MCP servers. Its login, account id and chat history stay behind." + tail
        case CursorProfile.appClaudeDesktop:
            return "Copies the MCP config and installed extensions with their settings. Its login and cookies stay behind." + tail
        case CursorProfile.appGrokBot:
            return "Copies local settings, permission choices and tool approvals; its login and machine identity stay behind. Grok Bot agents live on your account's cloud box, not on this Mac — use Share with team on an agent in Grok Bot to give this account the same agents." + tail
        default:
            return "Copies settings, keybindings, tasks and snippets (extensions are already shared). Its login and machine id stay behind." + tail
        }
    }

    private var resourcesSection: some View {
        section(title: "Resources") {
            VStack(alignment: .leading, spacing: 8) {
                Text(app == CursorProfile.appCursor
                     ? "Memory limit — passed to Cursor as --max-memory."
                     : "Memory limit applies to Cursor only — ignored for this app.")
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)

                HStack(spacing: 6) {
                    memoryPreset("8 GB", value: 8192)
                    memoryPreset("16 GB", value: 16384)
                    memoryPreset("32 GB", value: 32768)
                    Spacer()
                    TextField("MB", value: $memoryMB, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .rounded))
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                        .disabled(app != CursorProfile.appCursor)
                    Text("MB")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                }
            }
        }
        .opacity(app == CursorProfile.appCursor ? 1.0 : 0.55)
    }

    private var projectSection: some View {
        section(title: "Project") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Folder opened on launch (optional).")
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                HStack(spacing: 6) {
                    TextField("No folder — open Finder picker on launch", text: $projectPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .rounded))
                    Button("Choose…") { pickFolder() }
                }
            }
        }
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(PrismTheme.Colors.textTertiary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PrismTheme.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerMedium))
            .overlay(RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerMedium)
                .stroke(PrismTheme.Colors.border, lineWidth: 1)
                .allowsHitTesting(false))
        }
    }

    private func memoryPreset(_ label: String, value: Int) -> some View {
        Button {
            memoryMB = value
        } label: {
            Text(label)
                .font(.system(size: 11, weight: memoryMB == value ? .semibold : .regular))
        }
        .buttonStyle(.bordered)
        .tint(memoryMB == value ? previewColor : nil)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if case .edit(let profile) = mode {
                Text(profile.isSystem
                     ? "Built-in profile — \(profile.appLabel) data"
                     : "Folder: \(profile.folderName)")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(PrismTheme.Colors.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Cancel", role: .cancel) { close() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            Button(isEditing ? "Save" : "Create Profile") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Helpers

    private func formatGB(_ mb: Int) -> String {
        mb >= 1024 ? String(format: "%.0f GB", Double(mb) / 1024.0) : "\(mb) MB"
    }

    private func populate() {
        switch mode {
        case .create:
            memoryMB = store.defaultMemoryMB
            colorHex = AccentPalette.random().hex
            app = CursorProfile.appCursor
        case .edit(let profile):
            name = profile.displayName
            app = profile.normalizedApp
            colorHex = profile.colorHex
            memoryMB = profile.defaultMemoryMB
            projectPath = profile.defaultProjectPath ?? ""
        }
    }

    private func save() {
        let trimmedProject = projectPath.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .create where isOverflow:
            guard let source = overflowSource else { return }
            store.createOverflow(displayName: trimmedName, colorHex: colorHex,
                                 memoryMB: max(512, memoryMB),
                                 defaultProjectPath: trimmedProject.isEmpty ? nil : trimmedProject,
                                 source: source)
            close()
        case .create:
            let created = store.createProfile(
                displayName: trimmedName,
                app: app,
                colorHex: colorHex,
                memoryMB: max(512, memoryMB),
                defaultProjectPath: trimmedProject.isEmpty ? nil : trimmedProject
            )
            if created != nil { close() }
        case .edit(let original):
            var updated = original
            updated.displayName = trimmedName
            updated.colorHex = colorHex
            updated.defaultMemoryMB = max(512, memoryMB)
            updated.defaultProjectPath = trimmedProject.isEmpty ? nil : trimmedProject
            store.update(updated)
            close()
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            projectPath = url.path
        }
    }
}

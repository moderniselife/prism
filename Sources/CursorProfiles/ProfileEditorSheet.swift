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
    @State private var endpointIdentity = ""
    @ObservedObject private var gateway = GatewayController.shared
    /// Start empty, or carry another same-app profile's config over into a
    /// second account ("overflow"). Never its sign-in.
    @State private var accountSetup: AccountSetup = .fresh
    @State private var sourceFolder = ""

    enum AccountSetup: Hashable {
        case fresh
        case overflow
    }

    private static let sheetWidth: CGFloat = 560

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

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

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    nameField
                    appPicker
                    colorPicker
                    if !isEditing {
                        accountSection
                    }
                    if app == CursorProfile.appCursor {
                        memorySection
                    }
                    if opensProjectFolder {
                        projectSection
                    }
                    if app == CursorProfile.appClaudeCode && !gateway.config.identities.isEmpty && !isOverflow {
                        endpointSection
                    }
                }
                // Pin the form to the sheet's width. Without a fixed width
                // the first layout pass sizes it from its widest child and
                // the form renders clipped until something re-lays it out.
                .frame(width: Self.sheetWidth - 48, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }

            footer
        }
        .frame(width: Self.sheetWidth, height: 640)
        .background(PrismTheme.Colors.bg)
        .tint(PrismTheme.Colors.accent)
        .onAppear(perform: populate)
        .onChange(of: app) { _, _ in defaultSource() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isEditing ? "Edit profile" : "New profile")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(PrismTheme.Colors.textPrimary)
                Text("Each profile keeps its own sign-in, settings and history.")
                    .font(.system(size: 12))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
            }

            Spacer()

            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(PrismTheme.Colors.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(PrismTheme.Colors.surfaceAlt, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    /// Pick the app's built-in profile as the default overflow source.
    private func defaultSource() {
        if overflowSource == nil {
            sourceFolder = (overflowSources.first { $0.isSystem } ?? overflowSources.first)?.folderName ?? ""
        }
    }

    private var opensProjectFolder: Bool {
        app == CursorProfile.appCursor || app == CursorProfile.appClaudeCode
    }

    // MARK: - Fields

    private var nameField: some View {
        field("Name") {
            TextField("e.g. Client work", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(PrismTheme.Colors.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(PrismTheme.Colors.borderMed, lineWidth: 1))
        }
    }

    private var appPicker: some View {
        field("App") {
            HStack(spacing: 8) {
                ForEach(CursorProfile.allApps, id: \.self) { candidate in
                    let selected = app == candidate
                    Button {
                        app = candidate
                    } label: {
                        VStack(spacing: 8) {
                            AppGlyph(app: candidate, size: 18)
                            Text(CursorProfile.label(for: candidate))
                                .font(.system(size: 12, weight: selected ? .medium : .regular))
                                .lineLimit(1)
                        }
                        .foregroundStyle(selected ? PrismTheme.Colors.textPrimary : PrismTheme.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 70)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selected ? PrismTheme.Colors.accent.opacity(0.07) : PrismTheme.Colors.surface))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? PrismTheme.Colors.accent : PrismTheme.Colors.border,
                                          lineWidth: selected ? 1.5 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .disabled(isEditing)
            .opacity(isEditing ? 0.6 : 1)
            .help(isEditing ? "The app is fixed after creation." : "Which app this profile belongs to.")
        }
    }

    private var colorPicker: some View {
        field("Color") {
            HStack(spacing: 10) {
                ForEach(AccentPalette.all) { swatch in
                    let selected = colorHex == swatch.hex
                    Button {
                        colorHex = swatch.hex
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 22, height: 22)
                            .padding(3)
                            .overlay(Circle().strokeBorder(selected ? swatch.color : .clear, lineWidth: 2))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(swatch.name)
                }
            }
            .padding(.leading, -3)
        }
    }

    private var accountSection: some View {
        field("Account") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    accountOption(.fresh, title: "Fresh account",
                                  detail: "Starts empty. Sign in with any account on first launch.")
                    accountOption(.overflow, title: CursorProfile.copyChoiceLabel(for: app),
                                  detail: isGrok
                                    ? "Copies local settings. Agents stay on your Grok account."
                                    : "Copies your setup, then you sign in with another account.")
                }

                if accountSetup == .overflow {
                    if overflowSources.isEmpty {
                        Text("No \(CursorProfile.label(for: app)) profile to carry over from yet. Open \(CursorProfile.label(for: app)) once, then come back.")
                            .font(.system(size: 12))
                            .foregroundStyle(PrismTheme.Colors.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack(spacing: 10) {
                            Text("Copy from")
                                .font(.system(size: 12))
                                .foregroundStyle(PrismTheme.Colors.textSecondary)
                            Picker("", selection: $sourceFolder) {
                                ForEach(overflowSources) { source in
                                    Text(source.displayName).tag(source.folderName)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: 260, alignment: .leading)
                        }
                        Text(Self.overflowExplainer(for: app))
                            .font(.system(size: 12))
                            .foregroundStyle(PrismTheme.Colors.textTertiary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .onAppear(perform: defaultSource)
    }

    private func accountOption(_ choice: AccountSetup, title: String, detail: String) -> some View {
        let selected = accountSetup == choice
        return Button {
            accountSetup = choice
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? PrismTheme.Colors.accent : PrismTheme.Colors.textMuted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PrismTheme.Colors.textPrimary)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? PrismTheme.Colors.accent.opacity(0.06) : PrismTheme.Colors.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? PrismTheme.Colors.accent : PrismTheme.Colors.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            return "Copies local settings, permission choices and tool approvals only — not your agents, which live on your Grok Bot account. To bring an agent across: in the source profile open the agent → Create Template → Share a template link → Copy the share link, then paste that link into a chat in this profile (paste it rather than clicking it, so it opens here)." + tail
        default:
            return "Copies settings, keybindings, tasks and snippets (extensions are already shared). Its login and machine id stay behind." + tail
        }
    }

    private var memorySection: some View {
        field("Memory limit") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    HStack(spacing: 2) {
                        memoryPreset("8 GB", value: 8192)
                        memoryPreset("16 GB", value: 16384)
                        memoryPreset("32 GB", value: 32768)
                    }
                    .padding(3)
                    .background(PrismTheme.Colors.surfaceAlt, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                    Spacer(minLength: 8)

                    TextField("MB", value: $memoryMB, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text("MB")
                        .font(.system(size: 12))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                }
                Text("Passed to Cursor as --max-memory.")
                    .font(.system(size: 12))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
            }
        }
    }

    private var projectSection: some View {
        field("Project folder") {
            HStack(spacing: 8) {
                TextField("None — choose when you launch", text: $projectPath)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(PrismTheme.Colors.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(PrismTheme.Colors.borderMed, lineWidth: 1))
                Button("Choose…") { pickFolder() }
                    .buttonStyle(PrismButtonStyle(kind: .secondary, height: 32))
            }
        }
    }

    private var endpointSection: some View {
        field("API account") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: $endpointIdentity) {
                    Text("This profile's own sign-in").tag("")
                    Text("Prism endpoint · whichever identity is active").tag("*")
                    ForEach(gateway.config.identities) { identity in
                        Text("Prism endpoint · always \(identity.name)").tag(identity.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Text(endpointIdentity.isEmpty
                     ? "Claude Code uses the account you sign in with."
                     : (gateway.config.enabled
                        ? "Claude Code sends requests through Prism with your API keys, so you can switch accounts mid-session."
                        : "Turn the endpoint on in Settings → Endpoint first; until then this profile uses its own sign-in."))
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PrismTheme.Colors.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func memoryPreset(_ label: String, value: Int) -> some View {
        let selected = memoryMB == value
        return Button {
            memoryMB = value
        } label: {
            Text(label)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? PrismTheme.Colors.textPrimary : PrismTheme.Colors.textSecondary)
                .frame(width: 64, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? PrismTheme.Colors.surface : .clear)
                    .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 1, y: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if case .edit(let profile) = mode {
                Text(profile.isSystem
                     ? "Built-in profile — \(profile.appLabel) data"
                     : "Folder: \(profile.folderName)")
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Cancel", role: .cancel) { close() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            Button(isEditing ? "Save" : "Create profile") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(PrismTheme.Colors.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(PrismTheme.Colors.borderSubtle).frame(height: 1)
        }
    }

    // MARK: - Helpers

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
            endpointIdentity = profile.endpointIdentity ?? ""
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
            if var created {
                if app == CursorProfile.appClaudeCode, !endpointIdentity.isEmpty {
                    created.endpointIdentity = endpointIdentity
                    store.update(created)
                }
                close()
            }
        case .edit(let original):
            var updated = original
            updated.displayName = trimmedName
            updated.colorHex = colorHex
            updated.defaultMemoryMB = max(512, memoryMB)
            updated.defaultProjectPath = trimmedProject.isEmpty ? nil : trimmedProject
            updated.endpointIdentity = app == CursorProfile.appClaudeCode && !endpointIdentity.isEmpty ? endpointIdentity : nil
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

import SwiftUI
import UniformTypeIdentifiers

/// Column widths shared by the list header and its rows.
enum HubColumns {
    static let app: CGFloat = 140
    static let status: CGFloat = 180
    static let action: CGFloat = 112
    static let spacing: CGFloat = 12
}

// MARK: - One profile in the hub list

@MainActor
struct ProfileRow: View {
    @EnvironmentObject var store: ProfileStore
    let profile: CursorProfile
    let isSelected: Bool
    /// Show the profile's group as a tag (off when the list is already
    /// split or filtered by group).
    var showGroup = true
    var onSelect: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var showingLaunchOptions = false

    private var isRunning: Bool { store.isRunning(profile) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        HStack(spacing: HubColumns.spacing) {
            HStack(spacing: 10) {
                Circle()
                    .fill(profile.accentColor)
                    .frame(width: 8, height: 8)
                Text(profile.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PrismTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if profile.isSystem { DefaultTag() }
                if showGroup, let group = store.group(profile.groupID) {
                    GroupTag(group: group)
                }
                if profile.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(PrismTheme.Colors.textMuted)
                        .help("Pinned")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 7) {
                AppGlyph(app: profile.normalizedApp, size: 14)
                Text(profile.appLabel)
                    .lineLimit(1)
            }
            .font(.system(size: 12))
            .foregroundStyle(PrismTheme.Colors.textSecondary)
            .frame(width: HubColumns.app, alignment: .leading)

            ProfileStatusLabel(profile: profile)
                .frame(width: HubColumns.status, alignment: .leading)

            Button(profile.primaryActionTitle(running: isRunning)) {
                // A running instance needs --new-window, otherwise this
                // just refocuses and looks dead.
                store.launch(profile, newWindow: isRunning)
            }
            .buttonStyle(PrismButtonStyle(kind: isSelected || hovering ? .secondary : .plain))
            .frame(width: HubColumns.action, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(shape.fill(isSelected ? PrismTheme.Colors.accent.opacity(0.08)
                                          : (hovering ? PrismTheme.Colors.hover : .clear)))
        .overlay(shape.strokeBorder(dropTargeted ? profile.accentColor
                                                 : (isSelected ? PrismTheme.Colors.accent.opacity(0.25) : .clear),
                                    lineWidth: 1))
        .contentShape(shape)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { store.launch(profile, newWindow: isRunning) }
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
        .contextMenu {
            ProfileMenuItems(profile: profile, onEdit: onEdit, onDelete: onDelete,
                             onOptions: { showingLaunchOptions = true })
        }
        .popover(isPresented: $showingLaunchOptions, arrowEdge: .bottom) {
            LaunchOptionsView(profile: profile)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        // Drag onto a group in the sidebar to file it there.
        .draggable(profile.id) {
            HStack(spacing: 8) {
                Circle().fill(profile.accentColor).frame(width: 8, height: 8)
                Text(profile.displayName).font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(PrismTheme.Colors.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .help(profile.opensProjectFolder ? "Drop a folder here to open it in this profile" : "")
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard profile.opensProjectFolder, let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.hasDirectoryPath || FileManager.default.isDirectory(url) else { return }
            DispatchQueue.main.async {
                store.launch(profile, projectPath: url.path)
            }
        }
        return true
    }
}

/// "Running · 281 MB", "Copying…" or "Idle · 2 days ago".
@MainActor
struct ProfileStatusLabel: View {
    @EnvironmentObject var store: ProfileStore
    let profile: CursorProfile

    var body: some View {
        HStack(spacing: 7) {
            if store.duplicating.contains(profile.folderName) {
                ProgressView().controlSize(.mini)
                Text("Copying…")
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
            } else if store.isRunning(profile) {
                LiveDot()
                Text("Running")
                    .fontWeight(.medium)
                    .foregroundStyle(PrismTheme.Colors.emerald)
                let live = store.liveMemory[profile.folderName] ?? 0
                if live > 0 {
                    Text(Format.bytes(Int64(live)))
                        .monospacedDigit()
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                }
            } else {
                Text(profile.lastLaunchedAt == nil ? "Idle" : "Idle · \(Format.relative(profile.lastLaunchedAt))")
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
    }
}

// MARK: - Launch options popover

@MainActor
struct LaunchOptionsView: View {
    @EnvironmentObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    let profile: CursorProfile

    @State private var memoryMB: Int = 16384
    @State private var projectPath: String = ""
    @State private var newWindow = false

    private var isCursorProfile: Bool { profile.normalizedApp == CursorProfile.appCursor }
    /// Apps that never open a project folder (Claude Desktop, Grok Bot).
    private var isDesktopProfile: Bool { !profile.opensProjectFolder }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 10) {
                PrismLogoView(size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Launch \"\(profile.displayName)\"")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PrismTheme.Colors.textPrimary)
                    Text("Quick launch configuration")
                        .font(.system(size: 10))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                }
            }

            Divider().overlay(PrismTheme.Colors.border)

            // Memory (Cursor only)
            VStack(alignment: .leading, spacing: 4) {
                Text("Memory limit")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PrismTheme.Colors.textSecondary)
                HStack(spacing: 6) {
                    TextField("MB", value: $memoryMB, format: .number.grouping(.never))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.Colors.cyan)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(PrismTheme.Colors.bg)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(PrismTheme.Colors.border, lineWidth: 0.5))
                        .frame(width: 80)
                        .disabled(!isCursorProfile)
                    Text("MB")
                        .font(.system(size: 10))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                }
            }
            .opacity(isCursorProfile ? 1.0 : 0.45)

            // Project (unused by Desktop)
            VStack(alignment: .leading, spacing: 4) {
                Text("Project folder")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PrismTheme.Colors.textSecondary)
                HStack(spacing: 6) {
                    TextField("Optional", text: $projectPath)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.Colors.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(PrismTheme.Colors.bg)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(PrismTheme.Colors.border, lineWidth: 0.5))
                        .disabled(isDesktopProfile)
                    Button("…") { pickFolder() }
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(PrismTheme.Colors.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(PrismTheme.Colors.border, lineWidth: 0.5))
                        .buttonStyle(.plain)
                        .disabled(isDesktopProfile)
                }
            }
            .opacity(isDesktopProfile ? 0.45 : 1.0)

            Toggle(isOn: $newWindow) {
                Text("Force a new window")
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textSecondary)
            }
            .toggleStyle(.checkbox)

            Divider().overlay(PrismTheme.Colors.border)

            HStack {
                Button("Cancel") { dismiss() }
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                Spacer()
                Button("Launch") {
                    store.launch(
                        profile,
                        projectPath: projectPath.isEmpty ? nil : projectPath,
                        memoryMB: max(512, memoryMB),
                        newWindow: newWindow
                    )
                    dismiss()
                }
                .buttonStyle(PrismButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(PrismTheme.Colors.surface)
        .onAppear {
            memoryMB = profile.defaultMemoryMB
            projectPath = profile.defaultProjectPath ?? ""
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

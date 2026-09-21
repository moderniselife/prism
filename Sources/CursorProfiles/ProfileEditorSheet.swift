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
    @State private var colorHex = AccentPalette.all[0].hex
    @State private var memoryMB = 16384
    @State private var projectPath = ""

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var previewColor: Color { Color(hex: colorHex) ?? .accentColor }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var canSave: Bool { !trimmedName.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    previewStrip
                    detailsSection
                    resourcesSection
                    projectSection
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(width: 560, height: 600)
        .background(PrismTheme.Colors.bg)
        .onAppear(perform: populate)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "Edit Profile" : "New Profile")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PrismTheme.Colors.textPrimary)
                Text("Each profile is an isolated Cursor instance.")
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
                Text("\(formatGB(memoryMB)) limit\(projectPath.isEmpty ? "" : " · \((projectPath as NSString).abbreviatingWithTildeInPath)")")
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

    private var resourcesSection: some View {
        section(title: "Resources") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Memory limit — passed to Cursor as --max-memory.")
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
                    Text("MB")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                }
            }
        }
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
                     ? "Built-in profile — ~/Library/Application Support/Cursor"
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
        case .edit(let profile):
            name = profile.displayName
            colorHex = profile.colorHex
            memoryMB = profile.defaultMemoryMB
            projectPath = profile.defaultProjectPath ?? ""
        }
    }

    private func save() {
        let trimmedProject = projectPath.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .create:
            let created = store.createProfile(
                displayName: trimmedName,
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

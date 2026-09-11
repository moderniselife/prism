import SwiftUI

// MARK: - Create / edit sheet

struct ProfileEditorSheet: View {
    enum Mode {
        case create
        case edit(CursorProfile)
    }

    @EnvironmentObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    @State private var name = ""
    @State private var emoji = emojiChoices[0]
    @State private var colorHex = AccentPalette.all[0].hex
    @State private var memoryMB = 16384
    @State private var projectPath = ""

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var previewColor: Color { Color(hex: colorHex) ?? .accentColor }

    var body: some View {
        VStack(spacing: 0) {
            // Live preview header
            HStack(spacing: 12) {
                Text(emoji)
                    .font(.system(size: 34))
                    .frame(width: 58, height: 58)
                    .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 14))
                Text(name.isEmpty ? "New Profile" : name)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
            }
            .padding(18)
            .background(
                LinearGradient(colors: [previewColor, previewColor.opacity(0.65)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )

            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("e.g. Work, Personal, Experiments"))

                    LabeledContent("Icon") {
                        emojiGrid
                    }
                    LabeledContent("Color") {
                        colorSwatches
                    }
                }

                Section("Launch defaults") {
                    LabeledContent("Memory limit") {
                        HStack(spacing: 6) {
                            TextField("MB", value: $memoryMB, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Text("MB").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Project folder") {
                        HStack(spacing: 6) {
                            TextField("Optional", text: $projectPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Choose…") { pickFolder() }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if case .edit(let profile) = mode {
                    Text(profile.isSystem
                         ? "Built-in profile — ~/Library/Application Support/Cursor"
                         : "Folder: \(profile.folderName)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Create Profile") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 480, height: 520)
        .onAppear(perform: populate)
    }

    private var emojiGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 10), spacing: 4) {
            ForEach(emojiChoices, id: \.self) { choice in
                Button {
                    emoji = choice
                } label: {
                    Text(choice)
                        .font(.system(size: 17))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(emoji == choice ? previewColor.opacity(0.3) : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(emoji == choice ? previewColor : .clear, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var colorSwatches: some View {
        HStack(spacing: 6) {
            ForEach(AccentPalette.all) { swatch in
                Button {
                    colorHex = swatch.hex
                } label: {
                    Circle()
                        .fill(swatch.color)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle().strokeBorder(.white, lineWidth: colorHex == swatch.hex ? 2 : 0)
                        )
                        .shadow(color: swatch.color.opacity(colorHex == swatch.hex ? 0.6 : 0), radius: 3)
                }
                .buttonStyle(.plain)
                .help(swatch.name)
            }
        }
    }

    private func populate() {
        switch mode {
        case .create:
            memoryMB = store.defaultMemoryMB
            colorHex = AccentPalette.random().hex
        case .edit(let profile):
            name = profile.displayName
            emoji = profile.emoji
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
                displayName: name,
                emoji: emoji,
                colorHex: colorHex,
                memoryMB: max(512, memoryMB),
                defaultProjectPath: trimmedProject.isEmpty ? nil : trimmedProject
            )
            if created != nil { dismiss() }
        case .edit(let original):
            var updated = original
            updated.displayName = name.trimmingCharacters(in: .whitespaces)
            updated.emoji = emoji
            updated.colorHex = colorHex
            updated.defaultMemoryMB = max(512, memoryMB)
            updated.defaultProjectPath = trimmedProject.isEmpty ? nil : trimmedProject
            store.update(updated)
            dismiss()
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

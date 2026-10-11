import SwiftUI

@MainActor
struct SettingsView: View {
    @EnvironmentObject var store: ProfileStore

    var body: some View {
        Form {
            Section("Cursor") {
                LabeledContent("Detected path") {
                    Text(store.resolvedCursorPath ?? "Not found")
                        .foregroundStyle(store.resolvedCursorPath == nil ? PrismTheme.Colors.red : PrismTheme.Colors.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("Custom path") {
                    HStack(spacing: 6) {
                        TextField("Leave empty for auto-detect", text: store.binding(\.customCursorPath))
                            .textFieldStyle(.roundedBorder)
                        Button("Browse...") { pickExecutable() }
                    }
                }
            }

            Section("Claude Code (CLI)") {
                LabeledContent("Detected path") {
                    Text(store.resolvedCodePath ?? "Not found")
                        .foregroundStyle(store.resolvedCodePath == nil ? PrismTheme.Colors.red : PrismTheme.Colors.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("Custom path") {
                    HStack(spacing: 6) {
                        TextField("Leave empty for auto-detect", text: store.binding(\.customCodePath))
                            .textFieldStyle(.roundedBorder)
                        Button("Browse...") { pickExecutable(kind: .code) }
                    }
                }
            }

            Section("Claude Desktop (app)") {
                LabeledContent("Detected path") {
                    Text(store.resolvedDesktopPath ?? "Not found")
                        .foregroundStyle(store.resolvedDesktopPath == nil ? PrismTheme.Colors.red : PrismTheme.Colors.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("Custom path") {
                    HStack(spacing: 6) {
                        TextField("Leave empty for auto-detect", text: store.binding(\.customDesktopPath))
                            .textFieldStyle(.roundedBorder)
                        Button("Browse...") { pickExecutable(kind: .desktop) }
                    }
                }
            }

            Section("New profile defaults") {
                LabeledContent("Memory limit") {
                    HStack(spacing: 6) {
                        TextField("MB", value: store.binding(\.defaultMemoryMB), format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Text("MB").foregroundStyle(PrismTheme.Colors.textTertiary)
                    }
                }
            }

            Section("Storage") {
                LabeledContent("Profiles folder") {
                    HStack(spacing: 6) {
                        Text((store.profilesDir.path as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(PrismTheme.Colors.textSecondary)
                            .textSelection(.enabled)
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([store.profilesDir])
                        }
                    }
                }
                Button("Rescan Profiles") { store.reload() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private enum ExeKind {
        case cursor, code, desktop
    }

    private func pickExecutable() {
        pickExecutable(kind: .cursor)
    }

    private func pickExecutable(kind: ExeKind) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Use"
        if panel.runModal() == .OK, let url = panel.url {
            var path = url.path
            if path.hasSuffix(".app") {
                let exeName: String = {
                    switch kind {
                    case .cursor: return "Cursor"
                    case .code: return "claude"
                    case .desktop: return "Claude"
                    }
                }()
                path += "/Contents/MacOS/\(exeName)"
            }
            switch kind {
            case .cursor: store.customCursorPath = path
            case .code: store.customCodePath = path
            case .desktop: store.customDesktopPath = path
            }
        }
    }
}

extension ProfileStore {
    func binding<T>(_ keyPath: ReferenceWritableKeyPath<ProfileStore, T>) -> Binding<T> {
        Binding(
            get: { self[keyPath: keyPath] },
            set: { self[keyPath: keyPath] = $0; self.objectWillChange.send() }
        )
    }
}

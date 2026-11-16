import SwiftUI

// MARK: - Detail panel for the selected profile

@MainActor
struct ProfileInspector: View {
    @EnvironmentObject var store: ProfileStore
    let profile: CursorProfile
    var onEdit: () -> Void
    var onDelete: () -> Void

    @State private var showingLaunchOptions = false

    private var isRunning: Bool { store.isRunning(profile) }
    private var liveBytes: UInt64 { store.liveMemory[profile.folderName] ?? 0 }
    private var displayPID: Int32? {
        store.runningPIDs[profile.folderName]?.first(where: { $0 > 0 })
    }
    private var dataPath: String { store.directory(for: profile).path }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    divider
                    if isRunning { liveSection } else { activitySection }
                    divider
                    profileSection
                    divider
                    brainSection
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            footerActions
        }
        .frame(maxHeight: .infinity)
        .background(PrismTheme.Colors.panel)
        .overlay(alignment: .leading) {
            Rectangle().fill(PrismTheme.Colors.border).frame(width: 1)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Spacer()
            Menu {
                ProfileMenuItems(profile: profile, onEdit: onEdit, onDelete: onDelete,
                                 onOptions: { showingLaunchOptions = true })
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PrismTheme.Colors.textSecondary)
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PrismTheme.Colors.borderSubtle).frame(height: 1)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                AppGlyph(app: profile.normalizedApp, size: 22)
                    .foregroundStyle(profile.accentColor)
                    .frame(width: 44, height: 44)
                    .background(profile.accentColor.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(PrismTheme.Colors.textPrimary)
                        .lineLimit(2)
                    Text(profile.isSystem ? "\(profile.appLabel) · Default profile" : profile.appLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                }
            }

            HStack(spacing: 8) {
                Button {
                    store.launch(profile, newWindow: isRunning)
                } label: {
                    Text(profile.primaryActionTitle(running: isRunning))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrismButtonStyle(kind: .primary, height: 32))
                .keyboardShortcut(.defaultAction)

                if isRunning {
                    Button("Quit") { store.quit(profile) }
                        .buttonStyle(PrismButtonStyle(kind: .secondary, height: 32))
                } else {
                    Button("Options…") { showingLaunchOptions = true }
                        .buttonStyle(PrismButtonStyle(kind: .secondary, height: 32))
                        .popover(isPresented: $showingLaunchOptions, arrowEdge: .bottom) {
                            LaunchOptionsView(profile: profile)
                        }
                }
            }
        }
        .padding(.top, 22)
    }

    // MARK: Sections

    private var liveSection: some View {
        section("Live") {
            keyValue("Status") {
                HStack(spacing: 7) {
                    LiveDot()
                    Text("Running").fontWeight(.medium).foregroundStyle(PrismTheme.Colors.emerald)
                }
            }
            keyValue("Memory") {
                Text(liveBytes > 0
                     ? Format.bytes(Int64(liveBytes)) + (profile.hasMemoryCap ? " of \(profile.memoryCapLabel)" : "")
                     : "Measuring…")
                    .monospacedDigit()
            }
            if let cpu = store.liveCPU[profile.folderName] {
                keyValue("CPU") { Text(String(format: "%.0f%%", cpu)).monospacedDigit() }
            }
            let windows = store.windows(for: profile)
            if windows > 0 {
                keyValue("Windows") { Text("\(windows)").monospacedDigit() }
            }
            if let pid = displayPID {
                keyValue("Process") { Text("\(pid)").monospacedDigit() }
            }
        }
    }

    private var activitySection: some View {
        section("Activity") {
            keyValue("Status") { Text("Idle").foregroundStyle(PrismTheme.Colors.textSecondary) }
            keyValue("Last used") {
                Text(profile.lastLaunchedAt == nil ? "Never" : Format.relative(profile.lastLaunchedAt))
            }
        }
    }

    private var profileSection: some View {
        section("Profile") {
            keyValue("Group") {
                GroupPicker(groupID: Binding(
                    get: { profile.groupID },
                    set: { store.setGroup($0, for: [profile.id]) }))
            }
            keyValue("Data") {
                Text(profile.isSystem ? "Default location" : (dataPath as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(dataPath)
                    .textSelection(.enabled)
            }
            if profile.opensProjectFolder {
                keyValue("Project") {
                    Text(profile.defaultProjectPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "None")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(profile.defaultProjectPath == nil
                                         ? PrismTheme.Colors.textTertiary : PrismTheme.Colors.textPrimary)
                }
            }
            if profile.hasMemoryCap {
                keyValue("Memory cap") { Text(profile.memoryCapLabel) }
            }
            keyValue("On disk") { Text(Format.bytes(store.sizes[profile.folderName])).monospacedDigit() }
            keyValue("Account") { Text("Its own sign-in") }
        }
    }

    @ViewBuilder
    private var brainSection: some View {
        section("Second brain") {
            VStack(alignment: .leading, spacing: 12) {
                Text(brainBlurb)
                    .font(.system(size: 12))
                    .foregroundStyle(PrismTheme.Colors.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                brainButton
                if let message = store.brainMessage {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var hasPersonalBrain: Bool { store.brainStatus?.personalExists == true }

    private var brainBlurb: String {
        if profile.normalizedApp == CursorProfile.appGrokBot {
            return "Grok agents run in the cloud. Paste the Brainium snippet into an agent's instructions to share memory with your other apps."
        }
        if hasPersonalBrain {
            return "Connect this profile so its agents read and write the same memory as your other apps."
        }
        return "Set up Brainium in Settings to give every profile one shared memory."
    }

    @ViewBuilder
    private var brainButton: some View {
        if profile.normalizedApp == CursorProfile.appGrokBot {
            Button {
                store.copyGrokBrainSnippet()
            } label: {
                Label("Copy snippet", systemImage: "doc.on.doc")
            }
            .buttonStyle(PrismButtonStyle(kind: .secondary, height: 30))
            .disabled(store.brainBusy)
        } else if hasPersonalBrain {
            Button {
                store.wireBrain(profile)
            } label: {
                Label("Connect this profile", systemImage: "link")
            }
            .buttonStyle(PrismButtonStyle(kind: .secondary, height: 30))
            .disabled(store.brainBusy)
        } else {
            Button("Open Settings") { PrismSettings.open(.secondBrain) }
                .buttonStyle(PrismButtonStyle(kind: .secondary, height: 30))
        }
    }

    // MARK: Footer

    private var footerActions: some View {
        VStack(alignment: .leading, spacing: 2) {
            footerButton(profile.copyActionTitle, icon: "arrow.right") {
                store.copyToNewProfile(profile)
            }
            .disabled(store.duplicating.contains(profile.folderName))
            footerButton("Show data folder", icon: "folder") {
                store.revealInFinder(profile)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(PrismTheme.Colors.borderSubtle).frame(height: 1)
        }
    }

    private func footerButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .foregroundStyle(PrismTheme.Colors.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Building blocks

    private var divider: some View {
        Rectangle()
            .fill(PrismTheme.Colors.borderSubtle)
            .frame(height: 1)
            .padding(.top, 20)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PrismTheme.Colors.textTertiary)
                .padding(.bottom, 2)
            content()
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func keyValue<Value: View>(_ key: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .foregroundStyle(PrismTheme.Colors.textTertiary)
                .frame(width: 84, alignment: .leading)
            value()
                .foregroundStyle(PrismTheme.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
    }
}

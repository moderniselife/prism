import AppKit
import SwiftUI

// MARK: - Settings window
//
// Prism's own window rather than SwiftUI's `Settings` scene: SettingsLink
// and showSettingsWindow: silently did nothing from the hub sidebar, and a
// window we own can also be opened on a given pane (Second brain card →
// Second brain, "Check for Updates…" → About).

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, apps, groups, secondBrain, endpoint, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .apps: return "Apps"
        case .groups: return "Groups"
        case .secondBrain: return "Second brain"
        case .endpoint: return "Endpoint"
        case .about: return "About & updates"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "New profiles, storage and shortcuts"
        case .apps: return "Where Prism finds each app"
        case .groups: return "Projects, clients or categories for your profiles"
        case .secondBrain: return "Memory that follows you across accounts"
        case .endpoint: return "One API for every account"
        case .about: return "Version, updates and source"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .apps: return "square.grid.2x2"
        case .groups: return "folder"
        case .secondBrain: return "brain"
        case .endpoint: return "point.3.connected.trianglepath.dotted"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var pane: SettingsPane = .general
}

@MainActor
enum PrismSettings {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("prism-settings")
    static let model = SettingsModel()
    private static var window: NSWindow?

    /// Open Settings, optionally on a given pane.
    static func open(_ pane: SettingsPane? = nil) {
        if let pane { model.pane = pane }
        let win = window ?? makeWindow()
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    /// Open About & updates and check GitHub right away.
    static func checkForUpdates() {
        open(.about)
        Task { await PrismSelfUpdater.shared.checkForRelease(force: true) }
    }

    private static func makeWindow() -> NSWindow {
        let root = SettingsRoot()
            .environmentObject(ProfileStore.shared)
            .environmentObject(model)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.identifier = windowIdentifier
        win.title = "Settings"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.contentMinSize = NSSize(width: 780, height: 520)
        win.contentView = NSHostingView(rootView: root)
        win.center()
        win.setFrameAutosaveName("PrismSettingsWindow")
        return win
    }
}

// MARK: - Layout

@MainActor
struct SettingsRoot: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(PrismTheme.Colors.bg)
        }
        .ignoresSafeArea(.container, edges: .top)
        .tint(PrismTheme.Colors.accent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Room for the traffic lights; drags the window.
            Color.clear.frame(height: 52).windowDragRegion()

            Text("Settings")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PrismTheme.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            ForEach(SettingsPane.allCases) { pane in
                item(pane)
            }

            Spacer(minLength: 12)

            Button { model.pane = .about } label: {
                Text("Prism \(BuildInfo.version) · \(BuildInfo.commit)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(PrismTheme.Colors.textMuted)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .help("About & updates")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(PrismTheme.Colors.bgAlt)
        .overlay(alignment: .trailing) {
            Rectangle().fill(PrismTheme.Colors.border).frame(width: 1)
        }
    }

    private func item(_ pane: SettingsPane) -> some View {
        let selected = model.pane == pane
        return Button { model.pane = pane } label: {
            HStack(spacing: 10) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 13))
                    .frame(width: 16)
                Text(pane.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                Spacer(minLength: 4)
                if pane == .about, PrismSelfUpdater.shared.available != nil {
                    Circle().fill(PrismTheme.Colors.accent).frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(selected ? PrismTheme.Colors.textPrimary : PrismTheme.Colors.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? PrismTheme.Colors.surfaceHigh : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(model.pane.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PrismTheme.Colors.textPrimary)
            Text(model.pane.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(PrismTheme.Colors.textTertiary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(height: 52)
        .windowDragRegion()
        .overlay(alignment: .bottom) {
            Rectangle().fill(PrismTheme.Colors.borderSubtle).frame(height: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.pane {
        case .general: GeneralSettingsPane()
        case .apps: AppsSettingsPane()
        case .groups: GroupsSettingsPane()
        case .secondBrain: SecondBrainSettingsView()
        case .endpoint: EndpointSettingsView()
        case .about: AboutSettingsPane()
        }
    }
}

// MARK: - Building blocks

/// Scrolling page of setting groups, kept to a readable width.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                content()
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A titled card of rows.
struct SettingsGroup<Content: View, Accessory: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PrismTheme.Colors.textSecondary)
                Spacer()
                accessory()
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content()
            }
            .background(PrismTheme.Colors.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PrismTheme.Colors.border, lineWidth: 1))

            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

extension SettingsGroup where Accessory == EmptyView {
    init(title: String, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.accessory = { EmptyView() }
        self.content = content
    }
}

/// Label (and optional detail) on the left, a control on the right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(PrismTheme.Colors.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 46)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(PrismTheme.Colors.borderSubtle)
            .frame(height: 1)
            .padding(.leading, 14)
    }
}

extension View {
    /// Prism's flat text field.
    func prismField(width: CGFloat? = nil) -> some View {
        self
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(width: width, height: 28)
            .background(PrismTheme.Colors.surfaceAlt, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(PrismTheme.Colors.border, lineWidth: 1))
    }
}

// MARK: - General

@MainActor
struct GeneralSettingsPane: View {
    @EnvironmentObject var store: ProfileStore
    @AppStorage(HubGrouping.storageKey) private var grouping = HubGrouping.status.rawValue

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Profile list") {
                SettingsRow(title: "Arrange profiles", detail: "By status shows Running and Not running; by group follows your groups.") {
                    Picker("", selection: $grouping) {
                        ForEach(HubGrouping.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }

            SettingsGroup(title: "New profiles",
                          footer: "Passed to Cursor as --max-memory. Each profile can override it.") {
                SettingsRow(title: "Cursor memory limit") {
                    HStack(spacing: 6) {
                        TextField("MB", value: store.binding(\.defaultMemoryMB), format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                            .prismField(width: 90)
                        Text("MB")
                            .font(.system(size: 12))
                            .foregroundStyle(PrismTheme.Colors.textTertiary)
                    }
                }
            }

            SettingsGroup(title: "Shortcuts") {
                shortcut("Quick Switch, from any app", "⌥Space")
                SettingsDivider()
                shortcut("Search profiles", "⌘K")
                SettingsDivider()
                shortcut("New profile", "⌘N")
                SettingsDivider()
                shortcut("Switch endpoint identity", "⌥⌘I")
                SettingsDivider()
                shortcut("Settings", "⌘,")
            }

            SettingsGroup(title: "Storage") {
                SettingsRow(title: "Profiles folder",
                            detail: (store.profilesDir.path as NSString).abbreviatingWithTildeInPath) {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.profilesDir])
                    }
                    .buttonStyle(PrismButtonStyle(kind: .secondary, height: 28))
                }
                SettingsDivider()
                SettingsRow(title: "Rescan profiles", detail: "Pick up folders added or removed outside Prism.") {
                    Button("Rescan") { store.reload() }
                        .buttonStyle(PrismButtonStyle(kind: .secondary, height: 28))
                }
            }
        }
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        SettingsRow(title: title) {
            Text(keys)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PrismTheme.Colors.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(PrismTheme.Colors.surfaceAlt, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}

// MARK: - Apps

@MainActor
struct AppsSettingsPane: View {
    @EnvironmentObject var store: ProfileStore

    var body: some View {
        SettingsPage {
            ForEach(CursorProfile.allApps, id: \.self) { app in
                SettingsGroup(title: CursorProfile.label(for: app)) {
                    SettingsRow(title: "Found at") {
                        let found = resolved(app)
                        Text(found.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not found")
                            .font(.system(size: 12))
                            .foregroundStyle(found == nil ? PrismTheme.Colors.red : PrismTheme.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Custom path") {
                        HStack(spacing: 6) {
                            TextField("Find automatically", text: customBinding(app))
                                .prismField(width: 260)
                            Button("Choose…") { pick(app) }
                                .buttonStyle(PrismButtonStyle(kind: .secondary, height: 28))
                        }
                    }
                }
            }
        }
    }

    private func resolved(_ app: String) -> String? {
        switch app {
        case CursorProfile.appClaudeCode: return store.resolvedCodePath
        case CursorProfile.appClaudeDesktop: return store.resolvedDesktopPath
        case CursorProfile.appGrokBot: return store.resolvedGrokPath
        default: return store.resolvedCursorPath
        }
    }

    private func customBinding(_ app: String) -> Binding<String> {
        switch app {
        case CursorProfile.appClaudeCode: return store.binding(\.customCodePath)
        case CursorProfile.appClaudeDesktop: return store.binding(\.customDesktopPath)
        case CursorProfile.appGrokBot: return store.binding(\.customGrokPath)
        default: return store.binding(\.customCursorPath)
        }
    }

    private func pick(_ app: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Use"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var path = url.path
        if path.hasSuffix(".app") {
            let exe: String
            switch app {
            case CursorProfile.appClaudeCode: exe = "claude"
            case CursorProfile.appClaudeDesktop: exe = "Claude"
            case CursorProfile.appGrokBot: exe = GrokLauncher.executableName
            default: exe = "Cursor"
            }
            path += "/Contents/MacOS/\(exe)"
        }
        customBinding(app).wrappedValue = path
    }
}

// MARK: - Groups

@MainActor
struct GroupsSettingsPane: View {
    @EnvironmentObject var store: ProfileStore

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Groups",
                          footer: "A group can hold profiles from any app. Deleting a group keeps its profiles; they just become ungrouped.",
                          accessory: {
                              Button {
                                  if let name = GroupPrompt.ask(title: "New group") {
                                      store.addGroup(name: name)
                                  }
                              } label: {
                                  Label("New group", systemImage: "plus")
                              }
                              .buttonStyle(PrismButtonStyle(kind: .plain, height: 24))
                          }) {
                if store.groups.isEmpty {
                    SettingsRow(title: "No groups yet",
                                detail: "Make one for each project, client or kind of work, then file profiles under it from their menu, the detail panel or by dragging them onto the group in the sidebar.") {
                        EmptyView()
                    }
                } else {
                    ForEach(Array(store.groups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 { SettingsDivider() }
                        GroupSettingsRow(group: group, index: index, count: store.groups.count)
                    }
                }
            }
        }
    }
}

@MainActor
private struct GroupSettingsRow: View {
    @EnvironmentObject var store: ProfileStore
    let group: ProfileGroup
    let index: Int
    let count: Int
    @State private var name = ""

    var body: some View {
        HStack(spacing: 10) {
            GroupColorMenu(group: group)
            TextField("Name", text: $name)
                .prismField()
                .onSubmit(commit)
                .onAppear { name = group.name }
                .onChange(of: group.name) { _, new in name = new }
            Text(profileCount)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(PrismTheme.Colors.textTertiary)
                .frame(width: 70, alignment: .trailing)
            Button { store.moveGroup(group.id, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .help("Move up")
            Button { store.moveGroup(group.id, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(index == count - 1)
                .help("Move down")
            Button { store.deleteGroup(group.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete group (its profiles are kept)")
        }
        .font(.system(size: 11))
        .foregroundStyle(PrismTheme.Colors.textSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .onDisappear(perform: commit)
    }

    private var profileCount: String {
        let n = store.profiles(in: group.id).count
        return n == 1 ? "1 profile" : "\(n) profiles"
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != group.name else {
            name = group.name
            return
        }
        var g = group
        g.name = trimmed
        store.updateGroup(g)
    }
}

// MARK: - About & updates

@MainActor
struct AboutSettingsPane: View {
    @ObservedObject private var updater = PrismSelfUpdater.shared

    private var repoURL: URL { URL(string: "https://github.com/\(PrismSelfUpdater.repo)")! }
    private var releasesURL: URL { URL(string: "https://github.com/\(PrismSelfUpdater.repo)/releases")! }

    var body: some View {
        SettingsPage {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prism")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(PrismTheme.Colors.textPrimary)
                    Text("Version \(BuildInfo.version)")
                        .font(.system(size: 13))
                        .foregroundStyle(PrismTheme.Colors.textSecondary)
                    Text(buildLine)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                        .textSelection(.enabled)
                }
            }

            SettingsGroup(title: "Updates") {
                SettingsRow(title: statusTitle, detail: statusDetail) {
                    updateAction
                }
                SettingsDivider()
                SettingsRow(title: "Check automatically", detail: "Looks for a new release on GitHub a few times a day.") {
                    Toggle("", isOn: $updater.autoCheck)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            if updater.replacedOnDisk {
                SettingsGroup(title: "This window") {
                    SettingsRow(title: "A newer build is installed",
                                detail: "Prism on disk was replaced while this copy was running.") {
                        Button("Relaunch") { updater.relaunch() }
                            .buttonStyle(PrismButtonStyle(kind: .primary, height: 28))
                    }
                }
            }

            SettingsGroup(title: "Source") {
                SettingsRow(title: "GitHub", detail: PrismSelfUpdater.repo) {
                    Button("Open") { NSWorkspace.shared.open(repoURL) }
                        .buttonStyle(PrismButtonStyle(kind: .secondary, height: 28))
                }
                SettingsDivider()
                SettingsRow(title: "All releases", detail: "Downloads and what changed in each version.") {
                    Button("Open") { NSWorkspace.shared.open(releasesURL) }
                        .buttonStyle(PrismButtonStyle(kind: .secondary, height: 28))
                }
            }
        }
    }

    private var buildLine: String {
        let day = BuildInfo.buildDate.prefix(10)
        return day.isEmpty ? "Build \(BuildInfo.commit)" : "Build \(BuildInfo.commit) · \(day)"
    }

    private var statusTitle: String {
        if let progress = updater.progress { return progress }
        if updater.checking { return "Checking GitHub…" }
        if let release = updater.available { return "Prism \(release.version) is available" }
        if updater.checkError != nil { return "Couldn't check for updates" }
        if updater.lastChecked != nil { return "Prism is up to date" }
        return "Updates"
    }

    private var statusDetail: String? {
        if let error = updater.lastError, updater.progress == nil { return error }
        if let error = updater.checkError, !updater.checking { return error }
        if let release = updater.available {
            return release.zipURL == nil
                ? "You have \(BuildInfo.version). This release has no Mac download yet; open it on GitHub."
                : "You have \(BuildInfo.version). Prism downloads it, replaces this app and relaunches."
        }
        if let checked = updater.lastChecked {
            let latest = updater.latestVersion.map { "Latest release \($0)" } ?? "Checked"
            return "\(latest) · checked \(checked.formatted(.relative(presentation: .named)))"
        }
        return "You have \(BuildInfo.version)."
    }

    @ViewBuilder
    private var updateAction: some View {
        if updater.progress != nil || updater.checking {
            ProgressView().controlSize(.small)
        } else if let release = updater.available {
            HStack(spacing: 6) {
                Button("What's new") { NSWorkspace.shared.open(release.pageURL) }
                    .buttonStyle(PrismButtonStyle(kind: .plain, height: 28))
                Button(release.zipURL == nil ? "Open on GitHub" : "Install and relaunch") {
                    Task { await updater.install() }
                }
                .buttonStyle(PrismButtonStyle(kind: .primary, height: 28))
            }
        } else {
            Button("Check for updates") {
                Task { await updater.checkForRelease(force: true) }
            }
            .buttonStyle(PrismButtonStyle(kind: .secondary, height: 28))
        }
    }
}

extension ProfileStore {
    /// A binding to one of the store's settings that also refreshes views.
    func binding<T>(_ keyPath: ReferenceWritableKeyPath<ProfileStore, T>) -> Binding<T> {
        Binding(
            get: { self[keyPath: keyPath] },
            set: { self[keyPath: keyPath] = $0; self.objectWillChange.send() }
        )
    }
}

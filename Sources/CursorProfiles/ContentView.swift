import SwiftUI

// MARK: - Filter & Sort

enum ProfileFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case active = "Active"
    case custom = "Custom" // non-built-in profiles (nothing here is sandboxed)
    case cursor = "Cursor"
    case code = "Code"
    case desktop = "Desktop"
    case grok = "Grok"

    var id: String { rawValue }

    /// Heading shown above the list.
    var title: String {
        switch self {
        case .all: return "All profiles"
        case .active: return "Running"
        case .custom: return "Custom"
        case .cursor: return "Cursor"
        case .code: return "Claude Code"
        case .desktop: return "Claude Desktop"
        case .grok: return "Grok Bot"
        }
    }

    /// The app a per-app filter shows, if any.
    var app: String? {
        switch self {
        case .cursor: return CursorProfile.appCursor
        case .code: return CursorProfile.appClaudeCode
        case .desktop: return CursorProfile.appClaudeDesktop
        case .grok: return CursorProfile.appGrokBot
        default: return nil
        }
    }
}

enum SortMode: String, CaseIterable, Identifiable {
    case name = "Name"
    case recent = "Recently Used"
    case size = "Size"
    var id: String { rawValue }
}

/// A titled group of rows ("Running", "Not running").
struct HubSection: Identifiable {
    let title: String
    let profiles: [CursorProfile]
    var id: String { title }
}

// MARK: - Main Hub Window
//
// Sidebar (filters, second brain, totals) | profile list | detail panel.
// The detail panel hides when the window is too narrow for three columns.

@MainActor
struct ContentView: View {
    @EnvironmentObject var store: ProfileStore
    @State private var search = ""
    @State private var sortMode: SortMode = .recent
    @State private var filter: ProfileFilter = .all
    @State private var selectedID: String?
    @State private var showingAdd = false
    @State private var editingProfile: CursorProfile?
    @State private var deletingProfile: CursorProfile?
    @State private var showSpotlight = false
    @FocusState private var isSearchFocused: Bool
    @State private var keyMonitor: Any?

    /// Below this width the detail panel is hidden.
    private static let inspectorMinWindowWidth: CGFloat = 1040

    private func matches(_ profile: CursorProfile, _ filter: ProfileFilter) -> Bool {
        switch filter {
        case .all: return true
        case .active: return store.isRunning(profile)
        case .custom: return !profile.isSystem
        default: return profile.normalizedApp == filter.app
        }
    }

    func count(_ filter: ProfileFilter) -> Int {
        store.profiles.filter { matches($0, filter) }.count
    }

    private var filtered: [CursorProfile] {
        var list = store.profiles.filter { matches($0, filter) }

        if !search.isEmpty {
            list = list.filter {
                $0.displayName.localizedCaseInsensitiveContains(search) ||
                $0.folderName.localizedCaseInsensitiveContains(search) ||
                $0.appLabel.localizedCaseInsensitiveContains(search) ||
                $0.normalizedApp.localizedCaseInsensitiveContains(search)
            }
        }

        list.sort { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            if a.isSystem != b.isSystem { return a.isSystem }
            switch sortMode {
            case .name:
                return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            case .recent:
                return (a.lastLaunchedAt ?? .distantPast) > (b.lastLaunchedAt ?? .distantPast)
            case .size:
                return (store.sizes[a.folderName] ?? 0) > (store.sizes[b.folderName] ?? 0)
            }
        }
        return list
    }

    private var sections: [HubSection] {
        let list = filtered
        let running = list.filter { store.isRunning($0) }
        let idle = list.filter { !store.isRunning($0) }
        var out: [HubSection] = []
        if !running.isEmpty { out.append(HubSection(title: "Running", profiles: running)) }
        if !idle.isEmpty { out.append(HubSection(title: "Not running", profiles: idle)) }
        return out
    }

    /// The selected profile, falling back to the first one listed.
    private var selectedProfile: CursorProfile? {
        if let id = selectedID, let match = store.profiles.first(where: { $0.folderName == id }) {
            return match
        }
        return sections.first?.profiles.first
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                HubSidebar(search: $search, filter: $filter,
                           searchFocus: $isSearchFocused, count: count)
                mainColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if geo.size.width >= Self.inspectorMinWindowWidth, let profile = selectedProfile {
                    ProfileInspector(profile: profile,
                                     onEdit: { editingProfile = profile },
                                     onDelete: { deletingProfile = profile })
                        .id(profile.folderName)
                        .frame(width: 320)
                }
            }
        }
        .background(PrismTheme.Colors.bg.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 860, minHeight: 560)
        .tint(PrismTheme.Colors.accent)
        .sheet(isPresented: $showingAdd) {
            ProfileEditorSheet(mode: .create, onClose: { showingAdd = false })
        }
        .sheet(item: $editingProfile) { profile in
            ProfileEditorSheet(mode: .edit(profile), onClose: { editingProfile = nil })
        }
        .sheet(isPresented: $showSpotlight) {
            SpotlightCommandBar()
                .environmentObject(store)
        }
        .confirmationDialog(
            "Delete \"\(deletingProfile?.displayName ?? "")\"?",
            isPresented: Binding(get: { deletingProfile != nil },
                                 set: { if !$0 { deletingProfile = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let p = deletingProfile { store.delete(p) }
                deletingProfile = nil
            }
        } message: {
            Text("The profile folder (\(Format.bytes(store.sizes[deletingProfile?.folderName ?? ""]))) will be moved to the Trash.")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } })
        ) {
            Button("OK", role: .cancel) { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .prismNewProfile)) { _ in
            showingAdd = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .prismQuickSwitch)) { _ in
            showSpotlight = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .prismFocusSearch)) { _ in
            isSearchFocused = true
        }
        .onAppear {
            store.refreshBrainStatus()
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if event.modifierFlags.contains(.option) && event.charactersIgnoringModifiers == " " {
                        showSpotlight.toggle()
                        return nil
                    }
                    return event
                }
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
    }

    // MARK: - Main column

    private var mainColumn: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 8) {
                if store.resolvedCursorPath == nil && count(.cursor) > 0 {
                    cursorMissingBanner
                }
                UpdateBanner()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if store.profiles.isEmpty {
                emptyState
            } else if sections.isEmpty {
                noMatches
            } else {
                columnHeader
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(sections) { section in
                            sectionHeader(section)
                            ForEach(section.profiles) { profile in
                                ProfileRow(
                                    profile: profile,
                                    isSelected: profile.folderName == selectedProfile?.folderName,
                                    onSelect: { selectedID = profile.folderName },
                                    onEdit: { editingProfile = profile },
                                    onDelete: { deletingProfile = profile }
                                )
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .background(PrismTheme.Colors.bg)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(filter.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PrismTheme.Colors.textPrimary)
            Text("\(filtered.count)")
                .font(.system(size: 13))
                .foregroundStyle(PrismTheme.Colors.textTertiary)
                .monospacedDigit()

            Spacer()

            Menu {
                Picker("Sort by", selection: $sortMode) {
                    ForEach(SortMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 4) {
                    Text(sortMode == .recent ? "Recent" : sortMode.rawValue)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 12))
                .foregroundStyle(PrismTheme.Colors.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort profiles")

            Button {
                showingAdd = true
            } label: {
                Label("New profile", systemImage: "plus")
            }
            .buttonStyle(PrismButtonStyle(kind: .primary, height: 30))
            .help("New profile (⌘N)")
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .frame(height: 52)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PrismTheme.Colors.borderSubtle).frame(height: 1)
        }
    }

    private var columnHeader: some View {
        HStack(spacing: HubColumns.spacing) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("App").frame(width: HubColumns.app, alignment: .leading)
            Text("Status").frame(width: HubColumns.status, alignment: .leading)
            Color.clear.frame(width: HubColumns.action, height: 1)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(PrismTheme.Colors.textTertiary)
        .padding(.horizontal, 30)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

    private func sectionHeader(_ section: HubSection) -> some View {
        HStack(spacing: 8) {
            Text(section.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PrismTheme.Colors.textPrimary)
            Text("\(section.profiles.count)")
                .font(.system(size: 12))
                .foregroundStyle(PrismTheme.Colors.textTertiary)
        }
        .padding(.horizontal, 32)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: 12) {
            PrismLogoView(size: 44)
                .opacity(0.9)
            Text("No profiles yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PrismTheme.Colors.textPrimary)
            Text("Each profile keeps its own sign-in, settings and history.")
                .font(.system(size: 12))
                .foregroundStyle(PrismTheme.Colors.textTertiary)
            Button {
                showingAdd = true
            } label: {
                Label("New profile", systemImage: "plus")
            }
            .buttonStyle(PrismButtonStyle(kind: .primary, height: 32))
            .keyboardShortcut(.defaultAction)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatches: some View {
        VStack(spacing: 10) {
            Text(!search.isEmpty ? "No profiles match “\(search)”" : (filter == .active ? "Nothing is running" : "Nothing here yet"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PrismTheme.Colors.textSecondary)
            if !search.isEmpty {
                Button("Clear search") { search = "" }
                    .buttonStyle(PrismButtonStyle(kind: .secondary))
            } else if filter != .all {
                Button("Show all profiles") { filter = .all }
                    .buttonStyle(PrismButtonStyle(kind: .secondary))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cursorMissingBanner: some View {
        HubBanner(icon: "exclamationmark.triangle", iconColor: PrismTheme.Colors.amber,
                  text: "Cursor wasn't found. Install it from cursor.com, or set its path in Settings.") {
            SettingsLink { Text("Open Settings") }
                .buttonStyle(PrismButtonStyle(kind: .secondary, height: 26))
        }
    }
}

// MARK: - Sidebar

@MainActor
struct HubSidebar: View {
    @EnvironmentObject var store: ProfileStore
    @Binding var search: String
    @Binding var filter: ProfileFilter
    var searchFocus: FocusState<Bool>.Binding
    var count: (ProfileFilter) -> Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the window's traffic lights.
            Color.clear.frame(height: 52)

            searchField

            VStack(spacing: 2) {
                item(.all) { symbol("square.stack") }
                item(.active) { symbol("waveform.path.ecg") }
                item(.custom) { symbol("person") }
            }
            .padding(.top, 16)

            Text("Apps")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PrismTheme.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.top, 20)
                .padding(.bottom, 6)

            VStack(spacing: 2) {
                ForEach([ProfileFilter.cursor, .code, .desktop, .grok]) { f in
                    item(f) { AppGlyph(app: f.app ?? "", size: 15) }
                }
            }

            Spacer(minLength: 16)

            brainCard
            footer
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(width: 228)
        .frame(maxHeight: .infinity)
        .background(PrismTheme.Colors.bgAlt)
        .overlay(alignment: .trailing) {
            Rectangle().fill(PrismTheme.Colors.border).frame(width: 1)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(PrismTheme.Colors.textPrimary)
                .focused(searchFocus)
            if search.isEmpty {
                Text("⌘K").font(.system(size: 11))
            } else {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .foregroundStyle(PrismTheme.Colors.textTertiary)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(PrismTheme.Colors.surfaceAlt, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13))
            .frame(width: 16, height: 16)
    }

    private func label(for f: ProfileFilter) -> String {
        f == .all ? "All profiles" : f.title
    }

    private func item<Icon: View>(_ f: ProfileFilter, @ViewBuilder icon: () -> Icon) -> some View {
        let selected = filter == f
        let n = count(f)
        return Button {
            filter = f
        } label: {
            HStack(spacing: 10) {
                icon()
                    .frame(width: 16)
                Text(label(for: f))
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                Spacer(minLength: 4)
                Text("\(n)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(f == .active && n > 0 ? PrismTheme.Colors.emerald : PrismTheme.Colors.textTertiary)
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

    // MARK: Second brain + totals

    private var brainOn: Bool { store.brainStatus?.personalExists == true }

    private var brainDetail: String {
        guard let status = store.brainStatus else { return "Not set up" }
        guard status.personalExists == true, let path = status.personalBrain else { return "No personal brain yet" }
        let pending = status.pending ?? 0
        let place = "Saving to \((path as NSString).abbreviatingWithTildeInPath)"
        return pending > 0 ? "\(pending) to file · \(place)" : place
    }

    private var brainCard: some View {
        SettingsLink {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "brain")
                        .font(.system(size: 12))
                        .foregroundStyle(PrismTheme.Colors.textSecondary)
                    Text("Second brain")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(PrismTheme.Colors.textPrimary)
                    Spacer(minLength: 4)
                    Circle()
                        .fill(brainOn ? PrismTheme.Colors.live : PrismTheme.Colors.textMuted)
                        .frame(width: 6, height: 6)
                    Text(brainOn ? "On" : "Off")
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                }
                Text(brainDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PrismTheme.Colors.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(PrismTheme.Colors.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Second brain settings")
    }

    private var footer: some View {
        let running = count(.active)
        return HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(running > 0
                     ? "\(running) running · \(Format.bytes(Int64(store.liveMemoryTotal)))"
                     : "Nothing running")
                Text("CPU \(store.systemCPU.map { String(format: "%.0f%%", $0) } ?? "—") · \(Format.bytes(Int64(store.physicalMemory))) RAM")
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(PrismTheme.Colors.textTertiary)
            .help("Live memory of running profiles · system CPU · installed RAM")

            Spacer(minLength: 4)

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(PrismTheme.Colors.textSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 4)
        .padding(.top, 10)
    }
}

// MARK: - Banner

/// Slim bordered notice row used for updates and setup problems.
struct HubBanner<Trailing: View>: View {
    let icon: String
    var iconColor: Color = PrismTheme.Colors.accentText
    let text: String
    var compact = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: compact ? 11 : 13))
                .foregroundStyle(iconColor)
            Text(text)
                .font(.system(size: compact ? 11 : 12))
                .foregroundStyle(PrismTheme.Colors.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 6 : 8)
        .background {
            if compact {
                Rectangle().fill(PrismTheme.Colors.accent.opacity(0.08))
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(PrismTheme.Colors.border, lineWidth: 1)
            }
        }
    }
}

// MARK: - Prism Logo (assets/logo.png, bundled by build.sh)

struct PrismLogoView: View {
    var size: CGFloat = 24

    var body: some View {
        if let url = Bundle.main.url(forResource: "logo", withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            // Fallback if the resource is missing — never blank.
            Triangle()
                .fill(
                    LinearGradient(
                        colors: [PrismTheme.Colors.cyan.opacity(0.8), PrismTheme.Colors.purple.opacity(0.6)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: size, height: size)
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Pending app update banner

/// Shown while Cursor / Claude Desktop / Grok Bot has an update staged that can't
/// install because profiles are still open. One click quits them, lets the
/// installer run, and reopens them.
@MainActor
struct UpdateBanner: View {
    @EnvironmentObject var store: ProfileStore
    var compact = false

    private var apps: [String] {
        [CursorProfile.appCursor, CursorProfile.appClaudeDesktop, CursorProfile.appGrokBot]
            .filter { store.pendingUpdates.contains($0) }
    }

    private func label(_ app: String) -> String {
        CursorProfile.label(for: app)
    }

    private func runningCount(_ app: String) -> Int {
        store.profiles.filter { $0.normalizedApp == app && store.isRunning($0) }.count
    }

    var body: some View {
        if let progress = store.updateProgress {
            HubBanner(icon: "arrow.triangle.2.circlepath", text: progress, compact: compact) {
                ProgressView().controlSize(.small)
            }
        } else {
            ForEach(apps, id: \.self) { app in
                let count = runningCount(app)
                HubBanner(icon: "arrow.up.circle",
                          text: count > 0
                            ? "A \(label(app)) update is ready. \(count) open profile\(count == 1 ? " is" : "s are") holding it."
                            : "A \(label(app)) update is ready. Waiting for its windows to close.",
                          compact: compact) {
                    Button("Restart to update") { store.restartToUpdate(app) }
                        .buttonStyle(PrismButtonStyle(kind: .tinted, height: compact ? 22 : 26))
                        .help("Quit every \(label(app)) profile, install the update, then reopen them")
                }
            }
        }
    }
}

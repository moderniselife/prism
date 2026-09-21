import SwiftUI
import UniformTypeIdentifiers

// MARK: - Filter & Sort

enum ProfileFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case active = "Active"
    case custom = "Custom" // non-built-in profiles (nothing here is sandboxed)

    var id: String { rawValue }
}

enum SortMode: String, CaseIterable, Identifiable {
    case name = "Name"
    case recent = "Recently Used"
    case size = "Size"
    var id: String { rawValue }
}

// MARK: - Main Hub Window

@MainActor
struct ContentView: View {
    @EnvironmentObject var store: ProfileStore
    @State private var search = ""
    @State private var sortMode: SortMode = .recent
    @State private var filter: ProfileFilter = .all
    @State private var showingAdd = false
    @State private var editingProfile: CursorProfile?
    @State private var deletingProfile: CursorProfile?
    @State private var showSpotlight = false
    @FocusState private var isSearchFocused: Bool

    private var filtered: [CursorProfile] {
        var list = store.profiles

        if !search.isEmpty {
            list = list.filter {
                $0.displayName.localizedCaseInsensitiveContains(search) ||
                $0.folderName.localizedCaseInsensitiveContains(search)
            }
        }

        switch filter {
        case .active:
            list = list.filter { store.isRunning($0) }
        case .custom:
            list = list.filter { !$0.isSystem }
        case .all:
            break
        }

        list.sort { a, b in
            if a.isSystem != b.isSystem { return a.isSystem }
            if a.isPinned != b.isPinned { return a.isPinned }
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

    private var runningCount: Int {
        store.profiles.filter { store.isRunning($0) }.count
    }

    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            filterBar
            mainContent
            statusBar
        }
        .background(PrismTheme.Colors.bg.ignoresSafeArea())
        .frame(minWidth: 860, minHeight: 560)
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

    // MARK: - Title Bar

    private var titleBar: some View {
        HStack(spacing: 0) {
            // Space for macOS traffic lights (close/minimize/zoom)
            // Standard position: ~20px from left, buttons are ~52px wide total
            Color.clear.frame(width: 72, height: 1)

            // Logo & title
            HStack(spacing: 8) {
                PrismLogoView(size: 24)
                Text("Prism")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(PrismTheme.Colors.textPrimary)
                Text("v\(PrismVersion.string)")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(PrismTheme.Colors.cyan)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(PrismTheme.Colors.cyan.opacity(0.15))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(PrismTheme.Colors.cyan.opacity(0.3), lineWidth: 0.5))
            }

            Spacer()

            // Center search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                TextField("Search profiles, tools, or folders...", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(PrismTheme.Colors.textPrimary)
                    .focused($isSearchFocused)
                Text("⌘K")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(PrismTheme.Colors.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(PrismTheme.Colors.border, lineWidth: 0.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(PrismTheme.Colors.bg.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerSmall))
            .overlay(RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerSmall).stroke(PrismTheme.Colors.border, lineWidth: 1))
            .frame(maxWidth: 400)

            Spacer()

            // Right controls
            HStack(spacing: 8) {
                Menu {
                    ForEach(SortMode.allCases) { mode in
                        Button { sortMode = mode } label: {
                            HStack {
                                Text(mode.rawValue)
                                if sortMode == mode { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(sortMode.rawValue)
                            .font(.system(size: 11))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(PrismTheme.Colors.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(PrismTheme.Colors.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(PrismTheme.Colors.border, lineWidth: 0.5))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    showingAdd = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("New Profile")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(PrismTheme.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        LinearGradient(
                            colors: [PrismTheme.Colors.cyan, PrismTheme.Colors.indigo],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: PrismTheme.Colors.cyan.opacity(0.3), radius: 8, y: 3)
                }
                .buttonStyle(.plain)

                // Running status badge (live measured RAM)
                HStack(spacing: 4) {
                    Circle()
                        .fill(runningCount > 0 ? PrismTheme.Colors.emerald : PrismTheme.Colors.textMuted)
                        .frame(width: 6, height: 6)
                    Text(runningCount > 0
                         ? "\(runningCount) Running · \(Format.bytes(Int64(store.liveMemoryTotal))) live"
                         : "Idle")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                }
                .foregroundStyle(runningCount > 0 ? PrismTheme.Colors.emerald : PrismTheme.Colors.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((runningCount > 0 ? PrismTheme.Colors.emerald : PrismTheme.Colors.textMuted).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke((runningCount > 0 ? PrismTheme.Colors.emerald : PrismTheme.Colors.textMuted).opacity(0.2), lineWidth: 0.5))
            }
            .padding(.trailing, 16)
        }
        .frame(height: PrismTheme.Layout.titleBarHeight)
        .background(PrismTheme.Colors.bgAlt.opacity(0.9))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PrismTheme.Colors.borderSubtle)
                .frame(height: 1)
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                Text("Profiles:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                    .padding(.trailing, 8)

                ForEach(ProfileFilter.allCases) { f in
                    Button {
                        filter = f
                    } label: {
                        let count = f == .all ? store.profiles.count :
                                    f == .active ? runningCount :
                                    store.profiles.filter { !$0.isSystem }.count
                        Text("\(f.rawValue) (\(count))")
                            .font(.system(size: 11, weight: filter == f ? .semibold : .regular))
                            .foregroundStyle(filter == f ? PrismTheme.Colors.textPrimary : PrismTheme.Colors.textTertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(filter == f ? PrismTheme.Colors.surfaceHigh : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            HStack(spacing: 12) {
                Text("\(store.profiles.count) profiles on disk")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)

                Button {
                    store.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Rescan profiles")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(PrismTheme.Colors.bg.opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PrismTheme.Colors.borderSubtle)
                .frame(height: 1)
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        if store.profiles.isEmpty {
            emptyState
        } else {
            ScrollView {
                if store.resolvedCursorPath == nil {
                    cursorMissingBanner
                        .padding([.horizontal, .top])
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: PrismTheme.Layout.cardMinWidth), spacing: 16)],
                    spacing: 16
                ) {
                    ForEach(filtered) { profile in
                        ProfileCard(
                            profile: profile,
                            onEdit: { editingProfile = profile },
                            onDelete: { deletingProfile = profile }
                        )
                    }
                }
                .padding(20)
            }
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 16) {
            // Real system CPU (Mach host statistics; "—" until 2nd sample)
            HStack(spacing: 4) {
                Text("CPU")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(PrismTheme.Colors.textMuted)
                Text(store.systemCPU.map { String(format: "%.0f%%", $0) } ?? "—")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(PrismTheme.Colors.textSecondary)
                ProgressView(value: (store.systemCPU ?? 0) / 100)
                    .frame(width: 48, height: 4)
                    .tint(PrismTheme.Colors.cyan)
            }

            Rectangle().fill(PrismTheme.Colors.textMuted).frame(width: 1, height: 12)

            // Real live RSS of running profiles / real physical RAM
            HStack(spacing: 4) {
                Text("RAM")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(PrismTheme.Colors.textMuted)
                Text(Format.bytes(Int64(store.liveMemoryTotal)))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(PrismTheme.Colors.cyan)
                Text("/ \(Format.bytes(Int64(store.physicalMemory)))")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(PrismTheme.Colors.textMuted)
            }
            .help("Live resident memory of running Cursor processes / total physical RAM")

            Spacer()

            Button {
                showSpotlight = true
            } label: {
                Text("⌥ Space")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(PrismTheme.Colors.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(PrismTheme.Colors.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(PrismTheme.Colors.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .frame(height: PrismTheme.Layout.statusBarHeight)
        .background(PrismTheme.Colors.bg.opacity(0.95))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PrismTheme.Colors.borderSubtle)
                .frame(height: 1)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            PrismLogoView(size: 64)
                .opacity(0.6)
            Text("No profiles yet")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(PrismTheme.Colors.textPrimary)
            Text("Each profile is a fully isolated Cursor instance —\nits own settings, extensions, login and chat history.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(PrismTheme.Colors.textTertiary)
            Button {
                showingAdd = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                    Text("Create your first profile")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(PrismTheme.Colors.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [PrismTheme.Colors.cyan, PrismTheme.Colors.indigo],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerSmall))
                .shadow(color: PrismTheme.Colors.cyan.opacity(0.4), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Cursor Missing Banner

    private var cursorMissingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(PrismTheme.Colors.amber)
            Text("Cursor was not found. Install it from cursor.sh, or set a custom path in Settings (⌘,).")
                .font(.system(size: 11))
            Spacer()
            SettingsLink { Text("Open Settings").font(.system(size: 11)) }
        }
        .padding(12)
        .background(PrismTheme.Colors.amber.opacity(0.1), in: RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerMedium))
        .overlay(RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerMedium).stroke(PrismTheme.Colors.amber.opacity(0.2), lineWidth: 1))
    }
}

// MARK: - Prism Logo (inline SVG-style triangle)

struct PrismLogoView: View {
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            // Gradient triangle
            Triangle()
                .fill(
                    LinearGradient(
                        colors: [PrismTheme.Colors.cyan.opacity(0.8), PrismTheme.Colors.purple.opacity(0.6)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: size, height: size)

            // Vertices dots
            Circle().fill(PrismTheme.Colors.cyan).frame(width: size * 0.15, height: size * 0.15)
                .offset(y: -size * 0.3)
            Circle().fill(PrismTheme.Colors.pink).frame(width: size * 0.15, height: size * 0.15)
                .offset(x: size * 0.25, y: size * 0.2)
            Circle().fill(PrismTheme.Colors.cyan).frame(width: size * 0.15, height: size * 0.15)
                .offset(x: -size * 0.25, y: size * 0.2)
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

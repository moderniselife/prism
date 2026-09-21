import SwiftUI

// MARK: - Spotlight Command Bar

@MainActor
struct SpotlightCommandBar: View {
    @EnvironmentObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = "cursor"
    @State private var selectedIndex = 0
    @FocusState private var isSearchFocused: Bool

    private var filteredProfiles: [CursorProfile] {
        let profiles = store.profiles
        guard !searchText.isEmpty else { return profiles }
        return profiles.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.folderName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var runningProfiles: [CursorProfile] {
        filteredProfiles.filter { store.isRunning($0) }
    }

    private var idleProfiles: [CursorProfile] {
        filteredProfiles.filter { !store.isRunning($0) }
    }

    @State private var escMonitor: Any?

    var body: some View {
        ZStack {
            // Dimmed backdrop
            PrismTheme.Colors.bg.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            // Ambient glow
            PrismTheme.Colors.purple.opacity(0.1)
                .ignoresSafeArea()

            // Modal
            VStack(spacing: 0) {
                searchHeader
                resultsList
                footerBar
            }
            .frame(width: 720, height: 520)
            .glassCard()
            .clipShape(RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerXLarge))
            .glowShadow(color: PrismTheme.Colors.purple, radius: 40)
        }
        .onAppear {
            isSearchFocused = true
            selectedIndex = 0
            // Self-removing: without this the monitor outlives the palette
            // and swallows Esc app-wide (which is what broke Cancel).
            if escMonitor == nil {
                escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if event.keyCode == 53 { // Escape
                        dismiss()
                        return nil
                    }
                    handleKeyDown(event)
                    return event
                }
            }
        }
        .onDisappear {
            if let monitor = escMonitor {
                NSEvent.removeMonitor(monitor)
                escMonitor = nil
            }
        }
    }

    // MARK: - Search Header

    private var searchHeader: some View {
        HStack(spacing: 12) {
            // Logo
            PrismLogoView(size: 28)

            // Search input
            HStack(spacing: 4) {
                TextField("", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PrismTheme.Colors.textPrimary)
                    .focused($isSearchFocused)
                    .onSubmit { executeSelected() }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        isSearchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(PrismTheme.Colors.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Scope filter
            HStack(spacing: 4) {
                Circle()
                    .fill(PrismTheme.Colors.cyan)
                    .frame(width: 6, height: 6)
                Text("All Profiles")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(PrismTheme.Colors.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(PrismTheme.Colors.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(PrismTheme.Colors.border, lineWidth: 0.5))

            Text("⌘P")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(PrismTheme.Colors.textMuted)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(PrismTheme.Colors.bg)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(PrismTheme.Colors.border, lineWidth: 0.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PrismTheme.Colors.border)
                .frame(height: 1)
        }
    }

    // MARK: - Results List

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Running instances section
                    if !runningProfiles.isEmpty {
                        sectionHeader(
                            title: "Running Instances",
                            count: runningProfiles.count,
                            subtitle: "live: \(Format.bytes(Int64(store.liveMemoryTotal)))"
                        )
                        VStack(spacing: 4) {
                            ForEach(Array(runningProfiles.enumerated()), id: \.element.id) { index, profile in
                                SpotlightItem(
                                    profile: profile,
                                    isRunning: true,
                                    isSelected: selectedIndex == index,
                                    store: store
                                )
                                .onTapGesture {
                                    selectedIndex = index
                                    store.launch(profile)
                                    dismiss()
                                }
                                .id(profile.id)
                            }
                        }
                    }

                    // Idle profiles section
                    if !idleProfiles.isEmpty {
                        sectionHeader(title: "Workspaces & Standalone CLI", count: nil, subtitle: nil)
                        VStack(spacing: 4) {
                            ForEach(Array(idleProfiles.enumerated()), id: \.element.id) { index, profile in
                                let globalIndex = runningProfiles.count + index
                                SpotlightItem(
                                    profile: profile,
                                    isRunning: false,
                                    isSelected: selectedIndex == globalIndex,
                                    store: store
                                )
                                .onTapGesture {
                                    selectedIndex = globalIndex
                                    store.launch(profile)
                                    dismiss()
                                }
                                .id(profile.id)
                            }
                        }
                    }

                    // Quick actions section
                    sectionHeader(title: "Quick Actions", count: nil, subtitle: nil)
                    quickActions
                }
                .padding(12)
            }
        }
    }

    // MARK: - Section Header

    private func sectionHeader(title: String, count: Int?, subtitle: String?) -> some View {
        HStack {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                if let count {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(PrismTheme.Colors.cyan)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(PrismTheme.Colors.cyan.opacity(0.15))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(PrismTheme.Colors.cyan.opacity(0.3), lineWidth: 0.5))
                }
            }

            Spacer()

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(PrismTheme.Colors.textMuted)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Quick Actions

    private var quickActions: some View {
        VStack(spacing: 6) {
            quickActionRow(
                icon: "plus",
                iconColor: PrismTheme.Colors.cyan,
                title: "New Profile...",
                shortcut: "⌘N"
            ) {
                dismiss()
                PrismUI.newProfile()
            }

            quickActionRow(
                icon: "arrow.triangle.2.circlepath",
                iconColor: PrismTheme.Colors.emerald,
                title: "Rescan Profiles",
                shortcut: "⌘R"
            ) {
                store.reload()
            }

            quickActionRow(
                icon: "folder",
                iconColor: PrismTheme.Colors.amber,
                title: "Reveal Profiles Folder",
                shortcut: ""
            ) {
                NSWorkspace.shared.activateFileViewerSelecting([store.profilesDir])
            }

            quickActionRow(
                icon: "rectangle.expand.vertical",
                iconColor: PrismTheme.Colors.indigo,
                title: "Open Full Profile Hub",
                shortcut: ""
            ) {
                dismiss()
                PrismUI.openHub()
            }
        }
    }

    private func quickActionRow(
        icon: String,
        iconColor: Color,
        title: String,
        shortcut: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(iconColor)
                    .frame(width: 24, height: 24)
                    .background(iconColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PrismTheme.Colors.textSecondary)

                Spacer()

                if !shortcut.isEmpty {
                    Text(shortcut)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(PrismTheme.Colors.textMuted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(PrismTheme.Colors.control)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(PrismTheme.Colors.border, lineWidth: 0.5))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PrismTheme.Colors.borderSubtle, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { _ in }
    }

    // MARK: - Footer Bar

    private var footerBar: some View {
        HStack(spacing: 12) {
            // Current target
            HStack(spacing: 6) {
                Circle()
                    .fill(PrismTheme.Colors.cyan)
                    .frame(width: 6, height: 6)
                if let firstRunning = runningProfiles.first {
                    Text(firstRunning.displayName)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(PrismTheme.Colors.textSecondary)
                    if let pids = store.runningPIDs[firstRunning.folderName], let pid = pids.first {
                        Text("PID \(pid)")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(PrismTheme.Colors.textMuted)
                    }
                    Text(Format.bytes(Int64(store.liveMemory[firstRunning.folderName] ?? 0)))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(PrismTheme.Colors.emerald)
                } else {
                    Text("No active instance")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(PrismTheme.Colors.textMuted)
                }
            }

            Spacer()

            // Key hints
            HStack(spacing: 12) {
                keyHint(key: "⏎", label: "Focus")
                keyHint(key: "⌘K", label: "Actions")
                keyHint(key: "⌘N", label: "New Window")
                keyHint(key: "⎋", label: "Close")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(PrismTheme.Colors.bg.opacity(0.9))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PrismTheme.Colors.border)
                .frame(height: 1)
        }
    }

    private func keyHint(key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(PrismTheme.Colors.textSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(PrismTheme.Colors.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(PrismTheme.Colors.border, lineWidth: 0.5))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(PrismTheme.Colors.textSecondary)
        }
    }

    // MARK: - Keyboard handling

    private func handleKeyDown(_ event: NSEvent) {
        let totalItems = runningProfiles.count + idleProfiles.count
        switch event.keyCode {
        case 125: // Down arrow
            selectedIndex = min(selectedIndex + 1, totalItems - 1)
        case 126: // Up arrow
            selectedIndex = max(selectedIndex - 1, 0)
        case 36: // Enter
            executeSelected()
        case 53: // Escape
            dismiss()
        default:
            break
        }
    }

    private func executeSelected() {
        let all = runningProfiles + idleProfiles
        guard selectedIndex < all.count else { return }
        let profile = all[selectedIndex]
        store.launch(profile)
        dismiss()
    }
}

// MARK: - Spotlight Item

@MainActor
struct SpotlightItem: View {
    let profile: CursorProfile
    let isRunning: Bool
    let isSelected: Bool
    let store: ProfileStore

    var body: some View {
        HStack(spacing: 10) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerSmall)
                    .fill(
                        LinearGradient(
                            colors: [profile.accentColor.opacity(0.3), profile.accentColor.opacity(0.1)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                Text(profile.initial)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(profile.accentColor)

                if isRunning {
                    Circle()
                        .fill(PrismTheme.Colors.emerald)
                        .frame(width: 7, height: 7)
                        .offset(x: 13, y: 13)
                        .shadow(color: PrismTheme.Colors.emerald.opacity(0.6), radius: 3)
                }
            }
            .frame(width: 36, height: 36)

            // Details
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? PrismTheme.Colors.textPrimary : PrismTheme.Colors.textSecondary)

                    if profile.isSystem {
                        Text("BUILT-IN")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(PrismTheme.Colors.cyan)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(PrismTheme.Colors.cyan.opacity(0.15))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(PrismTheme.Colors.cyan.opacity(0.3), lineWidth: 0.5))
                    }

                    if isRunning, let pids = store.runningPIDs[profile.folderName], let pid = pids.first {
                        Text("PID \(pid)")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(PrismTheme.Colors.textTertiary)
                    }
                }

                HStack(spacing: 4) {
                    if let project = profile.defaultProjectPath {
                        Text((project as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(PrismTheme.Colors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Text("·")
                        .foregroundStyle(PrismTheme.Colors.textMuted)

                    if isRunning {
                        let live = store.liveMemory[profile.folderName] ?? 0
                        Text("\(Format.bytes(Int64(live))) live")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(profile.accentColor)
                    } else {
                        Text("\(formatMB(profile.defaultMemoryMB)) limit")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(PrismTheme.Colors.textTertiary)
                    }
                }
            }

            Spacer()

            // Action button
            if isRunning {
                HStack(spacing: 4) {
                    Text("⏎")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                    Text("Focus")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(PrismTheme.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    LinearGradient(
                        colors: [PrismTheme.Colors.cyan, PrismTheme.Colors.cyan.opacity(0.8)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                HStack(spacing: 4) {
                    Text("⏎")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                    Text("Open")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(PrismTheme.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(PrismTheme.Colors.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(PrismTheme.Colors.border, lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isSelected
                ? LinearGradient(
                    colors: [profile.accentColor.opacity(0.12), PrismTheme.Colors.surfaceAlt],
                    startPoint: .leading, endPoint: .trailing
                  )
                : LinearGradient(
                    colors: [Color.clear, Color.clear],
                    startPoint: .leading, endPoint: .trailing
                  )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isSelected ? profile.accentColor.opacity(0.35) : Color.clear,
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        )
    }

    private func formatMB(_ mb: Int) -> String {
        if mb >= 1024 {
            return String(format: "%.1f GB", Double(mb) / 1024.0)
        }
        return "\(mb) MB"
    }
}

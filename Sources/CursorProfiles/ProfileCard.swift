import SwiftUI
import UniformTypeIdentifiers

struct ProfileCard: View {
    @EnvironmentObject var store: ProfileStore
    let profile: CursorProfile
    var onEdit: () -> Void
    var onDelete: () -> Void

    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var showingLaunchOptions = false

    private var isRunning: Bool { store.isRunning(profile) }
    private var limitBytes: UInt64 { UInt64(profile.defaultMemoryMB) * 1024 * 1024 }
    private var liveBytes: UInt64 { store.liveMemory[profile.folderName] ?? 0 }
    private var windowCount: Int { store.windows(for: profile) }
    /// Honest fill: live RSS against the configured --max-memory limit.
    private var usedMemoryFraction: CGFloat {
        guard limitBytes > 0, isRunning else { return 0 }
        return min(1.0, CGFloat(liveBytes) / CGFloat(limitBytes))
    }

    private var windowLabel: String {
        switch windowCount {
        case 0: return isRunning ? "starting…" : ""
        case 1: return "1 window"
        default: return "\(windowCount) windows"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topAccent
            header
            metadata
            actions
        }
        .glassCard(accent: profile.accentColor, active: isRunning)
        .clipShape(RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerLarge))
        .overlay(
            RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerLarge)
                .strokeBorder(
                    dropTargeted ? profile.accentColor : Color.clear,
                    lineWidth: 2
                )
                .allowsHitTesting(false)
        )
        .glowShadow(color: profile.accentColor, radius: hovering ? 24 : 14)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { store.launch(profile) }
        .contextMenu { contextMenuItems }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Top accent strip

    private var topAccent: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        profile.accentColor,
                        profile.accentColor.opacity(0.5),
                        profile.accentColor.opacity(0.2)
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .frame(height: 3)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: PrismTheme.Layout.cornerLarge,
                    topTrailingRadius: PrismTheme.Layout.cornerLarge
                )
            )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            // Icon box
            ZStack {
                RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerMedium)
                    .fill(
                        LinearGradient(
                            colors: [profile.accentColor.opacity(0.3), profile.accentColor.opacity(0.15)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                Text(profile.emoji)
                    .font(.system(size: 22))

                // Running indicator dot
                if isRunning {
                    Circle()
                        .fill(PrismTheme.Colors.emerald)
                        .frame(width: 8, height: 8)
                        .offset(x: 16, y: 16)
                        .shadow(color: PrismTheme.Colors.emerald.opacity(0.6), radius: 4)
                }
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.displayName)
                        .font(.system(size: PrismTheme.FontSize.regular, weight: .semibold))
                        .foregroundStyle(PrismTheme.Colors.textPrimary)
                        .lineLimit(1)

                    if profile.isSystem {
                        Text("BUILT-IN")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(PrismTheme.Colors.cyan)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(PrismTheme.Colors.cyan.opacity(0.15))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(PrismTheme.Colors.cyan.opacity(0.3), lineWidth: 0.5))
                    }
                }

                HStack(spacing: 4) {
                    Circle()
                        .fill(isRunning ? PrismTheme.Colors.emerald : PrismTheme.Colors.textMuted)
                        .frame(width: 6, height: 6)
                    if isRunning {
                        Text("Running")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(PrismTheme.Colors.emerald)
                        if let pids = store.runningPIDs[profile.folderName], !pids.isEmpty {
                            Text("PID \(pids[0])")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(PrismTheme.Colors.textTertiary)
                        }
                    } else {
                        Text("Idle")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(PrismTheme.Colors.textTertiary)
                    }
                }
            }

            Spacer()

            // More options
            Button {
                onEdit()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Metadata section

    private var metadata: some View {
        VStack(spacing: 8) {
            // Path + PID
            HStack(spacing: 8) {
                if let project = profile.defaultProjectPath, !project.isEmpty {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                        .foregroundStyle(PrismTheme.Colors.textMuted)
                    Text((project as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                        .foregroundStyle(PrismTheme.Colors.textMuted)
                    Text("No project set")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(PrismTheme.Colors.textMuted)
                }
            }

            // Live memory (measured RSS) vs configured limit
            HStack(spacing: 6) {
                Text("Memory")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(PrismTheme.Colors.textMuted)
                if isRunning {
                    Text(Format.bytes(Int64(liveBytes)))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(profile.accentColor)
                    Text("/ \(formatMB(profile.defaultMemoryMB)) limit")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(PrismTheme.Colors.textMuted)
                } else {
                    Text("\(formatMB(profile.defaultMemoryMB)) limit")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                }
                Spacer()
                Text(windowLabel)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
            }
            .help(isRunning ? "Live resident memory of this profile's Cursor processes" : "Configured --max-memory limit applied at launch")

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(PrismTheme.Colors.surfaceHigh)
                        .frame(height: 4)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [profile.accentColor, profile.accentColor.opacity(0.5)],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * usedMemoryFraction, height: 4)
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Action buttons

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                // A running instance needs --new-window, otherwise this
                // just refocuses and looks dead.
                store.launch(profile, newWindow: isRunning)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isRunning ? "plus" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(isRunning ? "New Window" : "Launch")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(PrismTheme.Colors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    isRunning
                        ? AnyShapeStyle(PrismTheme.Colors.surfaceHigh)
                        : AnyShapeStyle(
                            LinearGradient(
                                colors: [profile.accentColor, profile.accentColor.opacity(0.8)],
                                startPoint: .top, endPoint: .bottom
                            )
                          )
                )
                .clipShape(RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerSmall)
                        .strokeBorder(
                            isRunning ? PrismTheme.Colors.border : profile.accentColor.opacity(0.4),
                            lineWidth: 0.5
                        )
                )
            }
            .buttonStyle(.plain)

            Button {
                showingLaunchOptions = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                    .frame(width: 30, height: 30)
                    .background(PrismTheme.Colors.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerSmall))
                    .overlay(RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerSmall).stroke(PrismTheme.Colors.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingLaunchOptions, arrowEdge: .bottom) {
                LaunchOptionsView(profile: profile)
            }

            if isRunning {
                Button {
                    store.quit(profile)
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.Colors.red)
                        .frame(width: 30, height: 30)
                        .background(PrismTheme.Colors.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerSmall))
                        .overlay(RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerSmall).stroke(PrismTheme.Colors.red.opacity(0.2), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }

            if store.duplicating.contains(profile.folderName) {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Helpers

    private func formatMB(_ mb: Int) -> String {
        if mb >= 1024 {
            return String(format: "%.0f GB", Double(mb) / 1024.0)
        }
        return "\(mb) MB"
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Launch") { store.launch(profile) }
        Button("Launch with Options…") { showingLaunchOptions = true }
        if isRunning {
            Button("Quit Profile") { store.quit(profile) }
        }
        Divider()
        Button(profile.isPinned ? "Unpin" : "Pin to Top") { store.togglePin(profile) }
        Button("Edit…") { onEdit() }
        Button(profile.isSystem ? "Clone into New Profile" : "Duplicate") {
            store.duplicate(profile)
        }
        .disabled(store.duplicating.contains(profile.folderName))
        Button("Reveal in Finder") { store.revealInFinder(profile) }
        if !profile.isSystem {
            Divider()
            Button("Move to Trash", role: .destructive) { onDelete() }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.hasDirectoryPath || FileManager.default.isDirectory(url) else { return }
            DispatchQueue.main.async {
                store.launch(profile, projectPath: url.path)
            }
        }
        return true
    }
}

extension FileManager {
    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

// MARK: - Launch options popover (redesigned)

struct LaunchOptionsView: View {
    @EnvironmentObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    let profile: CursorProfile

    @State private var memoryMB: Int = 16384
    @State private var projectPath: String = ""
    @State private var newWindow = false

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

            // Memory
            VStack(alignment: .leading, spacing: 4) {
                Text("Memory limit")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PrismTheme.Colors.textSecondary)
                HStack(spacing: 6) {
                    TextField("MB", value: $memoryMB, format: .number.grouping(.never))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(PrismTheme.Colors.cyan)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(PrismTheme.Colors.bg)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(PrismTheme.Colors.border, lineWidth: 0.5))
                        .frame(width: 80)
                    Text("MB")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                }
            }

            // Project
            VStack(alignment: .leading, spacing: 4) {
                Text("Project folder")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PrismTheme.Colors.textSecondary)
                HStack(spacing: 6) {
                    TextField("Optional", text: $projectPath)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(PrismTheme.Colors.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(PrismTheme.Colors.bg)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(PrismTheme.Colors.border, lineWidth: 0.5))
                    Button("…") { pickFolder() }
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(PrismTheme.Colors.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(PrismTheme.Colors.border, lineWidth: 0.5))
                        .buttonStyle(.plain)
                }
            }

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
                .buttonStyle(PrismGlowButtonStyle(color: profile.accentColor))
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

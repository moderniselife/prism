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
    @State private var pulse = false

    private static let cardRadius: CGFloat = 20

    private var isRunning: Bool { store.isRunning(profile) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            details
        }
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: Self.cardRadius)
                .strokeBorder(
                    dropTargeted ? profile.accentColor : Color.primary.opacity(hovering ? 0.16 : 0.07),
                    lineWidth: dropTargeted ? 2.5 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: Self.cardRadius))
        .shadow(color: profile.accentColor.opacity(hovering ? 0.38 : 0.16),
                radius: hovering ? 26 : 12, y: hovering ? 12 : 6)
        .shadow(color: .black.opacity(hovering ? 0.16 : 0.06),
                radius: hovering ? 10 : 4, y: hovering ? 5 : 2)
        .scaleEffect(hovering ? 1.03 : 1)
        .offset(y: hovering ? -3 : 0)
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { store.launch(profile) }
        .contextMenu { contextMenuItems }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .help("Double-click to launch. Drop a folder here to open it with this profile.")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text(profile.emoji)
                .font(.system(size: 30))
                .frame(width: 52, height: 52)
                .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 15))
                .scaleEffect(isRunning && pulse ? 1.06 : 1)
                .animation(isRunning ? .easeInOut(duration: 1.6).repeatForever(autoreverses: true) : .default, value: pulse)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    if profile.isSystem {
                        Text("BUILT-IN")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.25), in: Capsule())
                            .help("Your original Cursor profile (~/Library/Application Support/Cursor). It can be launched and cloned, but never deleted from this app.")
                    }
                    if profile.isPinned && !profile.isSystem {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .opacity(0.85)
                    }
                }
                HStack(spacing: 5) {
                    ZStack {
                        if isRunning {
                            Circle()
                                .stroke(Color.green.opacity(0.55), lineWidth: 2)
                                .frame(width: 7, height: 7)
                                .scaleEffect(pulse ? 2.4 : 1)
                                .opacity(pulse ? 0 : 0.7)
                                .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: pulse)
                        }
                        Circle()
                            .fill(isRunning ? .green : .white.opacity(0.5))
                            .frame(width: 7, height: 7)
                    }
                    Text(isRunning ? "Running" : "Idle")
                        .font(.caption)
                        .opacity(0.9)
                }
            }
            .foregroundStyle(.white)

            Spacer()
        }
        .padding(14)
        .background(
            ZStack {
                LinearGradient(
                    colors: [profile.accentColor, profile.accentColor.opacity(0.65)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                shimmer
            }
        )
        .onAppear { pulse = true }
    }

    /// A slow diagonal highlight sweeping across the header, purely
    /// decorative — gives the gradient a bit of life without being distracting.
    private var shimmer: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { timeline in
            let cycle = 3.6
            let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0), location: 0),
                    .init(color: .white.opacity(0.22), location: 0.5),
                    .init(color: .white.opacity(0), location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: 140)
            .rotationEffect(.degrees(18))
            .offset(x: -160 + CGFloat(t) * 420)
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Label(Format.bytes(store.sizes[profile.folderName]), systemImage: "internaldrive")
                Label(Format.relative(profile.lastLaunchedAt), systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let project = profile.defaultProjectPath, !project.isEmpty {
                Label {
                    Text((project as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "folder")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    store.launch(profile)
                } label: {
                    Label(isRunning ? "New Window" : "Launch", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 10))
                .tint(profile.accentColor)
                .shadow(color: profile.accentColor.opacity(0.45), radius: 8, y: 3)

                Button {
                    showingLaunchOptions = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 10))
                .help("Launch with options…")
                .popover(isPresented: $showingLaunchOptions, arrowEdge: .bottom) {
                    LaunchOptionsView(profile: profile)
                }

                if isRunning {
                    Button {
                        store.quit(profile)
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .help("Quit this profile")
                }

                if store.duplicating.contains(profile.folderName) {
                    ProgressView()
                        .controlSize(.small)
                        .help("Cloning profile data…")
                }
            }
        }
        .padding(14)
    }

    // MARK: Context menu

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

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.cardRadius)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: Self.cardRadius)
                .fill(profile.accentColor.opacity(0.05))
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

// MARK: - Launch options popover

struct LaunchOptionsView: View {
    @EnvironmentObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    let profile: CursorProfile

    @State private var memoryMB: Int = 16384
    @State private var projectPath: String = ""
    @State private var newWindow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Launch “\(profile.displayName)”")
                .font(.headline)

            LabeledContent("Memory limit") {
                HStack(spacing: 6) {
                    TextField("MB", value: $memoryMB, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Text("MB").foregroundStyle(.secondary)
                }
            }

            LabeledContent("Project folder") {
                HStack(spacing: 6) {
                    TextField("Optional", text: $projectPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Button("Choose…") { pickFolder() }
                }
            }

            Toggle("Force a new window", isOn: $newWindow)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Launch") {
                    store.launch(
                        profile,
                        projectPath: projectPath.isEmpty ? nil : projectPath,
                        memoryMB: max(512, memoryMB),
                        newWindow: newWindow
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 360)
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

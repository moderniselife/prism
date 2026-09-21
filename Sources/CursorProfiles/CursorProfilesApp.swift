import Carbon
import SwiftUI

@main
struct CursorProfilesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ProfileStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Rescan Profiles") { store.reload() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandMenu("Prism") {
                Button("Quick Switch") {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .prismQuickSwitch, object: nil)
                }
                .keyboardShortcut(" ", modifiers: .option)
                Button("Search Profiles") {
                    NotificationCenter.default.post(name: .prismFocusSearch, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                Button("New Profile") { PrismUI.newProfile() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }

        MenuBarExtra("Prism", systemImage: "cursorarrow.square") {
            MenuBarDropdown()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu Bar Dropdown
//
// Popover-safe layout: every row carries an explicit fixed width.
// (Bare Spacers + ScrollView + GeometryReader collapse inside
// MenuBarExtra popovers — that was the "stacked spaghetti" bug.)

private enum MenuMetrics {
    static let width: CGFloat = 340
    static let contentWidth: CGFloat = 316 // width minus 12pt side padding
    static let itemInnerWidth: CGFloat = 284 // content minus item padding
    static let textColumnWidth: CGFloat = 176
    static let maxItems = 6
}

@MainActor
struct MenuBarDropdown: View {
    @EnvironmentObject var store: ProfileStore
    @State private var searchText = ""

    private var sortedProfiles: [CursorProfile] {
        store.profiles.sorted { a, b in
            if a.isSystem != b.isSystem { return a.isSystem }
            if a.isPinned != b.isPinned { return a.isPinned }
            return (a.lastLaunchedAt ?? .distantPast) > (b.lastLaunchedAt ?? .distantPast)
        }
    }

    private var filteredProfiles: [CursorProfile] {
        guard !searchText.isEmpty else { return sortedProfiles }
        return sortedProfiles.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.defaultProjectPath?.localizedCaseInsensitiveContains(searchText) == true
        }
    }

    private var runningCount: Int {
        store.profiles.filter { store.isRunning($0) }.count
    }

    private var visibleProfiles: [CursorProfile] {
        Array(filteredProfiles.prefix(MenuMetrics.maxItems))
    }

    private var hiddenCount: Int {
        max(0, filteredProfiles.count - visibleProfiles.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(PrismTheme.Colors.border)
            searchBar
            Divider().overlay(PrismTheme.Colors.borderSubtle)
            profileList
            Divider().overlay(PrismTheme.Colors.border)
            statusFooter
            Divider().overlay(PrismTheme.Colors.border)
            bottomActions
        }
        .frame(width: MenuMetrics.width)
        .background(PrismTheme.Colors.surface)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(PrismTheme.Colors.surfaceAlt)
                PrismLogoView(size: 20)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Prism")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(PrismTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Text("v\(PrismVersion.string)")
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(PrismTheme.Colors.cyan)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(PrismTheme.Colors.cyan.opacity(0.15))
                        .clipShape(Capsule())
                }
                .frame(width: 170, alignment: .leading)
                Text(runningCount > 0
                     ? "\(runningCount) running · \(Format.bytes(Int64(store.liveMemoryTotal))) live"
                     : "All profiles idle")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                    .lineLimit(1)
                    .frame(width: 170, alignment: .leading)
            }
            .frame(width: 178, alignment: .leading)

            Spacer(minLength: 4)

            Button { PrismUI.openHub() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Open full hub")

            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .frame(width: MenuMetrics.contentWidth, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(PrismTheme.Colors.textMuted)
            TextField("Filter profiles...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(PrismTheme.Colors.textPrimary)
                .frame(width: 270, alignment: .leading)
        }
        .frame(width: MenuMetrics.contentWidth, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - Profile List (no ScrollView — popovers mis-size it)

    private var profileList: some View {
        VStack(spacing: 4) {
            ForEach(visibleProfiles) { profile in
                MenuBarProfileItem(profile: profile, store: store)
            }
            if hiddenCount > 0 {
                Button { PrismUI.openHub() } label: {
                    Text("+\(hiddenCount) more — open hub")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(PrismTheme.Colors.cyan)
                        .frame(width: MenuMetrics.contentWidth, alignment: .center)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            if visibleProfiles.isEmpty {
                Text(searchText.isEmpty ? "No profiles yet" : "No matches")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                    .frame(width: MenuMetrics.contentWidth, alignment: .center)
                    .padding(.vertical, 12)
            }
        }
        .frame(width: MenuMetrics.contentWidth, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Status Footer

    private var statusFooter: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(runningCount > 0 ? PrismTheme.Colors.emerald : PrismTheme.Colors.textMuted)
                .frame(width: 6, height: 6)
            Text(runningCount > 0 ? "\(runningCount) running" : "Idle")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(PrismTheme.Colors.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("Live \(Format.bytes(Int64(store.liveMemoryTotal))) / \(Format.bytes(Int64(store.physicalMemory)))")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(PrismTheme.Colors.textMuted)
                .lineLimit(1)
        }
        .frame(width: MenuMetrics.contentWidth, alignment: .leading)
        .help("Live resident memory of running Cursor processes / total physical RAM")
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Bottom Actions

    private var bottomActions: some View {
        HStack(spacing: 8) {
            Button { PrismUI.newProfile() } label: {
                Label("New Profile", systemImage: "plus")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Spacer(minLength: 8)

            Button { store.quitAll() } label: {
                Text("Stop All")
                    .font(.system(size: 11, design: .rounded))
            }
            .buttonStyle(.borderless)

            Button { PrismUI.openHub() } label: {
                Text("Open Hub")
                    .font(.system(size: 11, design: .rounded))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(width: MenuMetrics.contentWidth, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Menu Bar Profile Item (fixed widths throughout)

@MainActor
struct MenuBarProfileItem: View {
    let profile: CursorProfile
    let store: ProfileStore

    private var isRunning: Bool { store.isRunning(profile) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(profile.accentColor.opacity(0.18))
                    Text(profile.initial)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(profile.accentColor)
                    if isRunning {
                        Circle()
                            .fill(PrismTheme.Colors.emerald)
                            .frame(width: 6, height: 6)
                            .offset(x: 12, y: 12)
                    }
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(profile.displayName)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(PrismTheme.Colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if isRunning {
                            Circle()
                                .fill(PrismTheme.Colors.emerald)
                                .frame(width: 5, height: 5)
                        }
                    }
                    .frame(width: MenuMetrics.textColumnWidth, alignment: .leading)

                    if let pids = store.runningPIDs[profile.folderName], let pid = pids.first {
                        Text("PID \(pid)")
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(PrismTheme.Colors.textMuted)
                            .lineLimit(1)
                            .frame(width: MenuMetrics.textColumnWidth, alignment: .leading)
                    } else if let project = profile.defaultProjectPath {
                        Text((project as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(PrismTheme.Colors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: MenuMetrics.textColumnWidth, alignment: .leading)
                    }

                    if isRunning {
                        let live = store.liveMemory[profile.folderName] ?? 0
                        let wins = store.windows(for: profile)
                        Text("\(Format.bytes(Int64(live))) · \(wins == 1 ? "1 window" : "\(wins) windows")")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(profile.accentColor)
                            .lineLimit(1)
                            .frame(width: MenuMetrics.textColumnWidth, alignment: .leading)
                    } else {
                        Text("\(formatMB(profile.defaultMemoryMB)) limit")
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(PrismTheme.Colors.textTertiary)
                            .lineLimit(1)
                            .frame(width: MenuMetrics.textColumnWidth, alignment: .leading)
                    }
                }
                .frame(width: MenuMetrics.textColumnWidth, alignment: .leading)

                Spacer(minLength: 4)

                if isRunning {
                    Button { store.launch(profile) } label: {
                        Text("Focus")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .frame(width: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button { store.launch(profile) } label: {
                        Text("Start")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .frame(width: 52)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .frame(width: MenuMetrics.itemInnerWidth, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)

            // Fixed-width live memory bar — plain arithmetic, no GeometryReader.
            if isRunning {
                let limit = UInt64(profile.defaultMemoryMB) * 1024 * 1024
                let live = store.liveMemory[profile.folderName] ?? 0
                let fraction = limit > 0 ? min(1.0, Double(live) / Double(limit)) : 0
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(profile.accentColor)
                        .frame(width: MenuMetrics.itemInnerWidth * CGFloat(fraction), height: 2)
                    Spacer(minLength: 0)
                }
                .frame(width: MenuMetrics.itemInnerWidth, height: 2, alignment: .leading)
                .background(PrismTheme.Colors.surfaceHigh.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 1))
            }
        }
        .frame(width: MenuMetrics.itemInnerWidth + 16, alignment: .leading)
        .background(isRunning ? profile.accentColor.opacity(0.07) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isRunning ? profile.accentColor.opacity(0.25) : PrismTheme.Colors.borderSubtle,
                    lineWidth: 1)
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

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        QuickSwitchHotkey.register()
        // Configure the main window for custom title bar
        DispatchQueue.main.async {
            for window in NSApp.windows where window.canBecomeMain {
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.isMovableByWindowBackground = false
            }
        }

        // Window dragging: intercept clicks in the top 48px of the MAIN
        // window only — never sheets, popovers or panels, so their
        // buttons (Cancel, X, …) always receive clicks.
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let win = event.window,
                  win.sheetParent == nil,
                  !(win is NSPanel),
                  win.styleMask.contains(.titled),
                  !win.styleMask.contains(.fullScreen),
                  let contentView = win.contentView else { return event }

            let locInView = contentView.convert(event.locationInWindow, from: nil)
            guard locInView.y > contentView.bounds.height - 48 else { return event }

            // Don't hijack clicks on actual controls. Walk up the view
            // chain: every AppKit control is an NSControl, and SwiftUI
            // control hosts carry Button/Field/Menu/etc in their names.
            if let hitView = contentView.hitTest(event.locationInWindow) {
                var view: NSView? = hitView
                while let current = view, current !== contentView {
                    if current is NSControl { return event }
                    let typeName = String(describing: type(of: current))
                    if typeName.contains("Button") || typeName.contains("Field")
                        || typeName.contains("Menu") || typeName.contains("PopUp")
                        || typeName.contains("Slider") || typeName.contains("Switch")
                        || typeName.contains("Toggle") || typeName.contains("Picker")
                        || typeName.contains("Stepper") || typeName.contains("Search") {
                        return event
                    }
                    view = current.superview
                }
            }

            // Check we're not over a traffic light button (~20px from left, ~14px from top)
            let locInWindow = event.locationInWindow
            let trafficLightZone = NSRect(x: 0, y: win.frame.height - 36, width: 80, height: 36)
            if NSPointInRect(NSPoint(x: locInWindow.x, y: locInWindow.y), trafficLightZone) {
                return event
            }

            // Begin window drag
            win.performDrag(with: event)
            return nil
        }
    }
}

// MARK: - Global Quick Switch hotkey (⌥Space, works from any app)
//
// Cmd+Space belongs to the OS and can never be ours. Option+Space is the
// standard Raycast/Alfred-style alternative. Carbon hotkeys are old but
// still functional — unlike a CGEvent tap they need no accessibility
// permission. When Prism is already frontmost the in-app local monitor
// handles the toggle, so this handler stays out of the way.

enum QuickSwitchHotkey {
    /// Written once during launch on the main thread, never mutated after.
    private final class HotKeyStorage: @unchecked Sendable {
        var ref: EventHotKeyRef?
    }
    private static let storage = HotKeyStorage()

    static func register() {
        var type = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = {
            (_: EventHandlerCallRef?, _: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus in
            QuickSwitchHotkey.pressed()
            return noErr
        }
        var installed: EventHandlerRef?
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &type, nil as UnsafeMutableRawPointer?, &installed)

        var ref: EventHotKeyRef?
        // 'PRSM' signature, Option+Space.
        let hotID = EventHotKeyID(signature: OSType(0x5052534D), id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey),
                            hotID, GetApplicationEventTarget(), 0, &ref)
        storage.ref = ref
    }

    private static func pressed() {
        DispatchQueue.main.async {
            guard !NSApp.isActive else { return } // in-app monitor toggles
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .prismQuickSwitch, object: nil)
        }
    }
}

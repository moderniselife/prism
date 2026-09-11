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
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Rescan Profiles") { store.reload() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }

        MenuBarExtra("Prism", systemImage: "cursorarrow.square") {
            MenuBarQuickLaunch()
                .environmentObject(store)
        }
    }
}

/// Quick-launch menu that lives in the menu bar — swap profiles from anywhere.
struct MenuBarQuickLaunch: View {
    @EnvironmentObject var store: ProfileStore

    var body: some View {
        ForEach(store.profiles.sorted(by: { a, b in
            if a.isSystem != b.isSystem { return a.isSystem }
            if a.isPinned != b.isPinned { return a.isPinned }
            return (a.lastLaunchedAt ?? .distantPast) > (b.lastLaunchedAt ?? .distantPast)
        })) { profile in
            Button {
                store.launch(profile)
            } label: {
                Text("\(profile.emoji)  \(profile.displayName)\(store.isRunning(profile) ? "  ●" : "")")
            }
        }
        if store.profiles.isEmpty {
            Text("No profiles yet")
        }
        Divider()
        Button("Open Prism") {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
        Button("Quit") { NSApp.terminate(nil) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keep the menu-bar quick launcher alive
    }
}

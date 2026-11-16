import SwiftUI

// MARK: - App glyphs
//
// Small line icons in place of text badges. Generic shapes, not app logos:
// a pointer for Cursor, a terminal for Claude Code, a window for Claude
// Desktop and a little bot for Grok Bot.

struct AppGlyph: View {
    let app: String
    var size: CGFloat = 14

    var body: some View {
        switch CursorProfile.normalizeApp(app) {
        case CursorProfile.appGrokBot:
            BotGlyph(size: size)
        case CursorProfile.appClaudeCode:
            symbol("terminal")
        case CursorProfile.appClaudeDesktop:
            symbol("macwindow")
        default:
            symbol("cursorarrow")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.86, weight: .regular))
            .frame(width: size, height: size)
    }
}

/// A rounded head with an antenna and two eyes, drawn on a 20-pt grid.
struct BotGlyph: View {
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            BotOutline()
                .stroke(style: StrokeStyle(lineWidth: max(1.1, size / 11), lineCap: .round, lineJoin: .round))
            BotEyes()
        }
        .frame(width: size, height: size)
    }
}

private struct BotOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 20
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 3.5 * s, y: 6.5 * s, width: 13 * s, height: 9.5 * s),
                         cornerSize: CGSize(width: 3 * s, height: 3 * s))
        p.move(to: CGPoint(x: 10 * s, y: 3.5 * s))
        p.addLine(to: CGPoint(x: 10 * s, y: 6.5 * s))
        return p
    }
}

private struct BotEyes: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 20
        var p = Path()
        p.addEllipse(in: CGRect(x: 6.5 * s, y: 10 * s, width: 2 * s, height: 2 * s))
        p.addEllipse(in: CGRect(x: 11.5 * s, y: 10 * s, width: 2 * s, height: 2 * s))
        return p
    }
}

// MARK: - Small pieces

/// Green "live" dot with a soft ring.
struct LiveDot: View {
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(PrismTheme.Colors.live)
            .frame(width: size, height: size)
            .background(Circle().fill(PrismTheme.Colors.live.opacity(0.18)).frame(width: size + 6, height: size + 6))
    }
}

/// Quiet tag for built-in profiles.
struct DefaultTag: View {
    var body: some View {
        Text("Default")
            .font(.system(size: 10.5))
            .foregroundStyle(PrismTheme.Colors.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(PrismTheme.Colors.border, lineWidth: 1))
            .fixedSize()
    }
}

// MARK: - Profile actions shared by rows, the inspector and menus

extension CursorProfile {
    /// Grok Bot has no new-window switch: launching a running profile
    /// again hands off to that instance, which brings its window forward.
    func primaryActionTitle(running: Bool) -> String {
        if running {
            return normalizedApp == Self.appGrokBot ? "Show" : "New Window"
        }
        return normalizedApp == Self.appClaudeCode ? "Open Terminal" : "Launch"
    }

    /// Cursor and Claude Code duplicates are full clones (same login);
    /// Desktop and Grok Bot copies are always overflow accounts.
    var clonesWholeProfile: Bool {
        normalizedApp == Self.appCursor || normalizedApp == Self.appClaudeCode
    }

    var duplicateTitle: String {
        if !clonesWholeProfile { return Self.copyMenuTitle(for: normalizedApp) }
        return isSystem ? "Clone into New Profile" : "Duplicate"
    }

    /// Sentence-case label for the "copy into a second account" action.
    var copyActionTitle: String {
        normalizedApp == Self.appGrokBot ? "Copy settings to a new profile" : "New overflow account from this"
    }

    var memoryCapLabel: String {
        defaultMemoryMB >= 1024
            ? String(format: "%.0f GB", Double(defaultMemoryMB) / 1024.0)
            : "\(defaultMemoryMB) MB"
    }
}

extension ProfileStore {
    /// One-click second account from `profile` (overflow / copied settings).
    func copyToNewProfile(_ profile: CursorProfile) {
        if profile.clonesWholeProfile {
            newOverflow(from: profile)
        } else {
            duplicate(profile)
        }
    }
}

/// The profile's full action menu, used by the row context menu and the
/// inspector's "…" button.
@MainActor
struct ProfileMenuItems: View {
    @EnvironmentObject var store: ProfileStore
    let profile: CursorProfile
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onOptions: () -> Void

    var body: some View {
        let running = store.isRunning(profile)
        let busy = store.duplicating.contains(profile.folderName)
        Button(profile.primaryActionTitle(running: running)) { store.launch(profile, newWindow: running) }
        Button("Launch with Options…") { onOptions() }
        if running {
            Button("Quit") { store.quit(profile) }
        }
        Divider()
        Button(profile.isPinned ? "Unpin" : "Pin to Top") { store.togglePin(profile) }
        GroupMenu(profile: profile)
        Button("Edit…") { onEdit() }
        Button(profile.duplicateTitle) { store.duplicate(profile) }
            .disabled(busy)
        if profile.clonesWholeProfile {
            Button(CursorProfile.copyMenuTitle(for: profile.normalizedApp)) { store.newOverflow(from: profile) }
                .disabled(busy)
        }
        Button("Show in Finder") { store.revealInFinder(profile) }
        if !profile.isSystem {
            Divider()
            Button("Move to Trash", role: .destructive) { onDelete() }
        }
    }
}

extension FileManager {
    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

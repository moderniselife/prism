import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Window dragging

/// A plain area that moves its window when dragged (double-click zooms or
/// minimises, following the system setting). Put it behind header bars:
/// clicks on buttons in front still reach the buttons.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.performMiniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
                return
            }
            window.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// Makes a plain area drag its window.
///
/// macOS 15+: SwiftUI's own WindowDragGesture. It goes through SwiftUI's
/// event handling, so it works even where an AppKit view sits underneath
/// (the profile list's scroll view reaches up under the header, and the
/// window server refused drags started over it). macOS 14: an AppKit drag
/// view, backed by the click monitor in AppDelegate.
struct WindowDragRegion: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
                .simultaneousGesture(TapGesture(count: 2).onEnded { WindowDragRegion.titleBarDoubleClick() })
        } else {
            content.background(WindowDragArea())
        }
    }

    /// What double-clicking a title bar does (System Settings → Desktop & Dock).
    @MainActor
    static func titleBarDoubleClick() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}

extension View {
    /// Drag the window from this view's empty space (see WindowDragRegion).
    func windowDragRegion() -> some View { modifier(WindowDragRegion()) }
}

// MARK: - How the hub arranges its list

enum HubGrouping: String, CaseIterable, Identifiable {
    case status, group

    static let storageKey = "hubGrouping"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .status: return "By status"
        case .group: return "By group"
        }
    }
}

// MARK: - Naming a group

@MainActor
enum GroupPrompt {
    /// Ask for a group name. Returns nil when cancelled or left empty.
    static func ask(title: String, initial: String = "", confirm: String = "Create",
                    info: String = "A project, client or kind of work. A group can hold profiles from any app.",
                    placeholder: String = "e.g. Acme, Side projects, Research") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

// MARK: - Group colour

/// A coloured swatch that opens a palette menu.
@MainActor
struct GroupColorMenu: View {
    @EnvironmentObject var store: ProfileStore
    let group: ProfileGroup

    var body: some View {
        Menu {
            GroupColorItems(group: group)
        } label: {
            GroupSwatch.image(group.colorHex, size: 14)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Colour")
    }
}

/// The palette as menu items, each with its colour.
@MainActor
struct GroupColorItems: View {
    @EnvironmentObject var store: ProfileStore
    let group: ProfileGroup

    var body: some View {
        ForEach(AccentPalette.all) { option in
            Button {
                var g = group
                g.colorHex = option.hex
                store.updateGroup(g)
            } label: {
                Label {
                    Text(option.name + (option.hex == group.colorHex ? "  ✓" : ""))
                } icon: {
                    GroupSwatch.image(option.hex)
                }
            }
        }
    }
}

struct GroupSwatch: View {
    let colorHex: String
    var size: CGFloat = 10

    /// The swatch as an image, for menus (they only draw text and images).
    static func image(_ hex: String, size: CGFloat = 12) -> Image {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            (NSColor(hex: hex) ?? .controlAccentColor).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                         xRadius: size * 0.3, yRadius: size * 0.3).fill()
            return true
        }
        return Image(nsImage: image)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(Color(hex: colorHex) ?? PrismTheme.Colors.accent)
            .frame(width: size, height: size)
    }
}

// MARK: - Filing a profile

/// "Group" submenu for a profile's context menu.
@MainActor
struct GroupMenu: View {
    @EnvironmentObject var store: ProfileStore
    let profile: CursorProfile

    var body: some View {
        Menu("Group") {
            ForEach(store.groups) { group in
                Button {
                    store.setGroup(group.id, for: [profile.id])
                } label: {
                    Label {
                        Text(group.name + (profile.groupID == group.id ? "  ✓" : ""))
                    } icon: {
                        GroupSwatch.image(group.colorHex)
                    }
                }
            }
            if !store.groups.isEmpty { Divider() }
            Button("New Group…") {
                if let name = GroupPrompt.ask(title: "New group for “\(profile.displayName)”") {
                    let group = store.addGroup(name: name)
                    store.setGroup(group.id, for: [profile.id])
                }
            }
            if profile.groupID != nil {
                Button("Remove from Group") { store.setGroup(nil, for: [profile.id]) }
            }
        }
    }
}

/// Inline picker for the detail panel and the profile editor.
@MainActor
struct GroupPicker: View {
    @EnvironmentObject var store: ProfileStore
    @Binding var groupID: String?

    var body: some View {
        let current = store.group(groupID)
        HStack(spacing: 6) {
            if let current {
                GroupSwatch(colorHex: current.colorHex, size: 9)
            }
            Menu {
                Button("No group") { groupID = nil }
                if !store.groups.isEmpty { Divider() }
                ForEach(store.groups) { group in
                    Button {
                        groupID = group.id
                    } label: {
                        Label { Text(group.name) } icon: { GroupSwatch.image(group.colorHex) }
                    }
                }
                Divider()
                Button("New Group…") {
                    if let name = GroupPrompt.ask(title: "New group") {
                        groupID = store.addGroup(name: name).id
                    }
                }
            } label: {
                (Text(current?.name ?? "No group")
                    + Text("  ")
                    + Text(Image(systemName: "chevron.up.chevron.down")).font(.system(size: 8, weight: .semibold)))
                    .font(.system(size: 12))
                    .foregroundStyle(current == nil ? PrismTheme.Colors.textTertiary : PrismTheme.Colors.textPrimary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

/// The group a row belongs to, as a small tag ("● Acme").
@MainActor
struct GroupTag: View {
    let group: ProfileGroup

    var body: some View {
        HStack(spacing: 4) {
            GroupSwatch(colorHex: group.colorHex, size: 7)
            Text(group.name)
                .lineLimit(1)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(PrismTheme.Colors.textTertiary)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .overlay(Capsule().strokeBorder(PrismTheme.Colors.border, lineWidth: 1))
        .help("Group: \(group.name)")
    }
}

// MARK: - Sidebar section

/// "Groups" in the hub sidebar: pick one to show only its profiles, drop a
/// profile on one to file it there.
@MainActor
struct SidebarGroups: View {
    @EnvironmentObject var store: ProfileStore
    @Binding var selectedGroup: String?
    var onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Groups")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
                Spacer()
                Button {
                    if let name = GroupPrompt.ask(title: "New group") {
                        let group = store.addGroup(name: name)
                        selectedGroup = group.id
                        onSelect()
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PrismTheme.Colors.textTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New group")
            }
            .padding(.horizontal, 10)
            .padding(.top, 20)
            .padding(.bottom, 6)

            if store.groups.isEmpty {
                Text("Sort profiles into projects or clients.")
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.Colors.textMuted)
                    .padding(.horizontal, 10)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(store.groups) { group in
                    SidebarGroupRow(group: group,
                                    selected: selectedGroup == group.id,
                                    onSelect: {
                                        selectedGroup = group.id
                                        onSelect()
                                    },
                                    onDeleted: {
                                        if selectedGroup == group.id { selectedGroup = nil }
                                    })
                }
            }
        }
    }
}

@MainActor
private struct SidebarGroupRow: View {
    @EnvironmentObject var store: ProfileStore
    let group: ProfileGroup
    let selected: Bool
    var onSelect: () -> Void
    var onDeleted: () -> Void
    @State private var dropTargeted = false

    var body: some View {
        let count = store.profiles(in: group.id).count
        Button(action: onSelect) {
            HStack(spacing: 10) {
                GroupSwatch(colorHex: group.colorHex, size: 10)
                    .frame(width: 16)
                Text(group.name)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(PrismTheme.Colors.textTertiary)
            }
            .foregroundStyle(selected ? PrismTheme.Colors.textPrimary : PrismTheme.Colors.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? PrismTheme.Colors.surfaceHigh : .clear))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(dropTargeted ? PrismTheme.Colors.accent : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: String.self) { ids, _ in
            let known = Set(store.profiles.map(\.id))
            let dropped = ids.filter { known.contains($0) }
            guard !dropped.isEmpty else { return false }
            store.setGroup(group.id, for: dropped)
            return true
        } isTargeted: { dropTargeted = $0 }
        .contextMenu {
            Button("Rename…") {
                if let name = GroupPrompt.ask(title: "Rename group", initial: group.name, confirm: "Rename") {
                    var g = group
                    g.name = name
                    store.updateGroup(g)
                }
            }
            Menu("Colour") {
                GroupColorItems(group: group)
            }
            Divider()
            Button("Move Up") { store.moveGroup(group.id, by: -1) }
                .disabled(store.groups.first?.id == group.id)
            Button("Move Down") { store.moveGroup(group.id, by: 1) }
                .disabled(store.groups.last?.id == group.id)
            Divider()
            Button("Delete Group", role: .destructive) {
                store.deleteGroup(group.id)
                onDeleted()
            }
        }
        .help("Drop profiles here to add them to \(group.name)")
    }
}

import SwiftUI

// MARK: - Profile model

struct CursorProfile: Identifiable, Codable, Equatable, Hashable {
    /// Reserved folder name marking the built-in Cursor profile
    /// (~/Library/Application Support/Cursor). It is not a real folder in
    /// ~/.cursor_profiles and can never be deleted from this app.
    static let systemFolderName = "__cursor-default__"

    var folderName: String          // directory name inside ~/.cursor_profiles
    var displayName: String
    var emoji: String
    var colorHex: String
    var defaultMemoryMB: Int
    var defaultProjectPath: String?
    var createdAt: Date
    var lastLaunchedAt: Date?
    var isPinned: Bool
    var isSystem: Bool = false      // the user's original Cursor profile

    var id: String { folderName }

    enum CodingKeys: String, CodingKey {
        case folderName, displayName, emoji, colorHex, defaultMemoryMB,
             defaultProjectPath, createdAt, lastLaunchedAt, isPinned, isSystem
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folderName = try c.decode(String.self, forKey: .folderName)
        displayName = try c.decode(String.self, forKey: .displayName)
        emoji = try c.decode(String.self, forKey: .emoji)
        colorHex = try c.decode(String.self, forKey: .colorHex)
        defaultMemoryMB = try c.decode(Int.self, forKey: .defaultMemoryMB)
        defaultProjectPath = try c.decodeIfPresent(String.self, forKey: .defaultProjectPath)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastLaunchedAt = try c.decodeIfPresent(Date.self, forKey: .lastLaunchedAt)
        isPinned = try c.decode(Bool.self, forKey: .isPinned)
        isSystem = try c.decodeIfPresent(Bool.self, forKey: .isSystem) ?? false
    }

    init(folderName: String,
         displayName: String,
         emoji: String = "🖥️",
         colorHex: String = AccentPalette.random().hex,
         defaultMemoryMB: Int = 16384,
         defaultProjectPath: String? = nil,
         createdAt: Date = Date(),
         lastLaunchedAt: Date? = nil,
         isPinned: Bool = false,
         isSystem: Bool = false) {
        self.folderName = folderName
        self.displayName = displayName
        self.emoji = emoji
        self.colorHex = colorHex
        self.defaultMemoryMB = defaultMemoryMB
        self.defaultProjectPath = defaultProjectPath
        self.createdAt = createdAt
        self.lastLaunchedAt = lastLaunchedAt
        self.isPinned = isPinned
        self.isSystem = isSystem
    }

    var accentColor: Color { Color(hex: colorHex) ?? .accentColor }
}

// MARK: - Accent palette

struct AccentPalette: Identifiable, Equatable {
    let name: String
    let hex: String
    var id: String { hex }
    var color: Color { Color(hex: hex) ?? .accentColor }

    static let all: [AccentPalette] = [
        .init(name: "Indigo",   hex: "#6366F1"),
        .init(name: "Violet",   hex: "#8B5CF6"),
        .init(name: "Fuchsia",  hex: "#D946EF"),
        .init(name: "Rose",     hex: "#F43F5E"),
        .init(name: "Orange",   hex: "#F97316"),
        .init(name: "Amber",    hex: "#F59E0B"),
        .init(name: "Emerald",  hex: "#10B981"),
        .init(name: "Teal",     hex: "#14B8A6"),
        .init(name: "Sky",      hex: "#0EA5E9"),
        .init(name: "Blue",     hex: "#3B82F6"),
        .init(name: "Slate",    hex: "#64748B"),
        .init(name: "Lime",     hex: "#84CC16"),
    ]

    static func random() -> AccentPalette { all.randomElement()! }
}

let emojiChoices: [String] = [
    "🖥️", "🚀", "⚡️", "🔥", "🧪", "🎨", "🛠️", "🧠", "💼", "🏠",
    "🌙", "☀️", "🐙", "🦄", "🍕", "🎮", "🔒", "🌈", "💎", "🤖",
    "👾", "🧬", "📦", "🪄", "🐉", "🍄", "🌊", "🏴‍☠️", "🎧", "🫠",
]

// MARK: - Color helpers

extension Color {
    init?(hex: String) {
        var str = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("#") { str.removeFirst() }
        guard str.count == 6, let value = UInt64(str, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}

// MARK: - Formatting helpers

enum Format {
    static func bytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "…" }
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "never launched" }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Folder-name sanitizing (letters, digits, _ and - only)

enum ProfileNaming {
    static func sanitizeFolderName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return String(raw.unicodeScalars.filter { allowed.contains($0) })
    }
}

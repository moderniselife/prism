import Foundation

// MARK: - Overflow accounts for every app
//
// An overflow profile is a new profile that carries another profile's
// config over, but never its identity: it starts signed out with its own
// machine id, and you sign in with a different account on first launch.
//
// Each app keeps config and identity in different places, so each has its
// own rule. Rules are allowlists wherever the app mixes the two (Cursor,
// Claude Code, Claude Desktop): anything not listed stays behind, so an
// unknown new token file can never leak into an overflow profile. Grok Bot
// keeps them in separate trees, so its rule is a denylist (GrokLauncher).
//
// Keep in sync with tui/carryover.go (which has the tests) and
// linux/prism.py.

enum CarryOver {

    /// Cursor: user settings, keybindings, tasks, snippets. The login lives
    /// in User/globalStorage/state.vscdb next to unrelated state, and the
    /// machine id in machineid/storage.json, so none of those travel.
    /// Extensions already live in ~/.cursor/extensions, shared by profiles.
    static let cursorEntries = [
        "User/settings.json",
        "User/keybindings.json",
        "User/tasks.json",
        "User/snippets",
    ]

    /// Claude Desktop: MCP servers/preferences and installed extensions
    /// with their settings. Sign-in lives in cookies and Chromium storage.
    static let desktopEntries = [
        "claude_desktop_config.json",
        "Claude Extensions",
        "Claude Extensions Settings",
    ]

    /// Claude Code: everything that shapes how it works for you.
    /// Credentials (.credentials.json, or the Keychain on macOS), session
    /// history, todos, shell snapshots and caches stay behind.
    static let claudeCodeEntries = [
        "settings.json",
        "CLAUDE.md",
        "keybindings.json",
        "agents",
        "commands",
        "skills",
        "output-styles",
        "hooks",
        "plugins",
    ]

    /// The parts of .claude.json that are preferences or user-scoped MCP
    /// servers; the rest is account identity, project history and caches.
    static let claudeCodeStateKeys = [
        "mcpServers",
        "theme",
        "editorMode",
        "autoCompactEnabled",
        "verbose",
        "preferredNotifChannel",
    ]

    enum CarryOverError: LocalizedError {
        case missingSource(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .missingSource(let path):
                return "There is nothing to carry over yet — \(path) doesn't exist. Launch the source profile once first."
            case .unreadable(let path):
                return "Couldn't read \(path)."
            }
        }
    }

    /// Copy `source`'s config into `destinationDir` (a new profile folder of
    /// the same app). Returns the number of files copied.
    static func run(app: String, sourceDir: URL, sourceIsSystem: Bool,
                    destinationDir: URL) throws -> Int {
        switch CursorProfile.normalizeApp(app) {
        case CursorProfile.appGrokBot:
            return try GrokLauncher.carryOver(
                from: GrokLauncher.dataRoot(profileDir: sourceDir, isSystem: sourceIsSystem),
                to: GrokLauncher.dataRoot(profileDir: destinationDir, isSystem: false))
        case CursorProfile.appClaudeCode:
            var copied = try copyAllowlist(from: sourceDir, to: destinationDir, entries: claudeCodeEntries)
            try rewritePluginPaths(in: destinationDir.appendingPathComponent("plugins"),
                                   from: sourceDir, to: destinationDir)
            if try copyClaudeState(
                from: claudeCodeStateFile(configDir: sourceDir, isSystem: sourceIsSystem),
                to: destinationDir.appendingPathComponent(".claude.json")) {
                copied += 1
            }
            return copied
        case CursorProfile.appClaudeDesktop:
            return try copyAllowlist(from: sourceDir, to: destinationDir, entries: desktopEntries)
        default:
            return try copyAllowlist(from: sourceDir, to: destinationDir, entries: cursorEntries)
        }
    }

    /// Where Claude Code keeps .claude.json for a config dir: inside it when
    /// CLAUDE_CONFIG_DIR points there, in the home folder otherwise.
    static func claudeCodeStateFile(configDir: URL, isSystem: Bool) -> URL {
        let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? ""
        if isSystem && override.isEmpty {
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
        }
        return configDir.appendingPathComponent(".claude.json")
    }

    // MARK: Helpers

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func skipsAnywhere(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["lockfile", "singletonlock", "singletonsocket", "singletoncookie"].contains(lower)
            || lower.hasSuffix(".lock") || lower.hasSuffix(".sock") || lower.hasSuffix(".pid")
    }

    /// Copy the listed slash-separated entries that exist.
    static func copyAllowlist(from sourceDir: URL, to destinationDir: URL,
                              entries: [String]) throws -> Int {
        guard isDirectory(sourceDir) else {
            throw CarryOverError.missingSource((sourceDir.path as NSString).abbreviatingWithTildeInPath)
        }
        var copied = 0
        for entry in entries {
            let source = sourceDir.appendingPathComponent(entry)
            let keys: Set<URLResourceKey> = [.isSymbolicLinkKey]
            guard (try? source.checkResourceIsReachable()) == true,
                  (try? source.resourceValues(forKeys: keys))?.isSymbolicLink != true else { continue }
            try copyTree(source: source, destination: destinationDir.appendingPathComponent(entry),
                         copied: &copied)
        }
        return copied
    }

    /// Copy a file or directory, skipping symlinks, special files and
    /// lock/socket files.
    private static func copyTree(source: URL, destination: URL, copied: inout Int) throws {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let values = try source.resourceValues(forKeys: Set(keys))
        if values.isSymbolicLink == true || skipsAnywhere(source.lastPathComponent) { return }
        if values.isDirectory == true {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            for entry in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: keys, options: []) {
                try copyTree(source: entry, destination: destination.appendingPathComponent(entry.lastPathComponent),
                             copied: &copied)
            }
        } else if values.isRegularFile == true {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: source, to: destination)
            copied += 1
        }
    }

    /// Write only the allowlisted keys of .claude.json. Returns whether a
    /// file was written.
    private static func copyClaudeState(from source: URL, to destination: URL) throws -> Bool {
        guard let data = try? Data(contentsOf: source) else { return false }
        guard let all = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CarryOverError.unreadable((source.path as NSString).abbreviatingWithTildeInPath)
        }
        let kept = all.filter { claudeCodeStateKeys.contains($0.key) }
        guard !kept.isEmpty else { return false }
        let out = try JSONSerialization.data(withJSONObject: kept, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return true
    }

    /// Claude Code records absolute install paths inside plugins/*.json:
    /// point the copies at the new profile, not the source's folder.
    private static func rewritePluginPaths(in pluginsDir: URL, from sourceDir: URL, to destinationDir: URL) throws {
        guard isDirectory(pluginsDir),
              let walker = FileManager.default.enumerator(at: pluginsDir, includingPropertiesForKeys: nil)
        else { return }
        let from = sourceDir.path
        let to = destinationDir.path
        // JSON escapes "/" as "\/" in some writers; cover both spellings.
        let escapedFrom = from.replacingOccurrences(of: "/", with: "\\/")
        let escapedTo = to.replacingOccurrences(of: "/", with: "\\/")
        for case let file as URL in walker where file.pathExtension == "json" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let rewritten = text
                .replacingOccurrences(of: from, with: to)
                .replacingOccurrences(of: escapedFrom, with: escapedTo)
            if rewritten != text {
                try rewritten.write(to: file, atomically: true, encoding: .utf8)
            }
        }
    }
}

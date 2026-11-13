import AppKit
import Foundation

// MARK: - Finding, launching & cloning Grok Bot
//
// Grok Bot is an Electron app whose main process honours the
// SAND_USER_DATA_DIR environment variable in release builds: it becomes
// the app's userData *and* moves the agent data root from ~/.grokbot to
// <dir>/sand-data. The single-instance lock is taken after that switch, so
// every profile is its own instance with its own login. Prism also passes a
// matching --user-data-dir=<dir> (the app keeps it across its own
// relaunches) purely so the profile can be found in the process list —
// environment variables are invisible there.
//
// Sign-in is a browser round-trip the app polls for, so several profiles
// can sign in to different accounts at the same time.

enum GrokLauncher {

    static let bundleIdentifiers = ["com.anysphere.sand"]
    static let executableName = "Grok Bot"
    static let userDataEnv = "SAND_USER_DATA_DIR"
    /// Where an isolated profile keeps agents/settings (the default install
    /// uses ~/.grokbot instead).
    static let dataSubdir = "sand-data"

    static let candidatePaths: [String] = [
        "/Applications/Grok Bot.app/Contents/MacOS/Grok Bot",
        NSHomeDirectory() + "/Applications/Grok Bot.app/Contents/MacOS/Grok Bot",
    ]

    /// Locate Grok Bot: custom path -> Launch Services -> known paths.
    static func findGrokBot(customPath: String?) -> String? {
        if let customPath, !customPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: customPath) {
            return customPath
        }
        for bundleID in bundleIdentifiers {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let exec = appURL.appendingPathComponent("Contents/MacOS/\(executableName)").path
                if FileManager.default.isExecutableFile(atPath: exec) { return exec }
            }
        }
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    // MARK: Data locations

    /// Electron's default userData for the app (appData + productName).
    static var systemUserDataDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Grok Bot")
    }

    /// Where the default install keeps agents and settings: ~/.grokbot, or
    /// the pre-rename ~/.cursor/sand on installs that never migrated.
    static var systemDataRoot: URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let canonical = home.appendingPathComponent(".grokbot")
        if isDirectory(canonical) { return canonical }
        let legacy = home.appendingPathComponent(".cursor/sand")
        if isDirectory(legacy) { return legacy }
        return canonical
    }

    /// A profile's agent data root.
    static func dataRoot(profileDir: URL, isSystem: Bool) -> URL {
        isSystem ? systemDataRoot : profileDir.appendingPathComponent(dataSubdir)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: Launching

    enum LaunchError: LocalizedError {
        case notFound
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "Grok Bot could not be found. Install it or set a custom path in Settings."
            case .failed(let message):
                return message
            }
        }
    }

    /// Launch Grok Bot. Pass `userDataDir: nil` for the built-in profile —
    /// no flag, no environment: exactly like opening it from the Dock.
    static func launch(userDataDir: URL?, grokPath: String?,
                       onFailure: @escaping @Sendable (String) -> Void) throws {
        guard let exe = findGrokBot(customPath: grokPath) else {
            throw LaunchError.notFound
        }
        var args: [String] = []
        var environment: [String: String] = [:]
        if let userDataDir {
            try FileManager.default.createDirectory(at: userDataDir, withIntermediateDirectories: true)
            args = ["--user-data-dir=\(userDataDir.path)"]
            environment = [userDataEnv: userDataDir.path]
        }
        do {
            try CursorLauncher.launchDetached(executable: exe, arguments: args,
                                              environment: environment) { message in
                onFailure("Failed to launch Grok Bot: \(message)")
            }
        } catch {
            throw LaunchError.failed("Failed to launch Grok Bot: \(error.localizedDescription)")
        }
    }

    // MARK: Process detection

    /// True only for the app's main process. Grok Bot also runs its
    /// local-exec daemon and agent coordinator through the *same*
    /// executable (as node, with a .cjs entry script inside app.asar), and
    /// Chromium helpers carry --type=; none of those is the profile itself.
    static func isMainExecutable(_ command: String) -> Bool {
        let needle = "Grok Bot.app/Contents/MacOS/Grok Bot"
        guard let range = command.range(of: needle) else { return false }
        let after = command[range.upperBound...]
        guard after.isEmpty || after.hasPrefix(" ") else { return false }
        if command.contains("--type=") { return false }
        if after.contains(".cjs") || after.contains("app.asar") { return false }
        return true
    }

    /// PIDs of the main process for a managed profile, found by the
    /// `--user-data-dir=<path>` marker Prism launches it with. The marker
    /// must end at a token boundary so "Work" never matches "Work-2".
    static func pids(in list: [CursorLauncher.ProcessEntry], profileDir: URL) -> [Int32] {
        let needle = "--user-data-dir=\(profileDir.path)"
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.filter {
            $0.pid != ownPID &&
            isMainExecutable($0.command) &&
            ($0.command.hasSuffix(needle) || $0.command.contains(needle + " "))
        }.map(\.pid)
    }

    /// PIDs of the built-in profile: a main process with no marker.
    static func systemPIDs(in list: [CursorLauncher.ProcessEntry]) -> [Int32] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.filter {
            $0.pid != ownPID &&
            isMainExecutable($0.command) &&
            !$0.command.contains("--user-data-dir")
        }.map(\.pid)
    }

    // MARK: Overflow-account carry-over
    //
    // An overflow profile is a second account that picks up where the first
    // left off: same agents, settings, tool approvals, plugins and MCP
    // setup, but its own sign-in. Only the agent data root is copied.
    // Everything in Electron's userData is per-account or per-machine
    // (Keychain-encrypted tokens *and* the machine id in sand-secrets.json,
    // user-secrets.json, cookies, account-scoped sand-client-persistence,
    // automation webhook keys), so it is never copied: the new profile
    // starts signed out with a fresh machine identity.
    //
    // Keep these lists in sync with tui/grokbot.go (which has the tests).

    /// Data-root entries that identify an account, a machine or a running
    /// instance. Matched by exact name, or name + "." (atomic-write temp
    /// files and backups such as mcp-auth.json.123).
    static let skippedTopLevel: [String] = [
        ".grokbot-data-root-v1",      // migration marker for the default root
        "host.lock",                  // live-instance lock
        "host-token.json",            // host auth
        "host-secrets.json",          // host auth
        "gateway.json",               // local gateway token
        "gateway-descriptor.json",    // local gateway endpoint
        "mcp-auth.json",              // MCP OAuth tokens of the source account
        "onepassword-oauth-states.json",
        "local-tool-spent-sends.json", // per-instance ledger
        "local-tool-retirements.json", // per-instance ledger
        "local-cua-helper.json",      // computer-use helper registration
        "recreate-intent.json",
        "recreate-resume.json",
        "desktop-status.json",
        "kept-update.json",
        "dev-box",                    // local container state
        "computer-use",               // helper runtime state
        "logs",
        "v8-code-cache",
    ]

    /// The local-exec daemon's discovery, credential, connection, lease and
    /// account-generation files are bound to the running, signed-in instance.
    static let skippedTopLevelPrefixes = ["local-exec-"]

    /// Whether a data-root entry stays behind. `relativePath` is
    /// slash-separated and relative to the data root.
    static func carryOverSkips(_ relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let top = parts.first, let leaf = parts.last else { return true }
        let lowerLeaf = leaf.lowercased()
        if ["lockfile", "singletonlock", "singletonsocket", "singletoncookie"].contains(lowerLeaf)
            || lowerLeaf.hasSuffix(".lock") || lowerLeaf.hasSuffix(".sock") || lowerLeaf.hasSuffix(".pid") {
            return true
        }
        if skippedTopLevel.contains(where: { top == $0 || top.hasPrefix($0 + ".") }) { return true }
        return skippedTopLevelPrefixes.contains(where: { top.hasPrefix($0) })
    }

    enum CarryOverError: LocalizedError {
        case missingSource(String)

        var errorDescription: String? {
            switch self {
            case .missingSource(let path):
                return "There is nothing to carry over yet — \(path) doesn't exist. Launch the source profile once first."
            }
        }
    }

    /// Copy agents and config from one data root to another, leaving
    /// identity, credentials and runtime state behind. Symlinks and special
    /// files are skipped, never followed. Returns the number of files copied.
    static func carryOver(from sourceRoot: URL, to destinationRoot: URL) throws -> Int {
        guard isDirectory(sourceRoot) else {
            throw CarryOverError.missingSource((sourceRoot.path as NSString).abbreviatingWithTildeInPath)
        }
        var copied = 0
        try copyTree(source: sourceRoot, destination: destinationRoot, relativePath: "", copied: &copied)
        return copied
    }

    private static func copyTree(source: URL, destination: URL, relativePath: String,
                                 copied: inout Int) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let entries = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: keys, options: [])
        for entry in entries {
            let name = entry.lastPathComponent
            let childPath = relativePath.isEmpty ? name : relativePath + "/" + name
            if carryOverSkips(childPath) { continue }
            let values = try entry.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { continue }
            let target = destination.appendingPathComponent(name)
            if values.isDirectory == true {
                try copyTree(source: entry, destination: target, relativePath: childPath, copied: &copied)
            } else if values.isRegularFile == true {
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: entry, to: target)
                copied += 1
            }
        }
    }
}

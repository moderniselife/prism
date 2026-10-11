import AppKit
import Foundation

// MARK: - Finding & launching Claude Code and Claude Desktop
//
// Claude Code profiles are isolated with CLAUDE_CONFIG_DIR (the documented
// multi-account mechanism); Claude Desktop is an Electron app isolated with
// --user-data-dir, exactly like Cursor.

enum ClaudeLauncher {

    /// Well-known install locations.
    static let desktopCandidatePaths: [String] = [
        "/Applications/Claude.app/Contents/MacOS/Claude",
        NSHomeDirectory() + "/Applications/Claude.app/Contents/MacOS/Claude",
        "/usr/local/bin/claude-desktop",
        "/opt/homebrew/bin/claude-desktop",
    ]

    static let codeCandidatePaths: [String] = [
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
        NSHomeDirectory() + "/.local/bin/claude",
    ]

    /// Locate the Claude Code CLI: custom path -> PATH -> known paths.
    static func findClaudeCode(customPath: String?) -> String? {
        if let customPath, !customPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: customPath) {
            return customPath
        }
        for name in ["claude"] {
            if let found = lookupOnPath(name) { return found }
        }
        for path in codeCandidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Locate Claude Desktop: custom path -> Launch Services -> known paths.
    static func findClaudeDesktop(customPath: String?) -> String? {
        if let customPath, !customPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: customPath) {
            return customPath
        }
        for bundleID in ["com.anthropic.claudefordesktop", "com.anthropic.claude"] {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let exec = appURL.appendingPathComponent("Contents/MacOS/Claude").path
                if FileManager.default.isExecutableFile(atPath: exec) { return exec }
            }
        }
        for path in desktopCandidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static func lookupOnPath(_ name: String) -> String? {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    enum LaunchError: LocalizedError {
        case codeNotFound
        case desktopNotFound
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .codeNotFound:
                return "Claude Code could not be found. Install it (see code.claude.com/docs) or set a custom path in Settings."
            case .desktopNotFound:
                return "Claude Desktop could not be found. Install it from claude.com/download or set a custom path in Settings."
            case .failed(let message):
                return message
            }
        }
    }

    /// Open Terminal running the CLI with this profile as its config dir.
    /// The CLI is interactive, so it gets its own window rather than a
    /// headless spawn. First launch walks through login for the new account.
    static func launchCode(profileDir: URL, displayName: String,
                           codePath: String?, projectPath: String?,
                           isSystem: Bool) throws {
        guard findClaudeCode(customPath: codePath) != nil else {
            throw LaunchError.codeNotFound
        }
        if !isSystem {
            try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        }
        var work = projectPath ?? ""
        if work.isEmpty { work = NSHomeDirectory() }
        // Single-quote for sh, then escape for the AppleScript string literal.
        func shellQuote(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let command = "export CLAUDE_CONFIG_DIR=\(shellQuote(profileDir.path))"
            + " && cd \(shellQuote(work)) && exec claude"
        let appleQuoted = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\n"
            + "activate\n"
            + "do script \"\(appleQuoted)\"\n"
            + "end tell"
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
        if error != nil {
            throw LaunchError.failed("Could not open Terminal for Claude Code: \(error.debugDescription)")
        }
    }

    /// Launch Claude Desktop. Pass `userDataDir: nil` for the built-in
    /// profile (no --user-data-dir), exactly like opening it normally.
    /// Managed profiles pass the Chromium `--user-data-dir=<path>` switch
    /// (must use "=": Chromium doesn't take a space-separated value). Verified
    /// on Windows with the standalone build; not yet verified on macOS.
    static func launchDesktop(userDataDir: URL?, desktopPath: String?,
                              options: CursorLauncher.LaunchOptions) throws {
        guard let exe = findClaudeDesktop(customPath: desktopPath) else {
            throw LaunchError.desktopNotFound
        }
        var args: [String] = []
        if let userDataDir {
            try FileManager.default.createDirectory(at: userDataDir, withIntermediateDirectories: true)
            args = ["--user-data-dir=\(userDataDir.path)"]
        }
        if options.newWindow { args.append("--new-window") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw LaunchError.failed("Failed to launch Claude Desktop: \(error.localizedDescription)")
        }
    }

    /// True when `command` runs the real Desktop main executable. Rejects the
    /// bundled Claude Code helper (same process family, lives under a
    /// claude-code path), non-main helpers, and — critically — the standalone
    /// `claude` CLI, which shares the executable name on every OS but never
    /// runs inside Claude.app.
    static func isMainDesktopExecutable(_ command: String) -> Bool {
        if command.localizedCaseInsensitiveContains("claude-code") { return false }
        if command.contains("--type=") { return false }
        let first = command.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        if (first as NSString).lastPathComponent.lowercased() == "claude-desktop" { return true }
        if let range = command.range(of: "Claude.app/Contents/MacOS/Claude") {
            let after = command[range.upperBound...]
            return after.isEmpty || after.hasPrefix(" ")
        }
        return false
    }

    /// PIDs of the Desktop main process for a managed profile directory,
    /// detected by its `--user-data-dir <path>` argument.
    static func desktopPIDs(in list: [CursorLauncher.ProcessEntry], profileDir: URL) -> [Int32] {
        let needles = ["--user-data-dir=\(profileDir.path)", "--user-data-dir \(profileDir.path)"]
        return list.filter {
            $0.pid != ProcessInfo.processInfo.processIdentifier &&
            needles.contains(where: $0.command.contains) &&
            isMainDesktopExecutable($0.command)
        }.map(\.pid)
    }

    /// PIDs of the Desktop main process running the *built-in* profile —
    /// a Desktop main process with no --user-data-dir at all.
    static func systemDesktopPIDs(in list: [CursorLauncher.ProcessEntry]) -> [Int32] {
        list.filter {
            $0.pid != ProcessInfo.processInfo.processIdentifier &&
            isMainDesktopExecutable($0.command) &&
            !$0.command.contains("--user-data-dir")
        }.map(\.pid)
    }

    /// Electron holds a lockfile inside a live user-data-dir. The -1 sentinel
    /// marks "running" without a matchable PID; it must never be signaled.
    static func desktopLockHeld(profileDir: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: profileDir.appendingPathComponent("lockfile").path)
    }

    /// Politely ask processes to quit (SIGTERM). Skips sentinel PIDs —
    /// signaling -1 would hit the whole process group.
    static func quit(pids: [Int32]) {
        for pid in pids where pid > 0 { kill(pid, SIGTERM) }
    }
}

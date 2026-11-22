import AppKit
import Foundation

// MARK: - Finding & launching Cursor

enum CursorLauncher {

    /// Well-known install locations.
    static let candidatePaths: [String] = [
        "/Applications/Cursor.app/Contents/MacOS/Cursor",
        NSHomeDirectory() + "/Applications/Cursor.app/Contents/MacOS/Cursor",
        "/usr/local/bin/cursor",
        "/opt/homebrew/bin/cursor",
    ]

    /// Locate the Cursor executable: custom path -> Launch Services -> known paths.
    static func findCursor(customPath: String?) -> String? {
        if let customPath, !customPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: customPath) {
            return customPath
        }
        // Ask Launch Services for Cursor.app (todesktop bundle id used by Cursor).
        for bundleID in ["com.todesktop.230313mzl4w4u92", "sh.cursor.Cursor"] {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let exec = appURL.appendingPathComponent("Contents/MacOS/Cursor").path
                if FileManager.default.isExecutableFile(atPath: exec) { return exec }
            }
        }
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    struct LaunchOptions {
        var memoryMB: Int
        var projectPath: String?
        var newWindow: Bool = false
    }

    enum LaunchError: LocalizedError {
        case cursorNotFound
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cursorNotFound:
                return "Cursor could not be found. Install it from cursor.sh or set a custom path in Settings."
            case .failed(let message):
                return "Failed to launch Cursor: \(message)"
            }
        }
    }

    /// Launch Cursor. Pass `userDataDir: nil` to launch the built-in default
    /// profile (no --user-data-dir), exactly like opening Cursor normally.
    static func launch(userDataDir: URL?, cursorPath: String?, options: LaunchOptions,
                       onFailure: @escaping @Sendable (String) -> Void) throws {
        guard let exe = findCursor(customPath: cursorPath) else {
            throw LaunchError.cursorNotFound
        }

        var args = ["--max-memory=\(options.memoryMB)"]
        if let userDataDir {
            try FileManager.default.createDirectory(at: userDataDir, withIntermediateDirectories: true)
            args = ["--user-data-dir", userDataDir.path] + args
        }
        if options.newWindow { args.append("--new-window") }
        if let project = options.projectPath, !project.isEmpty {
            args.append(project)
        }

        try launchDetached(executable: exe, arguments: args, onFailure: onFailure)
    }

    /// The `.app` bundle an executable lives in (…/Foo.app/Contents/MacOS/Foo).
    static func appBundle(forExecutable exe: String) -> URL? {
        guard let range = exe.range(of: ".app/Contents/MacOS/") else { return nil }
        return URL(fileURLWithPath: String(exe[..<range.lowerBound]) + ".app")
    }

    /// Bundle identifier of the app an executable belongs to.
    static func bundleIdentifier(forExecutable exe: String) -> String? {
        appBundle(forExecutable: exe).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// Start an app as its own independent instance via Launch Services, the
    /// same way Finder/Dock would. Spawning the executable as our child
    /// instead ties its lifecycle to Prism: it inherits our coalition and
    /// "responsible process", so the OS and the app's updater treat Prism and
    /// the instance as one unit (quitting one could take down the other).
    /// CLI shims outside an .app bundle fall back to a plain spawn.
    /// `environment` is added on top of the normal login environment (used
    /// by apps isolated with an env var rather than a flag, e.g. Grok Bot).
    static func launchDetached(executable exe: String, arguments args: [String],
                               environment: [String: String] = [:],
                               onFailure: @escaping @Sendable (String) -> Void) throws {
        if let bundle = appBundle(forExecutable: exe) {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.arguments = args
            if !environment.isEmpty { config.environment = environment }
            config.activates = true
            NSWorkspace.shared.openApplication(at: bundle, configuration: config) { _, error in
                if let error { onFailure(error.localizedDescription) }
            }
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, new in new }
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw LaunchError.failed(error.localizedDescription)
        }
    }

    struct ProcessEntry: Sendable {
        let pid: Int32
        let rssKB: Int64      // resident set size, kilobytes (live RAM)
        let cpuPercent: Double
        let command: String
    }

    /// One snapshot of all processes (pid + live RSS + CPU % + command line).
    /// Single `ps` invocation so RSS/CPU/PID detection never disagree.
    static func processList() -> [ProcessEntry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["ax", "-o", "pid=,rss=,%cpu=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard let waitForExit = try? process.launchForBlockingWait() else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        waitForExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = Int32(parts[0]),
                  let rss = Int64(parts[1]) else { return nil }
            let cpu = Double(parts[2].replacingOccurrences(of: ",", with: ".")) ?? 0
            let command = parts[3...].joined(separator: " ")
            return ProcessEntry(pid: pid, rssKB: rss, cpuPercent: cpu, command: command)
        }
    }

    /// Our own PID — must never be mistaken for a Cursor instance (older
    /// builds' binary was …/Prism.app/…/CursorProfiles, which contains the
    /// string "Cursor"). Matching ourselves once meant Stop SIGTERM'd
    /// Prism itself, i.e. an instant "crash".
    private static var ownPID: Int32 { ProcessInfo.processInfo.processIdentifier }

    /// True when `command` runs the real Cursor main executable: the path
    /// must end at a token boundary ("…/MacOS/Cursor" followed by space or
    /// end-of-string), rejecting "…/CursorProfiles" (us) and helpers.
    private static func isMainCursorExecutable(_ command: String) -> Bool {
        guard let range = command.range(of: ".app/Contents/MacOS/Cursor") else {
            return false
        }
        let after = command[range.upperBound...]
        guard after.isEmpty || after.hasPrefix(" ") else { return false }
        return true
    }

    /// PIDs of the main Cursor process for a managed profile directory,
    /// detected by its `--user-data-dir <path>` argument.
    static func pids(in list: [ProcessEntry], profileDir: URL) -> [Int32] {
        let needle = "--user-data-dir \(profileDir.path)"
        return list.filter {
            $0.pid != ownPID &&
            $0.command.contains(needle) &&
            // Only count the main process, not renderer/gpu helpers.
            !$0.command.contains("--type=")
        }.map(\.pid)
    }

    /// PIDs of the main Cursor process running the *built-in* profile —
    /// a Cursor main process with no --user-data-dir at all.
    static func systemProfilePIDs(in list: [ProcessEntry]) -> [Int32] {
        list.filter {
            $0.pid != ownPID &&
            isMainCursorExecutable($0.command) &&
            !$0.command.contains("--type=") &&
            !$0.command.contains("--user-data-dir") &&
            !$0.command.contains("Cursor Helper")
        }.map(\.pid)
    }

    /// True while an app's Squirrel.Mac updater has a downloaded update
    /// staged and is waiting to install it. ShipIt runs as
    /// "…/ShipIt <bundleID>.ShipIt <state plist>" from the moment the update
    /// is requested until *every* instance of the bundle has quit — any
    /// running profile holds it off indefinitely.
    static func updatePending(bundleID: String, in list: [ProcessEntry]) -> Bool {
        let needle = "/Squirrel.framework/Resources/ShipIt \(bundleID).ShipIt"
        return list.contains { $0.command.contains(needle) }
    }

    /// Version of the update the app's Squirrel updater has downloaded, when
    /// it's newer than the installed app. ShipIt records the download in
    /// ~/Library/Caches/<bundleID>.ShipIt/ShipItState.plist and deletes the
    /// bundle once it installs, so a leftover state file never counts.
    /// Info.plist is read directly: Bundle caches it and would go stale
    /// after the app updates in place.
    static func stagedUpdateVersion(bundleID: String, appPath: String) -> String? {
        let state = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/\(bundleID).ShipIt/ShipItState.plist")
        // Despite the name, Squirrel writes this file as JSON; accept a real
        // plist too in case that ever changes.
        guard let data = try? Data(contentsOf: state),
              let object = (try? JSONSerialization.jsonObject(with: data))
                ?? (try? PropertyListSerialization.propertyList(from: data, format: nil)),
              let dict = object as? [String: Any],
              let raw = dict["updateBundleURL"] as? String,
              let url = URL(string: raw), url.isFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let staged = bundleVersion(at: url.path) else { return nil }
        guard let installed = bundleVersion(at: appPath) else { return staged }
        return isNewer(staged, than: installed) ? staged : nil
    }

    static func bundleVersion(at appPath: String) -> String? {
        let info = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: info) else { return nil }
        return (dict["CFBundleShortVersionString"] as? String) ?? (dict["CFBundleVersion"] as? String)
    }

    /// Numeric dotted-version compare ("3.31.15" > "3.30.14").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Politely ask a running profile's processes to quit (SIGTERM).
    /// Skips sentinel PIDs — signaling -1 would hit the whole process group.
    static func quit(pids: [Int32]) {
        for pid in pids where pid > 0 { kill(pid, SIGTERM) }
    }
}

/// An app Prism watches for staged updates.
struct UpdatableApp: Sendable {
    let bundleID: String
    let bundlePath: String
}

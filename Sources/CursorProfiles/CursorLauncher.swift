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
    static func launch(userDataDir: URL?, cursorPath: String?, options: LaunchOptions) throws {
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw LaunchError.failed(error.localizedDescription)
        }
    }

    struct ProcessEntry {
        let pid: Int32
        let command: String
    }

    /// One snapshot of all processes (pid + full command line).
    static func processList() -> [ProcessEntry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["ax", "-o", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let pidStr = trimmed.split(separator: " ").first,
                  let pid = Int32(pidStr) else { return nil }
            return ProcessEntry(pid: pid, command: String(trimmed))
        }
    }

    /// PIDs of the main Cursor process for a managed profile directory,
    /// detected by its `--user-data-dir <path>` argument.
    static func pids(in list: [ProcessEntry], profileDir: URL) -> [Int32] {
        let needle = "--user-data-dir \(profileDir.path)"
        return list.filter {
            $0.command.contains(needle) &&
            // Only count the main process, not renderer/gpu helpers.
            !$0.command.contains("--type=")
        }.map(\.pid)
    }

    /// PIDs of the main Cursor process running the *built-in* profile —
    /// a Cursor main process with no --user-data-dir at all.
    static func systemProfilePIDs(in list: [ProcessEntry]) -> [Int32] {
        list.filter {
            $0.command.contains(".app/Contents/MacOS/Cursor") &&
            !$0.command.contains("--type=") &&
            !$0.command.contains("--user-data-dir") &&
            !$0.command.contains("Cursor Helper")
        }.map(\.pid)
    }

    /// Politely ask a running profile's processes to quit (SIGTERM).
    static func quit(pids: [Int32]) {
        for pid in pids { kill(pid, SIGTERM) }
    }
}

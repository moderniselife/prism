import AppKit
import Foundation

// MARK: - One-click Brainium and Node.js setup
//
// Brainium: `git clone` into ~/brainium when the Command Line Tools are
// installed (so it can be updated with git later), otherwise the GitHub
// tarball. Node.js: Homebrew when it's there, otherwise the official
// macOS installer from nodejs.org (latest LTS), opened for the user.

enum BrainiumSetup {
    static let repoURL = "https://github.com/moderniselife/brainium.git"
    static let tarballURL = URL(string: "https://codeload.github.com/moderniselife/brainium/tar.gz/refs/heads/main")!
    static let nodeIndexURL = URL(string: "https://nodejs.org/dist/index.json")!
    static var defaultDir: String { NSHomeDirectory() + "/brainium" }

    enum SetupError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let message): return message
            }
        }
    }

    static func tilde(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// Brainium checkout folder for a detected CLI path (…/bin/brainium.mjs).
    static func checkoutDir(forCLI cli: String) -> String {
        let bin = (cli as NSString).deletingLastPathComponent
        return (bin as NSString).lastPathComponent == "bin" ? (bin as NSString).deletingLastPathComponent : bin
    }

    /// Run a tool and return its output; throws with the tail of its output.
    /// stdout and stderr share one pipe so a chatty tool can't deadlock us.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            let tail = output.split(separator: "\n").suffix(3).joined(separator: " ")
            throw SetupError.failed(tail.isEmpty ? "\((executable as NSString).lastPathComponent) exited with \(process.terminationStatus)" : tail)
        }
        return output
    }

    /// git without the "install developer tools?" prompt the /usr/bin/git
    /// shim shows when the Command Line Tools are missing.
    static let hasGit: Bool = (try? run("/usr/bin/xcode-select", ["-p"])) != nil

    // MARK: Brainium

    static func installBrainium(into dir: String = defaultDir) async throws -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir + "/bin/brainium.mjs") {
            return "Brainium is already at \(tilde(dir))."
        }
        if let items = try? fm.contentsOfDirectory(atPath: dir), !items.isEmpty {
            throw SetupError.failed("\(tilde(dir)) already exists and isn't Brainium. Move it aside, or use “Use existing…”.")
        }

        if hasGit {
            if fm.fileExists(atPath: dir) { try fm.removeItem(atPath: dir) } // empty folder
            try run("/usr/bin/git", ["clone", "--depth", "1", repoURL, dir])
        } else {
            let (file, response) = try await URLSession.shared.download(from: tarballURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw SetupError.failed("Couldn't download Brainium from GitHub.")
            }
            let staging = fm.temporaryDirectory.appendingPathComponent("brainium-\(UUID().uuidString)")
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            try run("/usr/bin/tar", ["-xzf", file.path, "-C", staging.path])
            guard let extracted = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
                    .first(where: { $0.hasDirectoryPath }) else {
                throw SetupError.failed("The Brainium download was empty.")
            }
            if fm.fileExists(atPath: dir) { try fm.removeItem(atPath: dir) } // empty folder
            try fm.moveItem(at: extracted, to: URL(fileURLWithPath: dir))
        }

        guard fm.fileExists(atPath: dir + "/bin/brainium.mjs") else {
            throw SetupError.failed("Downloaded Brainium, but \(tilde(dir))/bin/brainium.mjs is missing.")
        }
        return "Installed Brainium at \(tilde(dir))."
    }

    /// `git pull` for a git checkout; nil when it isn't one.
    static func updateBrainium(at dir: String) throws -> String {
        guard FileManager.default.fileExists(atPath: dir + "/.git"), hasGit else {
            throw SetupError.failed("\(tilde(dir)) isn't a git checkout, so it can't be updated in place.")
        }
        let out = try run("/usr/bin/git", ["-C", dir, "pull", "--ff-only"])
        return out.contains("Already up to date") ? "Brainium is up to date." : "Updated Brainium."
    }

    // MARK: Node.js

    static var homebrew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func installNode() async throws -> String {
        if let brew = homebrew {
            let dir = (brew as NSString).deletingLastPathComponent
            try run(brew, ["install", "node"], environment: [
                "HOMEBREW_NO_AUTO_UPDATE": "1",
                "HOMEBREW_NO_INSTALL_CLEANUP": "1",
                "NONINTERACTIVE": "1",
                "PATH": "\(dir):/usr/bin:/bin:/usr/sbin:/sbin",
            ])
            return "Installed Node.js with Homebrew."
        }

        // Latest LTS from the official release index.
        let (data, _) = try await URLSession.shared.data(from: nodeIndexURL)
        guard let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let lts = releases.first(where: { $0["lts"] is String }),
              let version = lts["version"] as? String,
              let pkgURL = URL(string: "https://nodejs.org/dist/\(version)/node-\(version).pkg") else {
            throw SetupError.failed("Couldn't find the latest Node.js release.")
        }
        let (file, response) = try await URLSession.shared.download(from: pkgURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SetupError.failed("Couldn't download the Node.js \(version) installer.")
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let target = downloads.appendingPathComponent("node-\(version).pkg")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: file, to: target)
        await MainActor.run { _ = NSWorkspace.shared.open(target) }
        return "Opened the Node.js \(version) installer. Finish it, then click Check Again."
    }
}

// MARK: - Store actions

extension ProfileStore {
    func installBrainium() {
        runSetup(.brainium, label: "Couldn't install Brainium") {
            try await BrainiumSetup.installBrainium()
        }
    }

    func updateBrainium(at dir: String) {
        runSetup(.brainium, label: "Couldn't update Brainium") {
            try BrainiumSetup.updateBrainium(at: dir)
        }
    }

    func installNode() {
        runSetup(.node, label: "Couldn't install Node.js") {
            try await BrainiumSetup.installNode()
        }
    }

    /// Runs off the main actor; reports a one-line message and rechecks.
    private func runSetup(_ step: BrainSetupStep, label: String,
                          _ work: @escaping @Sendable () async throws -> String) {
        brainSetupStep = step
        brainMessage = nil
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> (ok: Bool, text: String) in
                do { return (ok: true, text: try await work()) } catch { return (ok: false, text: error.localizedDescription) }
            }.value
            guard let self else { return }
            self.brainSetupStep = nil
            self.brainMessage = outcome.ok ? outcome.text : "\(label): \(outcome.text)"
            self.refreshBrainStatus()
        }
    }
}

enum BrainSetupStep: Equatable {
    case brainium, node
}

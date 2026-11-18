import AppKit
import Foundation
import SwiftUI

// MARK: - Brainium updates
//
// Prism notices when Brainium has moved on and offers to update it, the same
// way it offers its own updates: a banner in the hub (Update / What's new /
// Skip) and the version in Settings → Second brain.
//
//   git checkout (what Prism installs)  `git fetch`, then compare with the
//                                        upstream branch; update = pull --ff-only
//   downloaded copy (no git)             GitHub's latest commit on main vs the one
//                                        recorded at install; update = download again
//
// A checkout with local changes or its own commits is left alone (no banner):
// that's someone working on Brainium, and git is the right tool there.
// After an update, profiles that were already wired are wired again so they
// pick up new instructions and tools.

enum BrainiumUpdateCheck {
    static let apiLatestCommit = URL(string: "https://api.github.com/repos/moderniselife/brainium/commits/main")!
    static let rawPackageJSON = URL(string: "https://raw.githubusercontent.com/moderniselife/brainium/main/package.json")!
    static let installRecord = ".brainium-install.json"

    /// What the check found.
    struct Result: Sendable, Equatable {
        var currentVersion: String
        var latestVersion: String
        /// Commits behind (git) — nil when unknown (downloaded copy).
        var behind: Int?
        /// Short summaries of what changed, newest first.
        var changes: [String]
        /// What "Skip" remembers: the upstream commit.
        var latestID: String
        var compareURL: URL
        /// Something newer exists and the copy can be updated in place.
        var available: Bool
        /// Why it can't be updated in place (local changes, ahead of upstream…).
        var blockedReason: String?
    }

    struct InstallRecord: Codable {
        var sha: String
        var version: String?
        var installedAt: Date?
    }

    static func version(at dir: String) -> String {
        guard let data = FileManager.default.contents(atPath: dir + "/package.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = json["version"] as? String else { return "?" }
        return v
    }

    private static func versionFrom(json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["version"] as? String
    }

    private static func git(_ dir: String, _ args: [String]) throws -> String {
        try BrainiumSetup.run("/usr/bin/git", ["-C", dir] + args, environment: ["GIT_TERMINAL_PROMPT": "0"])
    }

    /// Check one Brainium folder. Throws when it can't tell (offline…).
    static func check(dir: String) async throws -> Result {
        let current = version(at: dir)
        if FileManager.default.fileExists(atPath: dir + "/.git"), BrainiumSetup.hasGit {
            return try checkGit(dir: dir, current: current)
        }
        return try await checkDownload(dir: dir, current: current)
    }

    private static func checkGit(dir: String, current: String) throws -> Result {
        // The branch this copy follows; a checkout without one follows origin's default.
        let upstream = (try? git(dir, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])) ?? "origin/HEAD"
        let remote = upstream.split(separator: "/").first.map(String.init) ?? "origin"
        _ = try git(dir, ["fetch", "--quiet", remote])
        let head = try git(dir, ["rev-parse", "HEAD"])
        let target = try git(dir, ["rev-parse", upstream])
        let behind = Int(try git(dir, ["rev-list", "--count", "HEAD..\(upstream)"])) ?? 0
        let ahead = Int(try git(dir, ["rev-list", "--count", "\(upstream)..HEAD"])) ?? 0
        let dirty = !(try git(dir, ["status", "--porcelain", "--untracked-files=no"])).isEmpty
        let latest = (try? git(dir, ["show", "\(upstream):package.json"])).flatMap(versionFrom(json:)) ?? current
        let changes = behind > 0
            ? (try? git(dir, ["log", "--no-merges", "--format=%s", "-n", "8", "HEAD..\(upstream)"]))?
                .split(separator: "\n").map(String.init) ?? []
            : []
        var blocked: String?
        if behind > 0 && (dirty || ahead > 0) {
            blocked = dirty
                ? "Your Brainium folder has local changes, so Prism won't update it. Commit or stash them, then pull."
                : "Your Brainium folder has commits of its own, so Prism won't update it. Pull or rebase it yourself."
        }
        return Result(currentVersion: current, latestVersion: latest, behind: behind, changes: changes,
                      latestID: target,
                      compareURL: URL(string: "https://github.com/moderniselife/brainium/compare/\(head.prefix(12))...\(target.prefix(12))")!,
                      available: behind > 0 && blocked == nil, blockedReason: blocked)
    }

    private static func checkDownload(dir: String, current: String) async throws -> Result {
        var request = URLRequest(url: apiLatestCommit, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = obj["sha"] as? String else {
            throw BrainiumSetup.SetupError.failed("Couldn't reach GitHub to check for a newer Brainium.")
        }
        let (pkg, _) = try await URLSession.shared.data(from: rawPackageJSON)
        let latest = versionFrom(json: String(decoding: pkg, as: UTF8.self)) ?? current
        let recorded = FileManager.default.contents(atPath: dir + "/" + installRecord)
            .flatMap { try? JSONDecoder().decode(InstallRecord.self, from: $0) }
        // With no record (installed before Prism kept one) only a newer version counts.
        let newer = recorded.map { $0.sha != sha }
            ?? BrainiumBridge.versionKey(current).lexicographicallyPrecedes(BrainiumBridge.versionKey(latest))
        let compare = recorded.map { "https://github.com/moderniselife/brainium/compare/\($0.sha.prefix(12))...\(sha.prefix(12))" }
            ?? "https://github.com/moderniselife/brainium/commits/main"
        return Result(currentVersion: current, latestVersion: latest, behind: nil, changes: [],
                      latestID: sha, compareURL: URL(string: compare)!, available: newer, blockedReason: nil)
    }
}

@MainActor
final class BrainiumUpdater: ObservableObject {
    static let shared = BrainiumUpdater()

    @Published private(set) var result: BrainiumUpdateCheck.Result?
    @Published private(set) var checking = false
    @Published private(set) var updating = false
    @Published var lastError: String?
    @Published private(set) var lastChecked: Date?

    @AppStorage("brainiumSkippedUpdate") private var skippedID: String = ""
    @AppStorage("brainiumLastUpdateCheck") private var lastCheckStamp: Double = 0

    private var timer: Task<Void, Never>?
    nonisolated static let interval: TimeInterval = 6 * 3600

    /// An update the hub should offer (not skipped, can be applied).
    var offer: BrainiumUpdateCheck.Result? {
        guard let r = result, r.available, r.latestID != skippedID else { return nil }
        return r
    }

    /// Check a little after launch, then every few hours.
    func start(store: ProfileStore) {
        timer?.cancel()
        timer = Task { [weak self, weak store] in
            try? await Task.sleep(for: .seconds(15))
            while !Task.isCancelled {
                if let self, let store { await self.checkIfDue(store: store) }
                try? await Task.sleep(for: .seconds(1800))
            }
        }
    }

    func checkIfDue(store: ProfileStore, maxAge: TimeInterval = BrainiumUpdater.interval) async {
        if Date().timeIntervalSince1970 - lastCheckStamp < maxAge, result != nil { return }
        await check(store: store)
    }

    func check(store: ProfileStore) async {
        guard !checking, !updating, let cli = BrainiumBridge.findCLI(custom: store.brainiumPath) else { return }
        let dir = BrainiumSetup.checkoutDir(forCLI: cli)
        checking = true
        defer { checking = false }
        do {
            result = try await Task.detached(priority: .utility) { try await BrainiumUpdateCheck.check(dir: dir) }.value
            lastError = nil
            lastCheckStamp = Date().timeIntervalSince1970
            lastChecked = Date()
        } catch {
            // Offline or rate-limited: say so only when asked (Settings shows it).
            lastError = error.localizedDescription
        }
    }

    func skip() {
        if let r = result { skippedID = r.latestID }
    }

    /// Update, then re-wire the profiles that were wired so they get the new instructions.
    func update(store: ProfileStore) async {
        guard !updating, let cli = BrainiumBridge.findCLI(custom: store.brainiumPath) else { return }
        let dir = BrainiumSetup.checkoutDir(forCLI: cli)
        let before = BrainiumUpdateCheck.version(at: dir)
        updating = true
        store.brainMessage = "Updating Brainium…"
        defer { updating = false }
        do {
            _ = try await Task.detached(priority: .userInitiated) { try await BrainiumSetup.updateBrainium(at: dir) }.value
        } catch {
            store.brainMessage = "Couldn't update Brainium: \(error.localizedDescription)"
            lastError = error.localizedDescription
            return
        }
        let after = BrainiumUpdateCheck.version(at: dir)
        result = nil
        skippedID = ""
        let rewired = await store.rewireConnectedProfiles()
        var message = before == after ? "Updated Brainium (\(after))." : "Updated Brainium \(before) → \(after)."
        if rewired > 0 { message += " Refreshed \(rewired) connected profile\(rewired == 1 ? "" : "s")." }
        store.brainMessage = message
        store.refreshBrainStatus()
        await check(store: store)
    }
}

// MARK: - Re-wiring after an update

extension ProfileStore {
    /// Whether Brainium is already wired into this profile (its MCP server is in the app's config).
    nonisolated static func isBrainWired(app: String, dir: String, isSystem: Bool) -> Bool {
        let file: String
        switch app {
        case CursorProfile.appClaudeCode:
            file = isSystem && ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] == nil
                ? NSHomeDirectory() + "/.claude.json" : dir + "/.claude.json"
        case CursorProfile.appClaudeDesktop:
            file = dir + "/claude_desktop_config.json"
        case CursorProfile.appCursor:
            file = NSHomeDirectory() + "/.cursor/mcp.json"
        default:
            return false
        }
        guard let data = FileManager.default.contents(atPath: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any] else { return false }
        return servers["brainium"] != nil
    }

    /// Wire again every profile that's already wired; returns how many.
    func rewireConnectedProfiles() async -> Int {
        guard let bridge = brainium else { return 0 }
        let all = profiles.map { (app: $0.normalizedApp, dir: directory(for: $0).path, isSystem: $0.isSystem, brain: effectiveBrain(for: $0)) }
        return await Task.detached(priority: .utility) { () -> Int in
            var seenCursor = false
            let wired = all.filter { p in
                // Cursor shares one mcp.json: wire it once.
                if p.app == CursorProfile.appCursor {
                    if seenCursor { return false }
                    seenCursor = true
                }
                return ProfileStore.isBrainWired(app: p.app, dir: p.dir, isSystem: p.isSystem)
            }
            guard !wired.isEmpty else { return 0 }
            _ = try? bridge.wireAll(wired, enable: true)
            return wired.count
        }.value
    }
}

// MARK: - Hub banner

struct BrainiumUpdateBanner: View {
    @EnvironmentObject var store: ProfileStore
    @ObservedObject private var updater = BrainiumUpdater.shared
    var compact = false

    var body: some View {
        if updater.updating {
            HubBanner(icon: "brain", text: "Updating Brainium…", compact: compact) {
                ProgressView().controlSize(.small)
            }
        } else if let offer = updater.offer {
            HubBanner(icon: "brain", text: text(offer), compact: compact) {
                HStack(spacing: 6) {
                    if !compact {
                        Button("What's new") { NSWorkspace.shared.open(offer.compareURL) }
                            .buttonStyle(PrismButtonStyle(kind: .plain, height: 26))
                            .help(offer.changes.prefix(6).joined(separator: "\n"))
                        Button("Skip") { updater.skip() }
                            .buttonStyle(PrismButtonStyle(kind: .plain, height: 26))
                    }
                    Button("Update") { Task { await updater.update(store: store) } }
                        .buttonStyle(PrismButtonStyle(kind: .tinted, height: compact ? 22 : 26))
                }
            }
        }
    }

    private func text(_ r: BrainiumUpdateCheck.Result) -> String {
        let versions = r.latestVersion != r.currentVersion && r.currentVersion != "?"
            ? "Brainium \(r.latestVersion) is available — you have \(r.currentVersion)"
            : "A Brainium update is available"
        guard let n = r.behind, n > 0 else { return versions + "." }
        return versions + " (\(n) change\(n == 1 ? "" : "s"))."
    }
}

// MARK: - Settings row

/// "Up to date (0.3.0)" / "0.4.0 available — Update" / "Check for updates", for Settings → Second brain.
struct BrainiumVersionRow: View {
    @EnvironmentObject var store: ProfileStore
    @ObservedObject private var updater = BrainiumUpdater.shared

    var body: some View {
        HStack(spacing: 8) {
            if updater.updating || updater.checking {
                ProgressView().controlSize(.small)
            }
            Text(status)
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Spacer(minLength: 8)
            if let r = updater.result, r.available {
                Button("What's new") { NSWorkspace.shared.open(r.compareURL) }
                Button(r.currentVersion == r.latestVersion || r.currentVersion == "?" ? "Update" : "Update to \(r.latestVersion)") { Task { await updater.update(store: store) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(updater.updating)
            } else {
                Button("Check for Updates") { Task { await updater.check(store: store) } }
                    .disabled(updater.checking || updater.updating)
            }
        }
        .task { await updater.checkIfDue(store: store, maxAge: 3600) }
    }

    private var status: String {
        if updater.updating { return "Updating…" }
        if updater.checking { return "Checking for updates…" }
        if let r = updater.result {
            if let blocked = r.blockedReason { return r.currentVersion == "?" ? blocked : "\(r.currentVersion) — \(blocked)" }
            if r.available {
                let n = r.behind.map { " · \($0) change\($0 == 1 ? "" : "s")" } ?? ""
                return r.currentVersion == "?" || r.currentVersion == r.latestVersion
                    ? "Update available\(n)"
                    : "\(r.currentVersion) → \(r.latestVersion)\(n)"
            }
            return "\(r.currentVersion) — up to date"
        }
        if let error = updater.lastError { return error }
        return store.brainStatus?.version ?? "—"
    }

    private var statusColor: Color {
        if updater.result?.available == true { return PrismTheme.Colors.accentText }
        if updater.result?.blockedReason != nil || (updater.result == nil && updater.lastError != nil) { return PrismTheme.Colors.amber }
        return PrismTheme.Colors.textSecondary
    }
}

import AppKit
import SwiftUI

// MARK: - Prism itself: which build is running, and keeping it current
//
// A long-running Prism used to hide every rebuild: copying a new Prism.app
// over the running one, or opening another copy, only brought the old
// process forward. Now:
//   • the copy you open takes over from any older one that's running,
//   • a running Prism notices its app was replaced on disk and offers to
//     relaunch,
//   • and it can update itself from GitHub releases.

enum BuildInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Short git commit stamped by build.sh ("dev" for unstamped builds).
    static var commit: String {
        Bundle.main.infoDictionary?["PrismCommit"] as? String ?? "dev"
    }

    static var buildDate: String {
        Bundle.main.infoDictionary?["PrismBuildDate"] as? String ?? ""
    }

    /// "1.6.0 (abc1234, 2026-11-16)"
    static var description: String {
        let day = buildDate.prefix(10)
        return day.isEmpty ? "\(version) (\(commit))" : "\(version) (\(commit), \(day))"
    }

    static var executableURL: URL? {
        Bundle.main.executableURL?.resolvingSymlinksInPath()
    }

    static func modificationDate(_ url: URL?) -> Date? {
        guard let url else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

// MARK: - One Prism at a time

enum InstanceGuard {
    /// Call before the UI starts. Quits older copies of Prism, or hands
    /// over to an identical one that's already running.
    static func resolve() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me.processIdentifier && !$0.isTerminated }
        guard !others.isEmpty else { return }

        let myBundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let myBinaryDate = BuildInfo.modificationDate(BuildInfo.executableURL) ?? .distantPast

        for other in others {
            let sameCopy = other.bundleURL?.resolvingSymlinksInPath() == myBundle
            // Same app, and its files haven't changed since it started: this
            // is just a second launch. Show the running one instead.
            if sameCopy, let launched = other.launchDate, launched > myBinaryDate {
                other.activate()
                exit(0)
            }
        }
        // Another copy, or this copy's files were replaced after the old
        // process started: the one being opened wins.
        for other in others {
            NSLog("Prism: replacing older instance pid \(other.processIdentifier) at \(other.bundleURL?.path ?? "?")")
            other.terminate()
        }
        let deadline = Date().addingTimeInterval(4)
        while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        for other in others where !other.isTerminated {
            other.forceTerminate()
        }
    }

    /// Start a fresh copy of the app at `bundleURL` once this process exits,
    /// then quit.
    static func relaunch(_ bundleURL: URL = Bundle.main.bundleURL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = bundleURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open -n '\(path)'"]
        try? p.run()
        NSApp.terminate(nil)
    }
}

// MARK: - Updates (a newer build on disk, or a new release)

@MainActor
final class PrismSelfUpdater: ObservableObject {
    static let shared = PrismSelfUpdater()

    struct Release: Equatable {
        let version: String
        let pageURL: URL
        let zipURL: URL?
    }

    /// The app on disk is a different build from this process.
    @Published private(set) var replacedOnDisk = false
    @Published private(set) var available: Release?
    @Published private(set) var progress: String?
    @Published var lastError: String?

    @AppStorage("checkForPrismUpdates") var autoCheck = true
    @AppStorage("skippedPrismVersion") private var skippedVersion = ""

    private let launchedBinaryDate = BuildInfo.modificationDate(BuildInfo.executableURL)
    private let launchedBuildDate = BuildInfo.buildDate
    private var timer: Timer?
    private var lastCheck: Date?

    static let repo = "moderniselife/prism"

    private init() {}

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in PrismSelfUpdater.shared.tick() }
        }
        tick()
    }

    private func tick() {
        checkDisk()
        if autoCheck, lastCheck.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true {
            Task { await checkForRelease() }
        }
    }

    // MARK: On disk

    private func checkDisk() {
        guard !replacedOnDisk else { return }
        let info = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        let diskBuild = (NSDictionary(contentsOf: info)?["PrismBuildDate"] as? String) ?? ""
        let binaryDate = BuildInfo.modificationDate(BuildInfo.executableURL)
        if (!diskBuild.isEmpty && diskBuild != launchedBuildDate)
            || (binaryDate != nil && launchedBinaryDate != nil && binaryDate != launchedBinaryDate) {
            replacedOnDisk = true
            NSLog("Prism: a different build is now installed at \(Bundle.main.bundlePath); offering to relaunch")
        }
    }

    func relaunch() {
        InstanceGuard.relaunch()
    }

    // MARK: Releases

    func checkForRelease(force: Bool = false) async {
        lastCheck = Date()
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Prism/\(BuildInfo.version)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String,
              let page = (j["html_url"] as? String).flatMap(URL.init(string:)) else {
            if force { lastError = "Couldn't reach GitHub to check for updates." }
            return
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let zip = (j["assets"] as? [[String: Any]] ?? [])
            .first { ($0["name"] as? String) == "Prism.app.zip" }
            .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        if Self.isNewer(version, than: BuildInfo.version), force || version != skippedVersion {
            available = Release(version: version, pageURL: page, zipURL: zip)
        } else {
            available = nil
            if force { lastError = "Prism \(BuildInfo.version) is the latest version." }
        }
    }

    func skip() {
        if let v = available?.version { skippedVersion = v }
        available = nil
    }

    /// "1.10.0" > "1.9.2"; a non-numeric current version ("dev") is never
    /// offered an update.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? -1 }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        guard !pb.isEmpty, pb.count == b.split(separator: ".").count else { return false }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Download the release, swap it in place of this app and relaunch.
    func install() async {
        guard let release = available else { return }
        guard let zip = release.zipURL else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            lastError = "Prism can't write to \(parent.path). Download it from GitHub instead."
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        progress = "Downloading Prism \(release.version)…"
        defer { progress = nil }
        do {
            let (file, resp) = try await URLSession.shared.download(from: zip)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Download failed.") }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("prism-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            progress = "Installing Prism \(release.version)…"
            try run("/usr/bin/ditto", ["-x", "-k", file.path, work.path])
            let fresh = work.appendingPathComponent("Prism.app")
            guard Bundle(url: fresh)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw UpdateError("The download isn't a Prism app.")
            }
            var trashed: NSURL?
            try FileManager.default.trashItem(at: target, resultingItemURL: &trashed)
            do {
                try FileManager.default.moveItem(at: fresh, to: target)
            } catch {
                // Put the old app back rather than leave nothing behind.
                if let trashed = trashed as URL? { try? FileManager.default.moveItem(at: trashed, to: target) }
                throw error
            }
            try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", target.path])
            InstanceGuard.relaunch(target)
        } catch {
            lastError = "Update failed: \(error.localizedDescription)"
        }
    }

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("\(tool) failed (\(p.terminationStatus)).") }
    }
}

/// Hub and menu-bar banner for a replaced build or a new release.
@MainActor
struct PrismSelfBanner: View {
    @ObservedObject private var updater = PrismSelfUpdater.shared
    var compact = false

    var body: some View {
        if let progress = updater.progress {
            HubBanner(icon: "arrow.down.circle", text: progress, compact: compact) {
                ProgressView().controlSize(.small)
            }
        } else if updater.replacedOnDisk {
            HubBanner(icon: "arrow.clockwise.circle", text: "A new build of Prism was installed. This window is still the old one.",
                      compact: compact) {
                Button("Relaunch") { updater.relaunch() }
                    .buttonStyle(PrismButtonStyle(kind: .tinted, height: compact ? 22 : 26))
            }
        } else if let release = updater.available {
            HubBanner(icon: "sparkles", text: "Prism \(release.version) is available — you have \(BuildInfo.version).",
                      compact: compact) {
                HStack(spacing: 6) {
                    if !compact {
                        Button("What's new") { NSWorkspace.shared.open(release.pageURL) }
                            .buttonStyle(PrismButtonStyle(kind: .plain, height: 26))
                        Button("Skip") { updater.skip() }
                            .buttonStyle(PrismButtonStyle(kind: .plain, height: 26))
                    }
                    Button("Update") { Task { await updater.install() } }
                        .buttonStyle(PrismButtonStyle(kind: .tinted, height: compact ? 22 : 26))
                }
            }
        } else if let error = updater.lastError, !compact {
            HubBanner(icon: "info.circle", text: error, compact: compact) {
                Button("OK") { updater.lastError = nil }
                    .buttonStyle(PrismButtonStyle(kind: .plain, height: 26))
            }
        }
    }
}

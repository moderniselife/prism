import AppKit
import Combine
import SwiftUI

// MARK: - Store

@MainActor
final class ProfileStore: ObservableObject {

    @Published var profiles: [CursorProfile] = []
    @Published var sizes: [String: Int64] = [:]
    @Published var runningPIDs: [String: [Int32]] = [:]
    /// Live resident memory per profile (bytes, summed RSS of its processes).
    @Published var liveMemory: [String: UInt64] = [:]
    /// Live CPU % per profile (summed %cpu of its processes).
    @Published var liveCPU: [String: Double] = [:]
    /// Real on-screen window counts per profile.
    @Published var windowCounts: [String: Int] = [:]
    /// Real system-wide CPU %, nil until the second sample.
    @Published var systemCPU: Double?
    @Published var duplicating: Set<String> = []
    @Published var lastError: String?

    private let cpuMonitor = SystemCPUMonitor()

    /// Real total RAM of this Mac.
    var physicalMemory: UInt64 { SystemStats.physicalMemory }

    /// Real summed RSS of every running profile.
    var liveMemoryTotal: UInt64 { liveMemory.values.reduce(0, +) }

    @AppStorage("customCursorPath") var customCursorPath: String = ""
    @AppStorage("customCodePath") var customCodePath: String = ""
    @AppStorage("customDesktopPath") var customDesktopPath: String = ""
    @AppStorage("defaultMemoryMB") var defaultMemoryMB: Int = 16384

    let profilesDir: URL
    let codeProfilesDir: URL
    let desktopProfilesDir: URL
    private let metadataName = ".profiles.json"
    private var pollTask: Task<Void, Never>?

    var resolvedCursorPath: String? {
        CursorLauncher.findCursor(customPath: customCursorPath.isEmpty ? nil : customCursorPath)
    }

    var resolvedCodePath: String? {
        ClaudeLauncher.findClaudeCode(customPath: customCodePath.isEmpty ? nil : customCodePath)
    }

    var resolvedDesktopPath: String? {
        ClaudeLauncher.findClaudeDesktop(customPath: customDesktopPath.isEmpty ? nil : customDesktopPath)
    }

    init(profilesDir: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cursor_profiles"),
         codeProfilesDir: URL? = nil,
         desktopProfilesDir: URL? = nil) {
        self.profilesDir = profilesDir
        let home = URL(fileURLWithPath: NSHomeDirectory())
        self.codeProfilesDir = codeProfilesDir ?? home.appendingPathComponent(".claude_code_profiles")
        self.desktopProfilesDir = desktopProfilesDir ?? home.appendingPathComponent(".claude_desktop_profiles")
        reload()
        startPolling()
    }

    func dirForApp(_ app: String) -> URL {
        switch CursorProfile.normalizeApp(app) {
        case CursorProfile.appClaudeCode: return codeProfilesDir
        case CursorProfile.appClaudeDesktop: return desktopProfilesDir
        default: return profilesDir
        }
    }

    /// The built-in Cursor data directory — where Cursor keeps everything when
    /// launched normally. This is the profile people already have.
    static var systemDataDir: URL {
        systemDataDir(for: CursorProfile.appCursor)
    }

    /// Real (built-in) data location per app.
    static func systemDataDir(for app: String) -> URL {
        switch CursorProfile.normalizeApp(app) {
        case CursorProfile.appClaudeCode:
            if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
        case CursorProfile.appClaudeDesktop:
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Claude")
        default:
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Cursor")
        }
    }

    func directory(for profile: CursorProfile) -> URL {
        let app = profile.normalizedApp
        return profile.isSystem ? Self.systemDataDir(for: app) : dirForApp(app).appendingPathComponent(profile.folderName)
    }

    func isRunning(_ profile: CursorProfile) -> Bool {
        !(runningPIDs[profile.folderName] ?? []).isEmpty
    }

    // MARK: Loading & persistence

    func reload() {
        var all: [CursorProfile] = []
        for app in [CursorProfile.appCursor, CursorProfile.appClaudeCode, CursorProfile.appClaudeDesktop] {
            all.append(contentsOf: reloadApp(app))
        }
        profiles = all
        saveMetadata()
        refreshSizes()
        refreshRunning()
    }

    private func reloadApp(_ app: String) -> [CursorProfile] {
        let dir = dirForApp(app)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var known = loadMetadata(dir: dir)

        // Foreign built-ins (from a copied metadata file) belong to their own
        // app; hand-created folders are adopted into this app.
        known.removeAll { $0.isSystem && $0.folderName != CursorProfile.systemMarker(for: app) }
        known = known.map { p in var q = p; q.app = app; return q }

        // Adopt any directories created by hand.
        let onDisk = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        let dirNames = onDisk
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)

        for name in dirNames where !known.contains(where: { $0.folderName == name }) {
            var display = name
            if display.hasPrefix("custom_") { display.removeFirst("custom_".count) }
            known.append(CursorProfile(folderName: name, displayName: display, app: app))
        }
        // Drop metadata for folders that no longer exist (never the built-in one).
        known.removeAll { !$0.isSystem && !dirNames.contains($0.folderName) }

        // Surface the original app data so it's visible and launchable — and
        // clearly protected — rather than silently ignored.
        if !known.contains(where: { $0.isSystem }),
           FileManager.default.fileExists(atPath: Self.systemDataDir(for: app).path) {
            known.insert(CursorProfile(
                folderName: CursorProfile.systemMarker(for: app),
                displayName: CursorProfile.systemDisplayName(for: app),
                app: app,
                colorHex: "#3B82F6",
                isPinned: true,
                isSystem: true
            ), at: 0)
        }

        return known
    }

    private func loadMetadata(dir: URL) -> [CursorProfile] {
        let url = dir.appendingPathComponent(metadataName)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CursorProfile].self, from: data)) ?? []
    }

    private func saveMetadata() {
        for app in [CursorProfile.appCursor, CursorProfile.appClaudeCode, CursorProfile.appClaudeDesktop] {
            let url = dirForApp(app).appendingPathComponent(metadataName)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(profiles.filter { $0.normalizedApp == app }) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: CRUD

    @discardableResult
    func createProfile(displayName: String,
                       app: String = CursorProfile.appCursor,
                       colorHex: String,
                       memoryMB: Int,
                       defaultProjectPath: String?) -> CursorProfile? {
        let normalized = CursorProfile.normalizeApp(app)
        let base = ProfileNaming.sanitizeFolderName(displayName.replacingOccurrences(of: " ", with: "_"))
        guard !base.isEmpty else {
            lastError = "Profile name must contain at least one letter, number, hyphen or underscore."
            return nil
        }
        var folder = base
        var counter = 2
        let reserved = [CursorProfile.systemFolderName, CursorProfile.systemCodeFolderName,
                        CursorProfile.systemDesktopFolderName]
        while profiles.contains(where: { $0.folderName.caseInsensitiveCompare(folder) == .orderedSame })
            || reserved.contains(folder) {
            folder = "\(base)-\(counter)"
            counter += 1
        }

        let profile = CursorProfile(
            folderName: folder,
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            app: normalized,
            colorHex: colorHex,
            defaultMemoryMB: memoryMB,
            defaultProjectPath: defaultProjectPath
        )
        let dir = directory(for: profile)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            lastError = "Could not create profile folder: \(error.localizedDescription)"
            return nil
        }
        if normalized == CursorProfile.appClaudeDesktop {
            Self.seedDesktopConfig(systemDir: Self.systemDataDir(for: normalized), profileDir: dir)
        }
        profiles.append(profile)
        saveMetadata()
        refreshSizes()
        TitleBarColorizer.apply(profile: profile, profileDir: dir)
        return profile
    }

    /// Copy just claude_desktop_config.json (MCP/connectors) into a fresh
    /// Desktop profile — never gigabytes of Electron cache.
    static func seedDesktopConfig(systemDir: URL, profileDir: URL) {
        let src = systemDir.appendingPathComponent("claude_desktop_config.json")
        let dst = profileDir.appendingPathComponent("claude_desktop_config.json")
        guard FileManager.default.fileExists(atPath: src.path),
              !FileManager.default.fileExists(atPath: dst.path) else { return }
        try? FileManager.default.copyItem(at: src, to: dst)
    }

    func update(_ profile: CursorProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let colorChanged = profiles[idx].colorHex != profile.colorHex
        profiles[idx] = profile
        saveMetadata()
        if colorChanged {
            TitleBarColorizer.apply(profile: profile, profileDir: directory(for: profile))
        }
    }

    /// Duplicate a profile. For the built-in profile this *clones* the original
    /// app data into a new managed profile — the original is only read,
    /// never touched. Desktop duplicates are config-only (full Electron dirs
    /// are gigabytes of cache). Runs in the background since data dirs can
    /// be large.
    func duplicate(_ profile: CursorProfile) {
        let app = profile.normalizedApp
        let base = profile.isSystem
            ? CursorProfile.systemDisplayName(for: app).replacingOccurrences(of: " ", with: "-")
            : profile.folderName + "-copy"
        var folder = base
        var counter = 2
        while profiles.contains(where: { $0.folderName.caseInsensitiveCompare(folder) == .orderedSame }) {
            folder = "\(base)-\(counter)"
            counter += 1
        }
        let source = directory(for: profile)
        let dest = dirForApp(app).appendingPathComponent(folder)

        var copy = profile
        copy.folderName = folder
        copy.app = app
        copy.displayName = profile.isSystem
            ? CursorProfile.systemDisplayName(for: app) + " Clone"
            : profile.displayName + " Copy"
        copy.createdAt = Date()
        copy.lastLaunchedAt = nil
        copy.isPinned = false
        copy.isSystem = false

        duplicating.insert(profile.folderName)
        // Sendable snapshots cross the thread hop; the finish step runs in
        // this Task, which inherits MainActor isolation from duplicate().
        let folderName = profile.folderName
        let sourceURL = source
        let destURL = dest
        let finishedCopy = copy
        let desktopOnly = app == CursorProfile.appClaudeDesktop
        Task { [weak self] in
            let copyErrorMessage = await Task.detached(priority: .userInitiated) {
                if desktopOnly {
                    Self.copyDesktopConfig(source: sourceURL, dest: destURL)
                } else {
                    Self.copyProfileData(source: sourceURL, dest: destURL)
                }
            }.value
            self?.finishDuplicate(folderName: folderName, copy: finishedCopy,
                                  dest: destURL, errorMessage: copyErrorMessage)
        }
    }

    /// Config-only Desktop copy: fresh dir + MCP/connectors config.
    private static nonisolated func copyDesktopConfig(source: URL, dest: URL) -> String? {
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let src = source.appendingPathComponent("claude_desktop_config.json")
            if FileManager.default.fileExists(atPath: src.path) {
                try FileManager.default.copyItem(
                    at: src, to: dest.appendingPathComponent("claude_desktop_config.json"))
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Pure file copy: Sendable in/out, never touches the store.
    private static nonisolated func copyProfileData(source: URL, dest: URL) -> String? {
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @MainActor
    private func finishDuplicate(folderName: String, copy: CursorProfile,
                                 dest: URL, errorMessage: String?) {
        duplicating.remove(folderName)
        if let errorMessage {
            lastError = "Could not duplicate profile: \(errorMessage)"
            try? FileManager.default.removeItem(at: dest)
        } else {
            profiles.append(copy)
            saveMetadata()
            refreshSizes()
        }
    }

    /// Moves the profile folder to the Trash (recoverable, unlike the script's rm -rf).
    func delete(_ profile: CursorProfile) {
        if profile.isSystem {
            lastError = "The built-in profile can't be deleted from here — it's your original \(profile.appLabel) data."
            return
        }
        if isRunning(profile) {
            lastError = "'\(profile.displayName)' is running. Quit it before deleting."
            return
        }
        do {
            try FileManager.default.trashItem(at: directory(for: profile), resultingItemURL: nil)
        } catch {
            lastError = "Could not move profile to Trash: \(error.localizedDescription)"
            return
        }
        profiles.removeAll { $0.id == profile.id }
        sizes[profile.folderName] = nil
        saveMetadata()
    }

    func togglePin(_ profile: CursorProfile) {
        var p = profile
        p.isPinned.toggle()
        update(p)
    }

    func revealInFinder(_ profile: CursorProfile) {
        NSWorkspace.shared.activateFileViewerSelecting([directory(for: profile)])
    }

    // MARK: Launch / quit

    func launch(_ profile: CursorProfile, projectPath: String? = nil, memoryMB: Int? = nil, newWindow: Bool = false) {
        do {
            switch profile.normalizedApp {
            case CursorProfile.appClaudeCode:
                try ClaudeLauncher.launchCode(
                    profileDir: directory(for: profile),
                    displayName: profile.displayName,
                    codePath: customCodePath.isEmpty ? nil : customCodePath,
                    projectPath: projectPath ?? profile.defaultProjectPath,
                    isSystem: profile.isSystem
                )
            case CursorProfile.appClaudeDesktop:
                try ClaudeLauncher.launchDesktop(
                    userDataDir: profile.isSystem ? nil : directory(for: profile),
                    desktopPath: customDesktopPath.isEmpty ? nil : customDesktopPath,
                    options: CursorLauncher.LaunchOptions(
                        memoryMB: profile.defaultMemoryMB,
                        projectPath: nil,
                        newWindow: newWindow
                    )
                )
            default:
                let options = CursorLauncher.LaunchOptions(
                    memoryMB: memoryMB ?? profile.defaultMemoryMB,
                    projectPath: projectPath ?? profile.defaultProjectPath,
                    newWindow: newWindow
                )
                // Idempotent — also covers profiles adopted from disk that never went through createProfile.
                TitleBarColorizer.apply(profile: profile, profileDir: directory(for: profile))
                try CursorLauncher.launch(
                    userDataDir: profile.isSystem ? nil : directory(for: profile),
                    cursorPath: customCursorPath.isEmpty ? nil : customCursorPath,
                    options: options
                )
            }
            var p = profile
            p.lastLaunchedAt = Date()
            update(p)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.refreshRunning()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func quit(_ profile: CursorProfile) {
        let pids = runningPIDs[profile.folderName] ?? []
        if profile.normalizedApp == CursorProfile.appClaudeDesktop {
            ClaudeLauncher.quit(pids: pids)
        } else {
            CursorLauncher.quit(pids: pids)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.refreshRunning()
        }
    }

    func quitAll() {
        for profile in profiles where isRunning(profile) {
            let pids = runningPIDs[profile.folderName] ?? []
            if profile.normalizedApp == CursorProfile.appClaudeDesktop {
                ClaudeLauncher.quit(pids: pids)
            } else {
                CursorLauncher.quit(pids: pids)
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.refreshRunning()
        }
    }

    /// Windows actually on screen for a profile (counted, not guessed).
    func windows(for profile: CursorProfile) -> Int {
        windowCounts[profile.folderName] ?? 0
    }

    // MARK: Background refreshers

    /// Refreshes "Running" status periodically, but only while a window is
    /// actually open and key — no reason to keep scanning every process on
    /// the Mac while the app sits unattended in the background.
    private func startPolling() {
        // Structured poll loop. The Task inherits MainActor isolation from
        // this method, so touching the store needs no annotations — and
        // crucially no explicit @MainActor on the closure, which would flip
        // checking to Sendable-capture rules and forbid even weak self.
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, NSApp.isActive else { continue }
                self.refreshRunning()
            }
        }
    }

    private struct RunningSnapshot: Sendable {
        var pids: [String: [Int32]] = [:]
        var memory: [String: UInt64] = [:]
        var cpu: [String: Double] = [:]
        var windows: [String: Int] = [:]
    }

    func refreshRunning() {
        let items = profiles.map {
            (folderName: $0.folderName, dir: directory(for: $0),
             isSystem: $0.isSystem, app: $0.normalizedApp)
        }
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                Self.computeRunningSnapshot(items: items)
            }.value
            self?.applyRunningSnapshot(snapshot)
        }
    }

    /// Pure computation: Sendable in, Sendable out, never touches the store.
    private static nonisolated func computeRunningSnapshot(
        items: [(folderName: String, dir: URL, isSystem: Bool, app: String)]
    ) -> RunningSnapshot {
        let processes = CursorLauncher.processList()
        let statsByPid = Dictionary(uniqueKeysWithValues: processes.map {
            ($0.pid, (rssKB: $0.rssKB, cpu: $0.cpuPercent))
        })
        var snapshot = RunningSnapshot()
        var allPIDs: [Int32] = []
        var anyDesktopAlive = false
        for item in items where item.app == CursorProfile.appClaudeDesktop {
            // Cheap pre-scan so the lockfile fallback below knows Desktop
            // is actually on screen (avoids stale-lock false positives).
            anyDesktopAlive = true
            break
        }
        if anyDesktopAlive {
            anyDesktopAlive = !processes.filter {
                ClaudeLauncher.isMainDesktopExecutable($0.command) &&
                $0.pid != ProcessInfo.processInfo.processIdentifier
            }.isEmpty
        }
        for item in items {
            var matched: [Int32]
            switch item.app {
            case CursorProfile.appClaudeCode:
                // The CLI is a terminal session, not a trackable GUI app.
                matched = []
            case CursorProfile.appClaudeDesktop:
                if item.isSystem {
                    matched = ClaudeLauncher.systemDesktopPIDs(in: processes)
                } else {
                    matched = ClaudeLauncher.desktopPIDs(in: processes, profileDir: item.dir)
                }
                if matched.isEmpty && anyDesktopAlive
                    && ClaudeLauncher.desktopLockHeld(profileDir: item.dir) {
                    // -1 is a sentinel, never signaled (see quit).
                    matched = [-1]
                }
            default:
                matched = item.isSystem
                    ? CursorLauncher.systemProfilePIDs(in: processes)
                    : CursorLauncher.pids(in: processes, profileDir: item.dir)
            }
            snapshot.pids[item.folderName] = matched
            var rss: Int64 = 0
            var cpu = 0.0
            for pid in matched where pid > 0 {
                rss += statsByPid[pid]?.rssKB ?? 0
                cpu += statsByPid[pid]?.cpu ?? 0
            }
            snapshot.memory[item.folderName] = UInt64(max(0, rss)) * 1024
            snapshot.cpu[item.folderName] = cpu
            allPIDs.append(contentsOf: matched.filter { $0 > 0 })
        }
        let winsByPid = SystemStats.windowCounts(for: allPIDs)
        for (name, pids) in snapshot.pids {
            snapshot.windows[name] = pids.reduce(0) { $0 + (winsByPid[$1] ?? 0) }
        }
        return snapshot
    }

    @MainActor
    private func applyRunningSnapshot(_ snapshot: RunningSnapshot) {
        runningPIDs = snapshot.pids
        liveMemory = snapshot.memory
        liveCPU = snapshot.cpu
        windowCounts = snapshot.windows
        // host_statistics is microseconds-cheap; sample on main to
        // respect @MainActor isolation.
        if let sysCPU = cpuMonitor.usage() { systemCPU = sysCPU }
    }

    func refreshSizes() {
        let items = profiles.map { ($0.folderName, directory(for: $0)) }
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                var sizes: [String: Int64] = [:]
                for (name, dir) in items { sizes[name] = Self.directorySize(dir) }
                return sizes
            }.value
            if let self {
                for (name, size) in result { self.sizes[name] = size }
            }
        }
    }

    nonisolated private static func directorySize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys),
            options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

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
    @AppStorage("defaultMemoryMB") var defaultMemoryMB: Int = 16384

    let profilesDir: URL
    private let metadataName = ".profiles.json"
    private var pollTask: Task<Void, Never>?

    var resolvedCursorPath: String? {
        CursorLauncher.findCursor(customPath: customCursorPath.isEmpty ? nil : customCursorPath)
    }

    init(profilesDir: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cursor_profiles")) {
        self.profilesDir = profilesDir
        reload()
        startPolling()
    }

    /// The built-in Cursor data directory — where Cursor keeps everything when
    /// launched normally. This is the profile people already have.
    static var systemDataDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cursor")
    }

    func directory(for profile: CursorProfile) -> URL {
        profile.isSystem ? Self.systemDataDir : profilesDir.appendingPathComponent(profile.folderName)
    }

    func isRunning(_ profile: CursorProfile) -> Bool {
        !(runningPIDs[profile.folderName] ?? []).isEmpty
    }

    // MARK: Loading & persistence

    func reload() {
        try? FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)

        var known = loadMetadata()

        // Adopt any directories created by hand.
        let onDisk = (try? FileManager.default.contentsOfDirectory(
            at: profilesDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        let dirNames = onDisk
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)

        for name in dirNames where !known.contains(where: { $0.folderName == name }) {
            var display = name
            if display.hasPrefix("custom_") { display.removeFirst("custom_".count) }
            known.append(CursorProfile(folderName: name, displayName: display))
        }
        // Drop metadata for folders that no longer exist (never the built-in one).
        known.removeAll { !$0.isSystem && !dirNames.contains($0.folderName) }

        // Surface the user's original Cursor profile so it's visible and
        // launchable — and clearly protected — rather than silently ignored.
        if !known.contains(where: { $0.isSystem }),
           FileManager.default.fileExists(atPath: Self.systemDataDir.path) {
            known.insert(CursorProfile(
                folderName: CursorProfile.systemFolderName,
                displayName: "Main Cursor",
                colorHex: "#3B82F6",
                isPinned: true,
                isSystem: true
            ), at: 0)
        }

        profiles = known
        saveMetadata()
        refreshSizes()
        refreshRunning()
    }

    private func loadMetadata() -> [CursorProfile] {
        let url = profilesDir.appendingPathComponent(metadataName)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CursorProfile].self, from: data)) ?? []
    }

    private func saveMetadata() {
        let url = profilesDir.appendingPathComponent(metadataName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(profiles) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: CRUD

    @discardableResult
    func createProfile(displayName: String,
                       colorHex: String,
                       memoryMB: Int,
                       defaultProjectPath: String?) -> CursorProfile? {
        let base = ProfileNaming.sanitizeFolderName(displayName.replacingOccurrences(of: " ", with: "_"))
        guard !base.isEmpty else {
            lastError = "Profile name must contain at least one letter, number, hyphen or underscore."
            return nil
        }
        var folder = base
        var counter = 2
        while profiles.contains(where: { $0.folderName.caseInsensitiveCompare(folder) == .orderedSame })
            || folder == CursorProfile.systemFolderName {
            folder = "\(base)-\(counter)"
            counter += 1
        }

        let profile = CursorProfile(
            folderName: folder,
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            colorHex: colorHex,
            defaultMemoryMB: memoryMB,
            defaultProjectPath: defaultProjectPath
        )
        do {
            try FileManager.default.createDirectory(at: directory(for: profile), withIntermediateDirectories: true)
        } catch {
            lastError = "Could not create profile folder: \(error.localizedDescription)"
            return nil
        }
        profiles.append(profile)
        saveMetadata()
        refreshSizes()
        TitleBarColorizer.apply(profile: profile, profileDir: directory(for: profile))
        return profile
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
    /// Cursor data into a new managed profile — the original is only read,
    /// never touched. Runs in the background since data dirs can be large.
    func duplicate(_ profile: CursorProfile) {
        let base = profile.isSystem
            ? "Main-Cursor-Clone"
            : profile.folderName + "-copy"
        var folder = base
        var counter = 2
        while profiles.contains(where: { $0.folderName.caseInsensitiveCompare(folder) == .orderedSame }) {
            folder = "\(base)-\(counter)"
            counter += 1
        }
        let source = directory(for: profile)
        let dest = profilesDir.appendingPathComponent(folder)

        var copy = profile
        copy.folderName = folder
        copy.displayName = profile.isSystem ? "Main Cursor Clone" : profile.displayName + " Copy"
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
        Task { [weak self] in
            let copyErrorMessage = await Task.detached(priority: .userInitiated) {
                Self.copyProfileData(source: sourceURL, dest: destURL)
            }.value
            self?.finishDuplicate(folderName: folderName, copy: finishedCopy,
                                  dest: destURL, errorMessage: copyErrorMessage)
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
            lastError = "The built-in Cursor profile can't be deleted from here — it's your original Cursor data."
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
        let options = CursorLauncher.LaunchOptions(
            memoryMB: memoryMB ?? profile.defaultMemoryMB,
            projectPath: projectPath ?? profile.defaultProjectPath,
            newWindow: newWindow
        )
        // Idempotent — also covers profiles adopted from disk that never went through createProfile.
        TitleBarColorizer.apply(profile: profile, profileDir: directory(for: profile))
        do {
            try CursorLauncher.launch(
                userDataDir: profile.isSystem ? nil : directory(for: profile),
                cursorPath: customCursorPath.isEmpty ? nil : customCursorPath,
                options: options
            )
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
        CursorLauncher.quit(pids: runningPIDs[profile.folderName] ?? [])
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.refreshRunning()
        }
    }

    func quitAll() {
        for profile in profiles where isRunning(profile) {
            CursorLauncher.quit(pids: runningPIDs[profile.folderName] ?? [])
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
        let items = profiles.map { ($0.folderName, directory(for: $0), $0.isSystem) }
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                Self.computeRunningSnapshot(items: items)
            }.value
            self?.applyRunningSnapshot(snapshot)
        }
    }

    /// Pure computation: Sendable in, Sendable out, never touches the store.
    private static nonisolated func computeRunningSnapshot(
        items: [(folderName: String, dir: URL, isSystem: Bool)]
    ) -> RunningSnapshot {
        let processes = CursorLauncher.processList()
        let statsByPid = Dictionary(uniqueKeysWithValues: processes.map {
            ($0.pid, (rssKB: $0.rssKB, cpu: $0.cpuPercent))
        })
        var snapshot = RunningSnapshot()
        var allPIDs: [Int32] = []
        for item in items {
            let matched = item.isSystem
                ? CursorLauncher.systemProfilePIDs(in: processes)
                : CursorLauncher.pids(in: processes, profileDir: item.dir)
            snapshot.pids[item.folderName] = matched
            var rss: Int64 = 0
            var cpu = 0.0
            for pid in matched {
                rss += statsByPid[pid]?.rssKB ?? 0
                cpu += statsByPid[pid]?.cpu ?? 0
            }
            snapshot.memory[item.folderName] = UInt64(max(0, rss)) * 1024
            snapshot.cpu[item.folderName] = cpu
            allPIDs.append(contentsOf: matched)
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

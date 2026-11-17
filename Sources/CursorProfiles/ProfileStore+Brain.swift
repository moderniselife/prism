import AppKit
import Foundation

// MARK: - Second brain actions
//
// Every call runs Brainium's CLI off the main thread and reports back a
// one-line message. Brainium's own config is the source of truth for the
// personal brain, capture and the summarizer.

extension ProfileStore {

    var brainium: BrainiumBridge? {
        BrainiumBridge.resolve(cliPath: brainiumPath, nodePath: brainiumNodePath)
    }

    /// Profiles as Sendable tuples for the bridge, each with the brain it uses.
    private var brainTargets: [(app: String, dir: String, isSystem: Bool, brain: String?)] {
        profiles.map(brainTarget)
    }

    private func brainTarget(_ p: CursorProfile) -> (app: String, dir: String, isSystem: Bool, brain: String?) {
        (app: p.normalizedApp, dir: directory(for: p).path, isSystem: p.isSystem, brain: effectiveBrain(for: p))
    }

    // MARK: Which brain a profile uses

    /// The profile's own choice, else its group's, else nil (Brainium's default).
    func effectiveBrain(for profile: CursorProfile) -> String? {
        if let own = profile.brain, !own.isEmpty { return own }
        if let group = group(profile.groupID), let brain = group.brain, !brain.isEmpty { return brain }
        return nil
    }

    /// Set (nil = follow its group) the brain one profile uses, and re-wire it
    /// when profiles are wired automatically.
    func setBrain(_ brain: String?, for profile: CursorProfile) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }), profiles[i].brain != brain else { return }
        profiles[i].brain = brain
        saveProfilesMetadata()
        rewireAfterBrainChange([profiles[i]])
    }

    /// Set (nil = Brainium's default) the brain a group's profiles use.
    func setBrain(_ brain: String?, forGroup groupID: String) {
        guard var g = group(groupID), g.brain != brain else { return }
        g.brain = brain
        updateGroup(g)
        rewireAfterBrainChange(profiles(in: groupID).filter { ($0.brain ?? "").isEmpty })
    }

    private func rewireAfterBrainChange(_ changed: [CursorProfile]) {
        let targets = changed.filter { BrainiumBridge.wireArguments(app: $0.normalizedApp, profileDir: "", isSystem: false, capture: false) != nil }
        guard !targets.isEmpty else { return }
        guard brainAutoWire else {
            brainMessage = "Saved. Wire the profile again (or Wire All Profiles) for its agents to use this brain."
            return
        }
        let tuples = targets.map(brainTarget)
        brainTask("Couldn't re-wire") { bridge in
            _ = try bridge.wireAll(tuples, enable: true)
            return "Re-wired \(tuples.count) profile\(tuples.count == 1 ? "" : "s") to use \(tuples.first?.brain ?? "the default brain")."
        }
    }

    /// Run `work` off the main actor; show its message (or error) when done.
    private func brainTask(_ label: String,
                           _ work: @escaping @Sendable (BrainiumBridge) throws -> String,
                           onSuccess: ((String) -> Void)? = nil) {
        guard let bridge = brainium else {
            brainMessage = BrainiumBridge.notFoundMessage
            brainStatus = nil
            return
        }
        brainBusy = true
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> (ok: Bool, text: String) in
                do { return (ok: true, text: try work(bridge)) } catch { return (ok: false, text: error.localizedDescription) }
            }.value
            guard let self else { return }
            self.brainBusy = false
            if outcome.ok {
                if let onSuccess { onSuccess(outcome.text) } else { self.brainMessage = outcome.text }
            } else {
                self.brainMessage = "\(label): \(outcome.text)"
            }
            self.refreshBrainStatus()
        }
    }

    func refreshBrainStatus() {
        guard let bridge = brainium else {
            brainStatus = nil
            brainList = []
            routineList = []
            return
        }
        Task { [weak self] in
            let status = await Task.detached(priority: .utility) { try? bridge.status() }.value
            guard let self else { return }
            self.brainStatus = status
            if let mode = status?.scheduler?.mode { self.routinesRunByPrism = mode == "prism" }
            if status?.supportsTeams == true { self.refreshTeams() }
        }
    }

    /// Brains (with agents) and routines; Brainium 0.3+.
    func refreshTeams() {
        guard let bridge = brainium else { return }
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> ([BrainiumBridge.BrainInfo], [BrainiumBridge.RoutineInfo])? in
                guard let brains = try? bridge.brains(), let routines = try? bridge.routines() else { return nil }
                return (brains, routines)
            }.value
            guard let self, let result else { return }
            if self.brainList != result.0 { self.brainList = result.0 }
            if self.routineList != result.1 { self.routineList = result.1 }
        }
    }

    /// Brain names a profile or group can use (personal first).
    var brainNames: [String] { brainList.map(\.name) }

    // MARK: Brains

    func createBrain(name: String, at url: URL, makeDefault: Bool) {
        let path = url.path
        brainTask("Couldn't create the brain") { bridge in
            var args = ["brain", "add", name, path, "--create"]
            if makeDefault { args.append("--default") }
            _ = try bridge.run(args)
            return "Brain \"\(name)\" ready at \(BrainiumSetup.tilde(path))."
        }
    }

    func addExistingBrain(name: String, at url: URL) {
        let path = url.path
        brainTask("Couldn't add the brain") { bridge in
            _ = try bridge.run(["brain", "add", name, path])
            return "Added \"\(name)\" (\(BrainiumSetup.tilde(path)))."
        }
    }

    func makeDefaultBrain(_ name: String) {
        brainTask("Couldn't change the default brain") { bridge in
            _ = try bridge.run(["brain", "default", name])
            return "\(name) is now the default brain."
        }
    }

    /// Forget a brain in Brainium (its folder stays) and clear it from profiles and groups.
    func forgetBrain(_ name: String) {
        for i in profiles.indices where profiles[i].brain == name { profiles[i].brain = nil }
        saveProfilesMetadata()
        for g in groups where g.brain == name {
            var copy = g
            copy.brain = nil
            updateGroup(copy)
        }
        brainTask("Couldn't remove the brain") { bridge in
            _ = try bridge.run(["brain", "remove", name])
            return "Forgot \"\(name)\". Its folder is untouched."
        }
    }

    /// Lines for an agent's instructions so it uses its own folder.
    func copyAgentSnippet(agent: String, brain: String, grok: Bool = false) {
        let args = ["snippet", grok ? "grok" : "agent", "--agent", agent, "--brain", brain]
        brainTask("Couldn't build the snippet", { bridge in
            try bridge.run(args)
        }, onSuccess: { [weak self] text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.brainMessage = grok
                ? "Grok Bot instructions for \(agent) copied."
                : "Instructions for \(agent) copied — paste them into the agent's instructions."
        })
    }

    // MARK: Routines

    /// Run a routine command (approve, enable…) and refresh the list.
    private func routineTask(_ label: String, _ args: [String], done: String) {
        brainTask(label, { bridge in
            _ = try bridge.run(args)
            return done
        }, onSuccess: { [weak self] text in
            self?.brainMessage = text
            self?.refreshTeams()
        })
    }

    func approveRoutine(_ r: BrainiumBridge.RoutineInfo, enable: Bool) {
        let ref = r.ref
        brainTask("Couldn't approve \(r.name)", { bridge in
            _ = try bridge.run(["routines", "approve", ref])
            if enable { _ = try bridge.run(["routines", "enable", ref]) }
            return "Approved \(r.name) on this Mac."
        }, onSuccess: { [weak self] text in
            self?.brainMessage = text
            self?.refreshTeams()
        })
    }

    func revokeRoutine(_ r: BrainiumBridge.RoutineInfo) {
        routineTask("Couldn't revoke", ["routines", "revoke", r.ref], done: "\(r.name) won't run on this Mac until you approve it again.")
    }

    func setRoutineEnabled(_ r: BrainiumBridge.RoutineInfo, _ on: Bool) {
        routineTask("Couldn't switch \(r.name) \(on ? "on" : "off")", ["routines", on ? "enable" : "disable", r.ref],
                    done: "\(r.name) \(on ? "on" : "off").")
    }

    /// Run now, in the background; the list shows it running and its result.
    func runRoutineNow(_ r: BrainiumBridge.RoutineInfo) {
        guard let bridge = brainium else { return }
        let ref = r.ref
        brainMessage = "Running \(r.name)…"
        Task { [weak self] in
            // Let the list pick up "running" while it works.
            try? await Task.sleep(for: .milliseconds(400))
            self?.refreshTeams()
        }
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> String in
                do {
                    let out = try bridge.run(["routines", "run", ref])
                    return out.split(separator: "\n").first.map(String.init) ?? "Done."
                } catch {
                    return error.localizedDescription
                }
            }.value
            self?.brainMessage = outcome
            self?.refreshTeams()
        }
    }

    /// Create a routine (off) from Brainium's template and open it to edit.
    func newRoutine(name: String, brain: String, type: String) {
        brainTask("Couldn't create the routine", { bridge in
            let out = try bridge.run(["routines", "new", name, "--brain", brain, "--type", type, "--json"])
            struct Made: Decodable { var ref: String; var file: String }
            let made = try JSONDecoder().decode(Made.self, from: Data(out.utf8))
            return made.file
        }, onSuccess: { [weak self] file in
            NSWorkspace.shared.open(URL(fileURLWithPath: file))
            self?.brainMessage = "Created \(name) (off). Edit it, then approve it here to turn it on."
            self?.refreshTeams()
        })
    }

    /// What runs routines: "os" (launchd), "prism" (while Prism is open) or "off".
    func setSchedulerMode(_ mode: String) {
        let wasOS = brainStatus?.scheduler?.installed == true
        brainTask("Couldn't change who runs routines", { bridge in
            switch mode {
            case "os":
                _ = try bridge.run(["scheduler", "install"])
            default:
                if wasOS { _ = try bridge.run(["scheduler", "uninstall"]) }
                _ = try bridge.run(["config", "set", "scheduler.mode", mode])
            }
            return mode == "os" ? "Routines now run in the background, even when Prism is closed."
                : mode == "prism" ? "Routines run while Prism is open."
                : "Routines won't run on a schedule. Run them by hand from here."
        }, onSuccess: { [weak self] text in
            self?.routinesRunByPrism = mode == "prism"
            self?.brainMessage = text
        })
    }

    /// Prism's own scheduler: when chosen, tick once a minute while Prism runs.
    /// A tick only starts due routines (each runs as its own process), so it's quick.
    func startRoutineTicker() {
        routineTickTask?.cancel()
        routineTickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, self.routinesRunByPrism, let bridge = self.brainium else { continue }
                _ = await Task.detached(priority: .utility) { try? bridge.run(["routines", "tick"]) }.value
            }
        }
    }

    func createPersonalBrain(at url: URL) {
        let path = url.path
        brainTask("Couldn't create the personal brain") { bridge in
            _ = try bridge.run(["init-personal", path])
            return "Personal brain ready at \((path as NSString).abbreviatingWithTildeInPath)."
        }
    }

    /// `brainium config set` for each pair, in order, in one task (the
    /// config file is read-modify-written, so writes must not overlap).
    /// Re-wires Claude Code profiles when capture changes so their hooks
    /// follow the switch.
    func setBrainConfig(_ pairs: [(String, String)]) {
        let changesCapture = pairs.contains { $0.0 == "capture" }
        let targets = changesCapture ? brainTargets.filter { $0.app == CursorProfile.appClaudeCode } : []
        let settings = pairs.map { [$0.0, $0.1] }
        brainTask("Couldn't save the setting") { bridge in
            for kv in settings { _ = try bridge.run(["config", "set"] + kv) }
            if !targets.isEmpty { _ = try bridge.wireAll(targets, enable: true) }
            return "Saved."
        }
    }

    func wireAllBrains(enable: Bool = true) {
        let targets = brainTargets
        brainTask(enable ? "Wiring failed" : "Unwiring failed") { bridge in
            try bridge.wireAll(targets, enable: enable)
        }
    }

    func wireBrainIfEnabled(_ profile: CursorProfile) {
        guard brainAutoWire, brainium != nil else { return }
        wireBrain(profile)
    }

    /// Wire one profile now (the inspector's "Connect this profile").
    /// Grok Bot has nothing local to wire; it uses the snippet instead.
    func wireBrain(_ profile: CursorProfile) {
        guard BrainiumBridge.wireArguments(app: profile.normalizedApp, profileDir: "", isSystem: false, capture: false) != nil
        else { return }
        let target = [brainTarget(profile)]
        let name = profile.displayName
        brainTask("Couldn't wire '\(name)'") { bridge in
            _ = try bridge.wireAll(target, enable: true)
            return "Wired '\(name)' into your second brain."
        }
    }

    /// Copy the Grok Bot instructions snippet (its agents run in the cloud and
    /// reach the personal brain through their GitHub connector).
    func copyGrokBrainSnippet(brain: String? = nil) {
        let args = ["snippet", "grok"] + (brain.map { ["--brain", $0] } ?? [])
        brainTask("Couldn't build the snippet", { bridge in
            try bridge.run(args)
        }, onSuccess: { [weak self] text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.brainMessage = "Grok Bot snippet copied — paste it into the agent's instructions."
        })
    }
}

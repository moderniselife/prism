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

    /// Profiles as Sendable tuples for the bridge.
    private var brainTargets: [(app: String, dir: String, isSystem: Bool)] {
        profiles.map { (app: $0.normalizedApp, dir: directory(for: $0).path, isSystem: $0.isSystem) }
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
            return
        }
        Task { [weak self] in
            let status = await Task.detached(priority: .utility) { try? bridge.status() }.value
            self?.brainStatus = status
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
        let target = [(app: profile.normalizedApp, dir: directory(for: profile).path, isSystem: profile.isSystem)]
        let name = profile.displayName
        brainTask("Couldn't wire '\(name)'") { bridge in
            _ = try bridge.wireAll(target, enable: true)
            return "Wired '\(name)' into your second brain."
        }
    }

    /// Copy the Grok Bot instructions snippet (its agents run in the cloud and
    /// reach the personal brain through their GitHub connector).
    func copyGrokBrainSnippet() {
        brainTask("Couldn't build the snippet", { bridge in
            try bridge.run(["snippet", "grok"])
        }, onSuccess: { [weak self] text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.brainMessage = "Grok Bot snippet copied — paste it into the agent's instructions."
        })
    }
}

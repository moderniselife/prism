import Foundation

// MARK: - Second brain (Brainium)
//
// Prism wires Brainium (github.com/moderniselife/brainium) into every
// profile so agents share one git-backed memory across apps and accounts.
// Prism stays thin: it finds node and a Brainium checkout and runs its CLI.
// Brainium's own config (personal brain, capture, summarizer) is the single
// source of truth, shared with its hooks and MCP server.
//
// Keep in sync with tui/brainium.go and linux/prism.py.

struct BrainiumBridge: Sendable {
    let node: String
    let cli: String

    struct Status: Decodable, Sendable {
        var version: String?
        var personalBrain: String?
        var personalExists: Bool?
        var personalRemote: String?
        var capture: Bool?
        var pending: Int?
        var summarizer: Summarizer?
        // Brainium 0.3+: team brains and routines.
        var defaultBrain: String?
        var brains: [String: String]?
        var scheduler: Scheduler?

        struct Scheduler: Decodable, Sendable {
            var mode: String?
            var platform: String?
            var installed: Bool?
            var loaded: Bool?
        }

        /// Brains, agents and routines need Brainium 0.3 or newer.
        var supportsTeams: Bool {
            BrainiumBridge.versionKey(version ?? "0").lexicographicallyPrecedes([0, 3]) == false
        }

        struct Summarizer: Decodable, Sendable {
            var provider: String?
            var url: String?
            var model: String?
            var apiKeyEnv: String?
            var hasKey: Bool?
        }
    }

    /// One brain from `brainium brains --json`.
    struct BrainInfo: Decodable, Identifiable, Sendable, Equatable {
        var name: String
        var path: String
        var exists: Bool
        var isDefault: Bool
        var isRepo: Bool?
        var remote: String?
        var agents: [AgentInfo]
        var routines: Int

        var id: String { name }

        enum CodingKeys: String, CodingKey {
            case name, path, exists, isDefault = "default", isRepo, remote, agents, routines
        }
    }

    struct AgentInfo: Decodable, Identifiable, Sendable, Equatable {
        var name: String
        var slug: String
        var tldr: String?
        var card: String?
        var folder: String?
        var id: String { slug }
    }

    /// One routine from `brainium routines --json`.
    struct RoutineInfo: Decodable, Identifiable, Sendable, Equatable {
        var ref: String
        var name: String
        var brain: String
        var file: String
        var type: String
        var schedule: String
        var agent: String?
        var app: String?
        var profile: String?
        var job: String?
        var enabled: Bool
        var needsApproval: Bool
        var approved: Bool
        var changedSinceApproval: Bool
        var errors: [String]
        var nextRun: String?
        var lastRun: String?
        var lastStatus: String?
        var lastExit: Int?
        var lastDurationMs: Double?
        var lastLog: String?
        var lastOutput: String?
        var running: Running?

        struct Running: Decodable, Sendable, Equatable {
            var pid: Int?
            var startedAt: String?
        }

        var id: String { ref }

        /// Prompt and shell routines run only after approval on this Mac.
        var blockedByApproval: Bool { needsApproval && !approved }
    }

    enum BridgeError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let message): return message
            }
        }
    }

    static let notFoundMessage =
        "Brainium isn't set up yet. Open Settings → Second brain and click Install."

    struct Provider: Identifiable, Sendable {
        let id: String
        let label: String
    }

    /// Summarizers Brainium supports, with the labels Prism shows.
    static let providers: [Provider] = [
        Provider(id: "agent", label: "Your AI, via MCP (no extra cost)"),
        Provider(id: "none", label: "No AI (mechanical summary)"),
        Provider(id: "anthropic", label: "Anthropic API"),
        Provider(id: "openai", label: "OpenAI API"),
        Provider(id: "bonsai", label: "Bonsai (self-hosted)"),
        Provider(id: "openai-compatible", label: "Other OpenAI-compatible API"),
    ]

    static func resolve(cliPath: String, nodePath: String) -> BrainiumBridge? {
        guard let node = findNode(custom: nodePath), let cli = findCLI(custom: cliPath) else { return nil }
        return BrainiumBridge(node: node, cli: cli)
    }

    private static func isFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// Numeric sort key for "v22.3.10".
    static func versionKey(_ v: String) -> [Int] {
        v.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").map { Int($0) ?? 0 }
    }

    /// node: custom -> PATH -> nvm (newest) -> Homebrew/system/Volta. GUI
    /// apps don't inherit the shell PATH, so the fallbacks matter.
    static func findNode(custom: String) -> String? {
        if !custom.isEmpty, isFile(custom) { return custom }
        let home = NSHomeDirectory()
        var candidates: [String] = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { "\($0)/node" }
        let nvm = home + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            for v in versions.sorted(by: { versionKey($0).lexicographicallyPrecedes(versionKey($1)) }).reversed() {
                candidates.append("\(nvm)/\(v)/bin/node")
            }
        }
        candidates += ["/opt/homebrew/bin/node", "/usr/local/bin/node", home + "/.volta/bin/node", "/usr/bin/node"]
        return candidates.first(where: isFile)
    }

    /// bin/brainium.mjs: custom (checkout or script) -> $BRAINIUM_HOME -> common clone spots.
    static func findCLI(custom: String) -> String? {
        if custom.hasSuffix(".mjs"), isFile(custom) { return custom }
        let home = NSHomeDirectory()
        var dirs: [String] = []
        if !custom.isEmpty { dirs.append(custom) }
        if let env = ProcessInfo.processInfo.environment["BRAINIUM_HOME"], !env.isEmpty { dirs.append(env) }
        dirs += ["brainium", "Projects/brainium", "src/brainium", "code/brainium", "Developer/brainium"].map { "\(home)/\($0)" }
        return dirs.map { "\($0)/bin/brainium.mjs" }.first(where: isFile)
    }

    /// Run the CLI; throws with its stderr on failure.
    func run(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [cli] + args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let waitForExit = try process.launchForBlockingWait()
        // Drain stderr on its own thread so a chatty CLI can't fill that pipe
        // while we're still reading stdout.
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        waitForExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BridgeError.failed(message.isEmpty ? "brainium exited with \(process.terminationStatus)" : message)
        }
        return String(decoding: outData, as: UTF8.self)
    }

    func status() throws -> Status {
        try JSONDecoder().decode(Status.self, from: Data(run(["status", "--json"]).utf8))
    }

    func brains() throws -> [BrainInfo] {
        try JSONDecoder().decode([BrainInfo].self, from: Data(run(["brains", "--json"]).utf8))
    }

    func routines() throws -> [RoutineInfo] {
        try JSONDecoder().decode([RoutineInfo].self, from: Data(run(["routines", "--json"]).utf8))
    }

    /// The CLI call that wires (or unwires) one profile, or nil when the app
    /// has nothing local to wire — Grok Bot agents run in the cloud and get
    /// an instructions snippet instead. Cursor's MCP config is global.
    static func wireArguments(app: String, profileDir: String, isSystem: Bool,
                              capture: Bool, enable: Bool = true, brain: String? = nil) -> [String]? {
        let verb = enable ? "wire" : "unwire"
        // The profile's own brain (Brainium 0.3+): its MCP server and capture hook use it.
        let brainArgs = enable && !(brain ?? "").isEmpty ? ["--brain", brain!] : []
        switch app {
        case "claude-code":
            var args = [verb, "--app", "claude-code", "--profile", profileDir, "--json"] + brainArgs
            if isSystem { args.append("--system") }
            if enable && capture { args.append("--capture") }
            return args
        case "claude-desktop":
            return [verb, "--app", "claude-desktop", "--profile", profileDir, "--json"] + brainArgs
        case "cursor":
            return [verb, "--app", "cursor", "--json"]
        default:
            return nil
        }
    }

    /// Wire or unwire every listed profile; Cursor's shared config once.
    /// Returns a one-line summary.
    func wireAll(_ profiles: [(app: String, dir: String, isSystem: Bool, brain: String?)], enable: Bool) throws -> String {
        let st = try status()
        if enable && st.personalExists != true {
            throw BridgeError.failed("Create your personal brain first.")
        }
        var done = 0
        var cursorDone = false
        var problems: [String] = []
        for p in profiles {
            let brain = st.supportsTeams ? p.brain : nil
            guard let args = Self.wireArguments(app: p.app, profileDir: p.dir, isSystem: p.isSystem,
                                                capture: st.capture ?? false, enable: enable, brain: brain) else { continue }
            if p.app == "cursor" {
                if cursorDone { done += 1; continue }
                cursorDone = true
            }
            do {
                _ = try run(args)
                done += 1
            } catch {
                problems.append("\((p.dir as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }
        let verb = enable ? "Wired" : "Unwired"
        let summary = "\(verb) \(done) profile\(done == 1 ? "" : "s")."
        return problems.isEmpty ? summary : summary + " Problems: " + problems.joined(separator: "; ")
    }
}

import Foundation

// MARK: - Prism endpoint: what each identity spends
//
// Every reply reports its token counts. Prism adds them up per identity,
// model and day, and prices them from a list you can edit, so you can see
// what Work and Personal cost and cap them. Costs are estimates: list
// prices, before discounts, surcharges or tool fees.

/// US dollars per million tokens.
struct GatewayPrice: Codable, Hashable, Sendable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double

    init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead ?? input
        self.cacheWrite = cacheWrite ?? input
    }

    func cost(_ u: CanonUsage) -> Double {
        (Double(u.input) * input + Double(u.output) * output
            + Double(u.cacheRead) * cacheRead + Double(u.cacheWrite) * cacheWrite) / 1_000_000
    }
}

enum GatewayPricing {
    /// Published list prices (Nov 2026), matched by the longest model-id
    /// prefix. Anthropic cache writes are 1.25× input; OpenAI charges
    /// cache writes as normal input.
    static let builtIn: [String: GatewayPrice] = {
        var t: [String: GatewayPrice] = [:]
        func a(_ id: String, _ i: Double, _ o: Double, _ cr: Double) {
            t[id] = GatewayPrice(input: i, output: o, cacheRead: cr, cacheWrite: i * 1.25)
        }
        func oa(_ id: String, _ i: Double, _ o: Double, _ cr: Double? = nil) {
            t[id] = GatewayPrice(input: i, output: o, cacheRead: cr ?? i, cacheWrite: i)
        }
        // Anthropic
        a("claude-opus-5-5", 4, 20, 0.20)
        a("claude-sonnet-5-5", 2, 10, 0.10)
        a("claude-haiku-5-5", 0.10, 0.50, 0.01)
        a("claude-fable-5-2", 8, 40, 0.20)
        a("claude-fable-5-1", 10, 50, 0.25)
        a("claude-mythos-5-2", 8, 40, 0.20)
        a("claude-mythos-5", 10, 50, 1)
        a("claude-opus-5", 5, 25, 0.50)
        a("claude-sonnet-5", 2, 10, 0.20)
        a("claude-haiku-4-5", 1, 5, 0.10)
        a("claude-opus-4-1", 15, 75, 1.50)
        a("claude-opus-4-2025", 15, 75, 1.50)
        a("claude-opus-4", 5, 25, 0.50)
        a("claude-sonnet-4", 3, 15, 0.30)
        a("claude-3-7-sonnet", 3, 15, 0.30)
        a("claude-3-5-sonnet", 3, 15, 0.30)
        a("claude-3-5-haiku", 0.80, 4, 0.08)
        a("claude-3-haiku", 0.25, 1.25, 0.03)
        // OpenAI
        oa("gpt-6-astra", 10, 50, 1)
        oa("gpt-6.1-sol", 2, 10, 0.10)
        oa("gpt-6.1-terra", 1, 5, 0.05)
        oa("gpt-6-luna", 0.10, 0.50, 0.01)
        oa("gpt-6-sol", 2, 10, 0.20)
        oa("gpt-5.6-sol", 4, 20, 0.40)
        oa("gpt-5.6-terra", 2, 12, 0.20)
        oa("gpt-5.6-luna", 0.20, 1.20, 0.02)
        oa("gpt-5.5-pro", 30, 180)
        oa("gpt-5.5", 5, 30, 0.50)
        oa("gpt-5.4-pro", 30, 180)
        oa("gpt-5.4-mini", 0.75, 4.50, 0.075)
        oa("gpt-5.4-nano", 0.20, 1.25, 0.02)
        oa("gpt-5.4", 2.50, 15, 0.25)
        oa("gpt-5.2-pro", 21, 168)
        oa("gpt-5.2", 1.75, 14, 0.175)
        oa("gpt-5.1", 1.25, 10, 0.125)
        oa("gpt-5-pro", 15, 120)
        oa("gpt-5-mini", 0.25, 2, 0.025)
        oa("gpt-5-nano", 0.05, 0.40, 0.005)
        oa("gpt-5", 1.25, 10, 0.125)
        oa("gpt-4.1-mini", 0.40, 1.60, 0.10)
        oa("gpt-4.1", 2, 8, 0.50)
        oa("gpt-4o-mini", 0.15, 0.60, 0.075)
        oa("gpt-4o", 2.50, 10, 1.25)
        oa("o3-pro", 20, 80)
        oa("o3", 2, 8, 0.50)
        return t
    }()

    /// The price for `model`, or nil if unknown. Your own server costs
    /// nothing unless you set a price for it.
    static func price(for model: String, provider: GatewayProvider, overrides: [String: GatewayPrice]) -> GatewayPrice? {
        let m = model.lowercased()
        func best(_ table: [String: GatewayPrice]) -> GatewayPrice? {
            table.filter { m.hasPrefix($0.key.lowercased()) }.max { $0.key.count < $1.key.count }?.value
        }
        if let p = best(overrides) { return p }
        if provider == .compatible { return GatewayPrice(input: 0, output: 0) }
        return best(builtIn)
    }
}

struct UsageTotals: Codable, Equatable, Sendable {
    var requests = 0
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var cost = 0.0
    /// Requests whose model had no price (not in `cost`).
    var unpriced = 0

    var tokens: Int { input + output + cacheRead + cacheWrite }

    mutating func add(_ o: UsageTotals) {
        requests += o.requests
        input += o.input
        output += o.output
        cacheRead += o.cacheRead
        cacheWrite += o.cacheWrite
        cost += o.cost
        unpriced += o.unpriced
    }
}

/// Daily totals per identity and model, kept for 120 days.
final class GatewayUsageStore: @unchecked Sendable {
    /// day ("2026-11-16") → identity id → model → totals
    private var days: [String: [String: [String: UsageTotals]]] = [:]
    private let lock = NSLock()
    private let fileURL: URL?
    private var dirty = false
    private var saveScheduled = false

    static var defaultURL: URL {
        GatewayConfig.fileURL.deletingLastPathComponent().appendingPathComponent("endpoint-usage.json")
    }

    /// nil keeps usage in memory only.
    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: [String: [String: UsageTotals]]].self, from: data) {
            days = saved
        }
    }

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func monthKey(_ date: Date) -> String {
        String(dayKey(date).prefix(7))
    }

    func record(identityID: String, model: String, usage: CanonUsage, cost: Double?, date: Date = Date()) {
        var t = UsageTotals()
        t.requests = 1
        t.input = usage.input
        t.output = usage.output
        t.cacheRead = usage.cacheRead
        t.cacheWrite = usage.cacheWrite
        if let cost { t.cost = cost } else if usage.input + usage.output > 0 { t.unpriced = 1 }
        lock.lock()
        let day = Self.dayKey(date)
        days[day, default: [:]][identityID, default: [:]][model, default: UsageTotals()].add(t)
        dirty = true
        let schedule = !saveScheduled && fileURL != nil
        if schedule { saveScheduled = true }
        lock.unlock()
        if schedule {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in self?.save() }
        }
    }

    func save() {
        lock.lock()
        saveScheduled = false
        guard dirty, let fileURL else { lock.unlock(); return }
        // Keep 120 days.
        let cutoff = Self.dayKey(Date().addingTimeInterval(-120 * 86_400))
        days = days.filter { $0.key >= cutoff }
        let snapshot = days
        dirty = false
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// This calendar month's totals for an identity.
    func month(_ identityID: String, of date: Date = Date()) -> UsageTotals {
        let prefix = Self.monthKey(date)
        lock.lock(); defer { lock.unlock() }
        var t = UsageTotals()
        for (day, ids) in days where day.hasPrefix(prefix) {
            for (_, total) in ids[identityID] ?? [:] { t.add(total) }
        }
        return t
    }

    func today(_ identityID: String) -> UsageTotals {
        let key = Self.dayKey(Date())
        lock.lock(); defer { lock.unlock() }
        var t = UsageTotals()
        for (_, total) in days[key]?[identityID] ?? [:] { t.add(total) }
        return t
    }

    /// This month's totals per model, most expensive first.
    func monthByModel(_ identityID: String, of date: Date = Date()) -> [(model: String, totals: UsageTotals)] {
        let prefix = Self.monthKey(date)
        lock.lock(); defer { lock.unlock() }
        var byModel: [String: UsageTotals] = [:]
        for (day, ids) in days where day.hasPrefix(prefix) {
            for (model, total) in ids[identityID] ?? [:] { byModel[model, default: UsageTotals()].add(total) }
        }
        return byModel.map { ($0.key, $0.value) }.sorted { $0.totals.cost == $1.totals.cost ? $0.totals.tokens > $1.totals.tokens : $0.totals.cost > $1.totals.cost }
    }

    /// Models used this month that have no price.
    func unpricedModels(of date: Date = Date()) -> [String] {
        let prefix = Self.monthKey(date)
        lock.lock(); defer { lock.unlock() }
        var out = Set<String>()
        for (day, ids) in days where day.hasPrefix(prefix) {
            for (_, models) in ids {
                for (model, t) in models where t.unpriced > 0 { out.insert(model) }
            }
        }
        return out.sorted()
    }

    /// Daily cost for the last `n` days, oldest first.
    func dailyCost(_ identityID: String, days n: Int = 30) -> [(day: String, cost: Double, tokens: Int)] {
        lock.lock(); defer { lock.unlock() }
        return (0..<n).reversed().map { offset in
            let key = Self.dayKey(Date().addingTimeInterval(-Double(offset) * 86_400))
            var t = UsageTotals()
            for (_, total) in days[key]?[identityID] ?? [:] { t.add(total) }
            return (key, t.cost, t.tokens)
        }
    }
}

// MARK: - Token counts inside replies

extension CanonUsage {
    init(responses u: JSONObject?) {
        let inputTotal = GatewayJSON.int(u?["input_tokens"]) ?? 0
        cacheRead = GatewayJSON.int((u?["input_tokens_details"] as? JSONObject)?["cached_tokens"]) ?? 0
        input = max(0, inputTotal - cacheRead)
        output = GatewayJSON.int(u?["output_tokens"]) ?? 0
    }

    /// Usage from a complete (non-streamed) reply in `api`'s shape.
    init(reply j: JSONObject, api: GatewayAPI) {
        switch api {
        case .anthropic: self.init(anthropic: j["usage"] as? JSONObject)
        case .chat: self.init(chat: j["usage"] as? JSONObject)
        case .responses: self.init(responses: j["usage"] as? JSONObject)
        }
    }
}

/// Reads token counts out of a stream that's being passed through as-is.
final class UsageSniffer {
    private let api: GatewayAPI
    private(set) var usage = CanonUsage()

    init(api: GatewayAPI) { self.api = api }

    /// Give it each complete SSE line.
    func feed(_ line: Data) {
        // Most lines carry no usage; skip them without parsing.
        guard line.count > 6, line.range(of: Data("usage".utf8)) != nil,
              let text = String(data: line, encoding: .utf8), text.hasPrefix("data:") else { return }
        let payload = text.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let j = GatewayJSON.parse(Data(payload.utf8)) else { return }
        switch api {
        case .anthropic:
            if let m = j["message"] as? JSONObject, let u = m["usage"] as? JSONObject {
                let start = CanonUsage(anthropic: u)
                usage.input = start.input
                usage.cacheRead = start.cacheRead
                usage.cacheWrite = start.cacheWrite
                if start.output > 0 { usage.output = start.output }
            } else if let u = j["usage"] as? JSONObject {
                if let o = GatewayJSON.int(u["output_tokens"]) { usage.output = o }
                if let i = GatewayJSON.int(u["input_tokens"]), i > 0 { usage.input = i }
                if let r = GatewayJSON.int(u["cache_read_input_tokens"]), r > 0 { usage.cacheRead = r }
                if let w = GatewayJSON.int(u["cache_creation_input_tokens"]), w > 0 { usage.cacheWrite = w }
            }
        case .chat:
            if let u = j["usage"] as? JSONObject { usage = CanonUsage(chat: u) }
        case .responses:
            if let r = j["response"] as? JSONObject, let u = r["usage"] as? JSONObject {
                usage = CanonUsage(responses: u)
            }
        }
    }
}

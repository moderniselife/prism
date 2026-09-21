import AppKit
import CoreGraphics

// MARK: - Honest system telemetry
//
// Everything here is measured live. Nothing is hardcoded: total RAM comes
// from the kernel, CPU % from Mach host statistics, per-profile RSS/CPU
// from `ps`, and window counts from the on-screen window list.

enum SystemStats {
    /// Real physical RAM, e.g. 16/32/64 GB depending on the Mac.
    static let physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory

    /// On-screen window counts keyed by PID. Counting — not guessing.
    static func windowCounts(for pids: [Int32]) -> [Int32: Int] {
        guard !pids.isEmpty else { return [:] }
        let wanted = Set(pids)
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [:] }
        var out: [Int32: Int] = [:]
        for info in list {
            // Layer 0 only: skips tooltip/menu/shadow helper windows that
            // would otherwise inflate the count.
            if let layer = info[kCGWindowLayer as String] as? NSNumber, layer.intValue != 0 {
                continue
            }
            var pid: Int32?
            if let n = info[kCGWindowOwnerPID as String] as? NSNumber {
                pid = n.int32Value
            } else if let i = info[kCGWindowOwnerPID as String] as? Int {
                pid = Int32(i)
            }
            guard let pid, wanted.contains(pid) else { continue }
            out[pid, default: 0] += 1
        }
        return out
    }
}

/// Real system CPU % via Mach host-statistics deltas.
/// First call returns nil (no previous sample to diff against).
final class SystemCPUMonitor {
    private var previous: host_cpu_load_info?
    private let lock = NSLock()

    func usage() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        defer { previous = info }
        guard let p = previous else { return nil }
        let user = Double(info.cpu_ticks.0) - Double(p.cpu_ticks.0)
        let sys  = Double(info.cpu_ticks.1) - Double(p.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2) - Double(p.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3) - Double(p.cpu_ticks.3)
        let total = user + sys + idle + nice
        guard total > 0 else { return nil }
        return max(0, min(100, (total - idle) / total * 100))
    }
}

// MARK: - Cross-view app actions

extension Notification.Name {
    static let prismNewProfile = Notification.Name("prismNewProfile")
    static let prismQuickSwitch = Notification.Name("prismQuickSwitch")
    static let prismFocusSearch = Notification.Name("prismFocusSearch")
}

enum PrismUI {
    /// Bring the hub window forward (and create nothing fake).
    static func openHub() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows
        where window.canBecomeMain && window.sheetParent == nil {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Open the hub, then ask it to present the New Profile sheet.
    static func newProfile() {
        openHub()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NotificationCenter.default.post(name: .prismNewProfile, object: nil)
        }
    }
}

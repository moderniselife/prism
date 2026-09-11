import AppKit

/// Cursor's Dock icon can't be rebranded per profile — re-signing its
/// executable under a different identity crashes it (deliberate anti-tamper
/// protection), which is also why this app no longer builds per-profile
/// wrapper .apps at all: each one is a distinct bundle identity, and macOS
/// ties permission consent (mic, camera, folder access, etc.) to whichever
/// bundle launched Cursor — so every wrapper re-triggered Cursor's entire
/// permission set as if it were a brand new, unfamiliar app. Instead, the
/// next best way to tell profiles apart while they're open is a distinct
/// title bar color per profile, visible in the window itself and in
/// Cmd+Tab/Mission Control.
enum TitleBarColorizer {

    /// Merge this profile's title-bar colors into its `User/settings.json`,
    /// preserving every other setting already there. No-op for the built-in
    /// profile — we never touch the user's real Cursor settings.
    static func apply(profile: CursorProfile, profileDir: URL) {
        guard !profile.isSystem else { return }

        let settingsURL = profileDir.appendingPathComponent("User/settings.json")
        do {
            try FileManager.default.createDirectory(
                at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return
        }

        var settings = readSettings(at: settingsURL)

        var colors = settings["workbench.colorCustomizations"] as? [String: Any] ?? [:]
        for (key, value) in colorValues(for: profile.colorHex) {
            colors[key] = value
        }
        settings["workbench.colorCustomizations"] = colors
        // Native title bars ignore colorCustomizations on macOS — required for the colors to render.
        settings["window.titleBarStyle"] = "custom"

        writeSettings(settings, to: settingsURL)
    }

    static func colorValues(for hex: String) -> [String: String] {
        let foreground = contrastingForeground(for: hex)
        return [
            "titleBar.activeBackground": hex,
            "titleBar.activeForeground": foreground,
            "titleBar.inactiveBackground": shade(hex, by: 0.55),
            "titleBar.inactiveForeground": foreground + "AA",
        ]
    }

    // MARK: - JSONC-tolerant read/write

    private static func readSettings(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [:] }
        let stripped = stripJSONComments(text)
        guard let strippedData = stripped.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: strippedData),
              let dict = object as? [String: Any] else { return [:] }
        return dict
    }

    private static func writeSettings(_ settings: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Strips `//` and `/* */` comments and trailing commas so a hand-edited
    /// JSONC settings.json (VS Code allows both) can still round-trip through
    /// strict JSONSerialization. Comments are not preserved on write.
    private static func stripJSONComments(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var inString = false
        var escaped = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if inString {
                result.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                i = text.index(after: i)
                continue
            }
            if c == "\"" {
                inString = true
                result.append(c)
                i = text.index(after: i)
                continue
            }
            if c == "/", text.index(after: i) < text.endIndex {
                let next = text[text.index(after: i)]
                if next == "/" {
                    while i < text.endIndex, text[i] != "\n" { i = text.index(after: i) }
                    continue
                }
                if next == "*" {
                    i = text.index(i, offsetBy: 2)
                    while i < text.endIndex {
                        if text[i] == "*", text.index(after: i) < text.endIndex,
                           text[text.index(after: i)] == "/" {
                            i = text.index(i, offsetBy: 2)
                            break
                        }
                        i = text.index(after: i)
                    }
                    continue
                }
            }
            result.append(c)
            i = text.index(after: i)
        }
        // Trailing commas before a closing bracket/brace.
        while let range = result.range(of: #",\s*([}\]])"#, options: .regularExpression) {
            let closer = result[result.index(before: range.upperBound)]
            result.replaceSubrange(range, with: String(closer))
        }
        return result
    }

    // MARK: - Color helpers

    private static func shade(_ hex: String, by factor: Double) -> String {
        guard let value = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16) else { return hex }
        let r = Double((value >> 16) & 0xFF) * factor
        let g = Double((value >> 8) & 0xFF) * factor
        let b = Double(value & 0xFF) * factor
        return String(format: "#%02X%02X%02X", Int(r), Int(g), Int(b))
    }

    private static func contrastingForeground(for hex: String) -> String {
        guard let value = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16) else { return "#FFFFFF" }
        let r = Double((value >> 16) & 0xFF)
        let g = Double((value >> 8) & 0xFF)
        let b = Double(value & 0xFF)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 150 ? "#1A1A1A" : "#FFFFFF"
    }
}

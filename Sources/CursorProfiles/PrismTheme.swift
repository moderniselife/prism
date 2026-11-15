import SwiftUI
import AppKit

// MARK: - Prism Design System (adaptive light / dark, follows system)

enum PrismTheme {

    // MARK: Core palette — all dynamic, listen to system appearance

    enum Colors {
        // Quiet neutrals: white / near-black grounds, one accent, hairline
        // borders. Surfaces stay solid (no translucency).
        static let bg          = adaptive(lightHex: "#FFFFFF", darkHex: "#141416")
        static let bgAlt       = adaptive(lightHex: "#F7F7F8", darkHex: "#19191C") // sidebar
        static let surface     = adaptive(lightHex: "#FFFFFF", darkHex: "#1C1C20")
        static let surfaceAlt  = adaptive(lightHex: "#F1F1F3", darkHex: "#222227") // fields
        static let surfaceHigh = adaptive(lightHex: "#E9E9EC", darkHex: "#2A2A30") // selected
        static let panel       = adaptive(lightHex: "#FCFCFD", darkHex: "#17171A") // inspector
        static let card        = adaptive(lightHex: "#FFFFFF", darkHex: "#1C1C20")
        static let control     = adaptive(lightHex: "#EEEEF1", darkHex: "#25252A")
        static let hover       = adaptive(lightHex: "#F4F4F6", darkHex: "#1F1F23")

        static let border       = adaptive(lightHex: "#E6E6EA", darkHex: "#2A2A2F")
        static let borderSubtle = adaptive(lightHex: "#EFEFF2", darkHex: "#222227")
        static let borderMed    = adaptive(lightHex: "#DCDCE1", darkHex: "#34343A")
        static let borderStrong = adaptive(lightHex: "#C9C9D0", darkHex: "#45454D")

        // Text grays tuned for >= 4.5:1 on their grounds.
        static let textPrimary   = adaptive(lightHex: "#18181B", darkHex: "#EDEDF0")
        static let textSecondary = adaptive(lightHex: "#52525C", darkHex: "#A9A9B3")
        static let textTertiary  = adaptive(lightHex: "#6B6B75", darkHex: "#8C8C97")
        static let textMuted     = adaptive(lightHex: "#8E8E98", darkHex: "#6A6A74")

        /// The one brand accent: primary buttons, selection, focus.
        static let accent     = adaptive(lightHex: "#5B5BD6", darkHex: "#7B7BEA")
        /// Accent for text and icons on neutral grounds.
        static let accentText = adaptive(lightHex: "#4F4FC4", darkHex: "#A5A5F3")
        /// Legacy name for the brand accent, kept for older views.
        static var cyan: Color { accent }

        /// Running state: a live dot and its label.
        static let live    = adaptive(lightHex: "#22C55E", darkHex: "#22C55E")
        static let emerald = adaptive(lightHex: "#15803D", darkHex: "#4ADE80")

        static let purple  = adaptive(lightHex: "#6D28D9", darkHex: "#A78BFA")
        static let pink    = adaptive(lightHex: "#BE185D", darkHex: "#F472B6")
        static let amber   = adaptive(lightHex: "#B45309", darkHex: "#FBBF24")
        static let red     = adaptive(lightHex: "#DC2626", darkHex: "#F87171")
        static let blue    = adaptive(lightHex: "#2563EB", darkHex: "#60A5FA")
        static let indigo  = adaptive(lightHex: "#4F46E5", darkHex: "#818CF8")
        static let teal    = adaptive(lightHex: "#0F766E", darkHex: "#2DD4BF")
        static let orange  = adaptive(lightHex: "#C2410C", darkHex: "#FB923C")
    }

    /// Dynamic Color that resolves per-system-appearance. This is what makes
    /// the whole app follow Light / Dark Mode without any extra plumbing —
    /// no `@Environment(\.colorScheme)` needed at call sites.
    private static func adaptive(lightHex: String, darkHex: String) -> Color {
        let light = NSColor(hex: lightHex) ?? .controlBackgroundColor
        let dark = NSColor(hex: darkHex) ?? .windowBackgroundColor
        let dynamic = NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
        return Color(nsColor: dynamic)
    }

    // MARK: Gradients

    enum Gradients {
        static func cardGlow(accent: Color) -> LinearGradient {
            LinearGradient(
                colors: [accent.opacity(0.22), accent.opacity(0.06), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        static var spotlight: RadialGradient {
            RadialGradient(
                colors: [
                    Colors.purple.opacity(0.14),
                    Colors.cyan.opacity(0.08),
                    .clear
                ],
                center: .center,
                startRadius: 0,
                endRadius: 650
            )
        }

        static var ambientMesh: some ShapeStyle {
            LinearGradient(
                colors: [
                    Colors.cyan.opacity(0.10),
                    Colors.purple.opacity(0.10),
                    Colors.pink.opacity(0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // MARK: Typography

    enum FontSize {
        static let tiny:    CGFloat = 9
        static let caption: CGFloat = 10
        static let small:   CGFloat = 11
        static let body:    CGFloat = 12
        static let regular: CGFloat = 13
        static let medium:  CGFloat = 14
        static let large:   CGFloat = 15
        static let title:   CGFloat = 16
        static let heading: CGFloat = 18
    }

    // MARK: Dimensions

    enum Layout {
        static let cornerSmall:  CGFloat = 8
        static let cornerMedium: CGFloat = 12
        static let cornerLarge:  CGFloat = 16
        static let cornerXLarge: CGFloat = 20

        static let spacingXS: CGFloat = 4
        static let spacingSM: CGFloat = 8
        static let spacingMD: CGFloat = 12
        static let spacingLG: CGFloat = 16
        static let spacingXL: CGFloat = 24

        static let cardMinWidth: CGFloat = 260
        static let titleBarHeight: CGFloat = 48
        static let statusBarHeight: CGFloat = 40
    }
}

// MARK: - Reusable view modifiers

/// Solid surface with a hairline border. No glow, no tint wash.
struct GlassCardModifier: ViewModifier {
    var accentColor: Color = .clear
    var isActive: Bool = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerLarge)
                    .fill(PrismTheme.Colors.surface)
            }
            .overlay(
                RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerLarge)
                    .strokeBorder(isActive ? accentColor.opacity(0.35) : PrismTheme.Colors.border, lineWidth: 1)
                    .allowsHitTesting(false)
            )
    }
}

/// A single soft drop shadow for floating panels. `color` is ignored:
/// coloured glows were part of the old look.
struct GlowShadowModifier: ViewModifier {
    var color: Color = PrismTheme.Colors.accent
    var radius: CGFloat = 20

    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(0.16), radius: radius * 0.6, y: radius * 0.2)
    }
}

/// Solid accent button (kept for older call sites).
struct PrismGlowButtonStyle: ButtonStyle {
    var color: Color = PrismTheme.Colors.accent

    func makeBody(configuration: Configuration) -> some View {
        PrismButtonStyle(kind: .primary).makeBody(configuration: configuration)
    }
}

/// The app's button look: primary (solid accent), secondary (bordered),
/// tinted (soft accent) or plain (text only, for quiet row actions).
struct PrismButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, tinted, plain }
    var kind: Kind = .secondary
    var height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        PrismButtonBody(configuration: configuration, kind: kind, height: height)
    }
}

struct PrismButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: PrismButtonStyle.Kind
    let height: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .secondary: return PrismTheme.Colors.textPrimary
        case .tinted: return PrismTheme.Colors.accentText
        case .plain: return PrismTheme.Colors.textSecondary
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: return PrismTheme.Colors.accent
        case .secondary: return PrismTheme.Colors.surface
        case .tinted: return PrismTheme.Colors.accent.opacity(0.12)
        case .plain: return .clear
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(kind == .secondary ? PrismTheme.Colors.borderMed : .clear, lineWidth: 1))
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}

extension View {
    func glassCard(accent: Color = .clear, active: Bool = false) -> some View {
        modifier(GlassCardModifier(accentColor: accent, isActive: active))
    }

    func glowShadow(color: Color = PrismTheme.Colors.cyan, radius: CGFloat = 20) -> some View {
        modifier(GlowShadowModifier(color: color, radius: radius))
    }
}

// MARK: - Real bundle version (no marketing numbers)

enum PrismVersion {
    static var string: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

// MARK: - NSColor hex (for dynamic provider)

extension NSColor {
    convenience init?(hex: String) {
        var str = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("#") { str.removeFirst() }
        guard str.count == 6, let value = UInt64(str, radix: 16) else { return nil }
        self.init(
            calibratedRed: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

// MARK: - Accent palette (extended from Models.swift)

struct AccentSwatch: Identifiable, Equatable {
    let name: String
    let hex: String
    var id: String { hex }
    var color: Color { Color(hex: hex) ?? .accentColor }

    static let all: [AccentSwatch] = [
        .init(name: "Cyan",     hex: "#06B6D4"),
        .init(name: "Indigo",   hex: "#6366F1"),
        .init(name: "Purple",   hex: "#8B5CF6"),
        .init(name: "Pink",     hex: "#EC4899"),
        .init(name: "Rose",     hex: "#F43F5E"),
        .init(name: "Orange",   hex: "#F97316"),
        .init(name: "Amber",    hex: "#F59E0B"),
        .init(name: "Emerald",  hex: "#10B981"),
        .init(name: "Teal",     hex: "#14B8A6"),
        .init(name: "Blue",     hex: "#3B82F6"),
        .init(name: "Slate",    hex: "#64748B"),
        .init(name: "Lime",     hex: "#84CC16"),
    ]

    static func random() -> AccentSwatch { all.randomElement()! }
}

// MARK: - IDE Engine model (for profile editor)

enum IDEEngine: String, CaseIterable, Identifiable {
    case cursor = "Cursor"
    case windsurf = "Windsurf"
    case claudeCode = "Claude Code"
    case antiGravity = "AntiGravity"
    case openCode = "OpenCode"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .cursor:     return "Fork 0.44"
        case .windsurf:   return "Cascade AI"
        case .claudeCode: return "Terminal CLI"
        case .antiGravity: return "Multi-agent"
        case .openCode:   return "OSS Core"
        }
    }

    var accentColor: Color {
        switch self {
        case .cursor:     return PrismTheme.Colors.cyan
        case .windsurf:   return PrismTheme.Colors.emerald
        case .claudeCode: return PrismTheme.Colors.amber
        case .antiGravity: return PrismTheme.Colors.purple
        case .openCode:   return PrismTheme.Colors.teal
        }
    }

    var iconName: String {
        switch self {
        case .cursor:     return "star.fill"
        case .windsurf:   return "wind"
        case .claudeCode: return "clock.fill"
        case .antiGravity: return "circle.dashed"
        case .openCode:   return "chevron.left.forwardslash.chevron.right"
        }
    }
}

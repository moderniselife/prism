import SwiftUI
import AppKit

// MARK: - Prism Design System (adaptive light / dark, follows system)

enum PrismTheme {

    // MARK: Core palette — all dynamic, listen to system appearance

    enum Colors {
        // Surfaces: solid (no translucency) so cards never look washed out.
        static let bg          = adaptive(lightHex: "#F1F2F5", darkHex: "#080B11")
        static let bgAlt       = adaptive(lightHex: "#E8EAF0", darkHex: "#0C1017")
        static let surface     = adaptive(lightHex: "#FFFFFF", darkHex: "#141A27")
        static let surfaceAlt  = adaptive(lightHex: "#ECEFF4", darkHex: "#1B2233")
        static let surfaceHigh = adaptive(lightHex: "#DDE3EC", darkHex: "#253046")
        static let panel       = adaptive(lightHex: "#FFFFFF", darkHex: "#131824")
        static let card        = adaptive(lightHex: "#FFFFFF", darkHex: "#161C2A")
        static let control     = adaptive(lightHex: "#E4E8F0", darkHex: "#1E2638")

        // Borders derived from primary so they flip automatically.
        // Stronger than before (0.09 was invisible on both modes).
        static let border       = Color.primary.opacity(0.14)
        static let borderSubtle = Color.primary.opacity(0.08)
        static let borderMed    = Color.primary.opacity(0.18)
        static let borderStrong = Color.primary.opacity(0.26)

        // Text: real grays tuned for contrast, not white-at-opacity.
        // Dark-bg values hit ~7:1 / ~4.6:1; light-bg values hit ~8:1 / ~4.6:1.
        static let textPrimary   = adaptive(lightHex: "#10151F", darkHex: "#F2F4F8")
        static let textSecondary = adaptive(lightHex: "#3F4756", darkHex: "#B7BFCD")
        static let textTertiary  = adaptive(lightHex: "#646D7D", darkHex: "#8E97A8")
        static let textMuted     = adaptive(lightHex: "#8B94A4", darkHex: "#6E7789")

        // Accents: darker cut for light mode (legible on white),
        // brighter cut for dark mode (legible on near-black).
        static let cyan    = adaptive(lightHex: "#0A7C93", darkHex: "#22D3EE")
        static let purple  = adaptive(lightHex: "#6D28D9", darkHex: "#A78BFA")
        static let pink    = adaptive(lightHex: "#BE185D", darkHex: "#F472B6")
        static let emerald = adaptive(lightHex: "#047857", darkHex: "#34D399")
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

/// Solid card — no `.ultraThinMaterial`, which was washing cards out to gray
/// against the dark background and vibrating in light mode.
struct GlassCardModifier: ViewModifier {
    var accentColor: Color = .clear
    var isActive: Bool = false

    func body(content: Content) -> some View {
        content
            .background {
                // Tint lives UNDER the content — an overlay here would sit
                // above the buttons and swallow every click on the card.
                ZStack {
                    RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerLarge)
                        .fill(PrismTheme.Colors.surface)
                    RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerLarge)
                        .fill(isActive ? accentColor.opacity(0.07) : .clear)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerLarge)
                    .strokeBorder(isActive ? accentColor.opacity(0.45) : PrismTheme.Colors.borderMed,
                                  lineWidth: isActive ? 1.5 : 1)
                    .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
    }
}

struct GlowShadowModifier: ViewModifier {
    var color: Color = PrismTheme.Colors.cyan
    var radius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(0.16), radius: radius, y: radius / 2)
            .shadow(color: .black.opacity(0.14), radius: radius / 2, y: radius / 4)
    }
}

struct PrismGlowButtonStyle: ButtonStyle {
    var color: Color = PrismTheme.Colors.cyan

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: PrismTheme.FontSize.body, weight: .semibold))
            .foregroundStyle(PrismTheme.Colors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                LinearGradient(colors: [color, color.opacity(0.82)], startPoint: .top, endPoint: .bottom)
            )
            .clipShape(RoundedRectangle(cornerRadius: PrismTheme.Layout.cornerSmall))
            .shadow(color: color.opacity(0.32), radius: 8, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
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

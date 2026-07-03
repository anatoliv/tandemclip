import SwiftUI
import AppKit

/// Light / dark / follow-the-system appearance, mirroring tonebox's `AppTheme`.
/// tandemclip is a menu-bar accessory app whose surfaces (picker, settings,
/// About/Help) are AppKit-hosted, so the lever is `NSApp.appearance` — setting
/// it cascades to every window and menu at once, the AppKit-native equivalent
/// of SwiftUI's `.preferredColorScheme`.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// The AppKit appearance to force, or nil to follow the system setting.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    /// Apply app-wide. Safe to call repeatedly (idempotent); pass `.system`
    /// to hand appearance back to macOS.
    static func apply(_ theme: AppTheme) {
        NSApp.appearance = theme.appearance
    }
}

/// Design tokens, adopted from tonebox's Theme/Tokens.swift so the two apps
/// share one visual family (warm paper + terracotta) instead of tandemclip
/// riding the system blue.
///
/// Source of truth: `docs/design/DESIGN_SYSTEM.md` (TandemClip Design System),
/// itself based on Tonebox Design System v1. The visual language is crisp,
/// dense and functional: warm surfaces, minimal corner radii (not rounded),
/// flat (no elevation), typography-first, subtle ease-out motion.
enum Tokens {
    // MARK: Colors

    /// Primary accent — selection, active controls, positive toasts. This is
    /// tonebox's WCAG-AA-safe rendering of the brand terracotta (~#C7693D,
    /// 3.5:1 on warm paper): safe for small fills, strokes, and text chips.
    static let accent = Color(red: 0.78, green: 0.41, blue: 0.24)

    /// Pure brand terracotta (#F26B3A) — large fills and brand moments only,
    /// never small text/strokes (fails AA there; see tonebox's contrast audit).
    static let brandAccent = Color(red: 0.949, green: 0.420, blue: 0.227)

    /// Muted positive (moss/sage) — success states that shouldn't shout:
    /// "synced", a healthy peer, the What's-New LATEST chip.
    static let positive = Color(red: 0.40, green: 0.56, blue: 0.36)

    /// Caution amber — held/paused states that need attention but aren't
    /// errors: privacy hold, a secret-guard hold, sync paused, "Fixed" notes.
    /// Destructive/error stays the system red; caution is never the accent.
    static let warning = Color(red: 0.85, green: 0.52, blue: 0.19)

    // MARK: Radius — crisp scale (never rounded/pill for containers)

    /// Corner-radius tokens. tonebox evaluated a soft 12/16/20/24 scale in
    /// app and rejected it (large radii ballooned small controls); the
    /// shipped language is crisp. Match it so the two apps feel the same.
    /// Do NOT set a window/sheet radius — macOS owns that curve.
    enum Radius {
        static let chip: CGFloat = 3     // status pills, badges
        static let control: CGFloat = 4  // buttons, text fields, key caps
        static let card: CGFloat = 6     // cards, hover previews, list rows
        static let sheet: CGFloat = 8    // overlays, popovers
    }

    // MARK: Spacing — 4pt scale, descriptive names document intent

    enum Space {
        static let row: CGFloat = 4      // inline gaps inside chips
        static let row6: CGFloat = 6     // tight two-column / badge gaps
        static let tight: CGFloat = 8    // close-pair spacing
        static let medium: CGFloat = 10  // search-field padding, row gaps
        static let snug: CGFloat = 12    // most stack spacing
        static let element: CGFloat = 14 // row-cell content gaps
        static let regular: CGFloat = 16 // standard padding/spacing
        static let wide: CGFloat = 24    // section gutters, pane padding
        static let pane: CGFloat = 28    // Help/Settings outer pane padding
        static let hero: CGFloat = 48    // empty-state spacing
    }

    /// Chip / pill padding — kept in lockstep so status pills and badges
    /// don't diverge by ±1pt across the app.
    enum ChipPadding {
        static let h: CGFloat = 6
        static let v: CGFloat = 2
    }

    // MARK: Typography — native SF faces (Display for body, Rounded for brand)

    /// Type scale. Body/UI text is the default SF system face; brand
    /// moments (app name in About) use SF Rounded. No half-point sizes —
    /// pick the nearest step so text lands on a shared rhythm.
    enum FontScale {
        static let display: Font = .system(size: 21, weight: .semibold, design: .rounded) // brand titles
        static let title: Font = .system(size: 20, weight: .semibold)   // pane / page titles
        static let sectionHeader: Font = .system(size: 15, weight: .semibold) // card / group headers
        static let body: Font = .system(size: 13)     // reading body text
        static let bodyStrong: Font = .system(size: 13, weight: .medium)
        static let small: Font = .system(size: 12)    // metadata, captions, secondary rows
        static let tiny: Font = .system(size: 11)     // eyebrow labels, shortcut chips
        static let micro: Font = .system(size: 9, weight: .bold) // badge text (with tracking)
    }

    /// SF Symbol sizing for icon-only images — geometry, not typography.
    enum IconSize {
        static let tiny: CGFloat = 9    // disclosure chevrons, eyebrow icons
        static let small: CGFloat = 11  // inline meta icons
        static let medium: CGFloat = 13 // standard sidebar / toolbar icon
        static let regular: CGFloat = 18 // prominent header / action icon
    }

    // MARK: Motion — 160–240ms ease-out, one shared curve family

    enum Motion {
        /// Pointer-driven feedback: hover, selection, chip toggles.
        static let microCurve: Animation = .easeOut(duration: 0.16)
        /// In-pane reveals: overlays, toasts, fold/unfold.
        static let paneCurve: Animation = .easeOut(duration: 0.20)
        /// Shell-level moves (window/panel) — a touch of settle.
        static let shellCurve: Animation = .spring(response: 0.24, dampingFraction: 0.86)
    }
}

extension Color {
    /// Terse alias for the most-used token.
    static var tandemAccent: Color { Tokens.accent }
}

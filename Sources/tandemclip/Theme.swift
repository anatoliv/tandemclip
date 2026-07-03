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
enum Tokens {
    /// Primary accent — selection, active controls, positive toasts. This is
    /// tonebox's WCAG-AA-safe rendering of the brand terracotta (~#C7693D,
    /// 3.5:1 on warm paper): safe for small fills, strokes, and text chips.
    static let accent = Color(red: 0.78, green: 0.41, blue: 0.24)

    /// Pure brand terracotta (#F26B3A) — large fills and brand moments only,
    /// never small text/strokes (fails AA there; see tonebox's contrast audit).
    static let brandAccent = Color(red: 0.949, green: 0.420, blue: 0.227)

    /// Muted positive (moss/sage) — success states that shouldn't shout.
    static let positive = Color(red: 0.40, green: 0.56, blue: 0.36)

    /// Motion, from tonebox's audited scale: one shared ease so hover
    /// feedback, reveals, and toasts stop animating on subtly different
    /// timings.
    enum Motion {
        /// Pointer-driven feedback: hover, selection, chip toggles.
        static let microCurve: Animation = .easeOut(duration: 0.16)
        /// In-pane reveals: overlays, toasts, fold/unfold.
        static let paneCurve: Animation = .easeOut(duration: 0.20)
    }
}

extension Color {
    /// Terse alias for the most-used token.
    static var tandemAccent: Color { Tokens.accent }
}

import SwiftUI

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

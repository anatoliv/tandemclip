import XCTest
import AppKit
import SwiftUI
@testable import tandemclip

/// Light/dark contrast check for the in-app Help window. Resolves the window's
/// custom color pairs under both appearances and asserts WCAG contrast — so a
/// theme or token change that hurts legibility (e.g. the dark-mode deep-link
/// flash regressing to an invisible wash) fails the build instead of shipping.
final class HelpContrastTests: XCTestCase {

    // MARK: WCAG helpers

    private struct RGB { let r, g, b: Double }

    /// Resolve an NSColor to sRGB components under a specific appearance.
    private func srgb(_ color: NSColor, _ name: NSAppearance.Name) -> RGB {
        var out = RGB(r: 0, g: 0, b: 0)
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB) ?? color
            out = RGB(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
        }
        return out
    }

    /// WCAG relative luminance.
    private func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// WCAG contrast ratio (1…21).
    private func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        let (hi, lo) = (max(l1, l2), min(l1, l2))
        return (hi + 0.05) / (lo + 0.05)
    }

    /// Source-over composite of `top` at `alpha` on `base` (per sRGB channel).
    private func over(_ top: RGB, alpha: Double, _ base: RGB) -> RGB {
        RGB(r: top.r * alpha + base.r * (1 - alpha),
            g: top.g * alpha + base.g * (1 - alpha),
            b: top.b * alpha + base.b * (1 - alpha))
    }

    private let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    // MARK: Tests

    /// The accent (used for the article title icon, links, selection) must clear
    /// the 3:1 AA bar for UI components / large text against the window surface.
    func testAccentReadableOnSurface() {
        let accent = NSColor(Tokens.accent)
        for (label, name) in appearances {
            let ratio = contrast(srgb(accent, name), srgb(.windowBackgroundColor, name))
            XCTAssertGreaterThanOrEqual(ratio, 3.0, "accent vs window (\(label)) = \(ratio)")
        }
    }

    /// Body text over the deep-link flash highlight must stay AA-normal (4.5:1)
    /// in both modes — the wash tints the surface but text must remain crisp.
    func testFlashHighlightKeepsTextReadable() {
        let accent = NSColor(Tokens.accent)
        let peaks: [(String, NSAppearance.Name, Double)] = [
            ("light", .aqua, Tokens.HelpHighlight.light),
            ("dark", .darkAqua, Tokens.HelpHighlight.dark),
        ]
        for (label, name, peak) in peaks {
            let eff = over(srgb(accent, name), alpha: peak, srgb(.windowBackgroundColor, name))
            let ratio = contrast(srgb(.labelColor, name), eff)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "text over flash (\(label)) = \(ratio)")
        }
    }

    /// The flash highlight must be VISIBLE — its tinted surface has to differ
    /// enough from the plain window surface to register, or the "here's your
    /// spot" cue is lost. Near-black, small absolute luminance shifts read as
    /// nothing, so this uses Δluminance (not contrast ratio, which is
    /// appearance-independent and can't tell the two apart). Measured: the old
    /// 0.16 dark wash gave Δlum ≈ 0.013 (invisible); the 0.30 dark peak gives
    /// ≈ 0.031. The 0.022 bar sits between them, so dropping the dark peak back
    /// toward 0.16 fails this test. Light mode always clears it comfortably.
    func testFlashHighlightIsVisible() {
        let accent = NSColor(Tokens.accent)
        let peaks: [(String, NSAppearance.Name, Double)] = [
            ("light", .aqua, Tokens.HelpHighlight.light),
            ("dark", .darkAqua, Tokens.HelpHighlight.dark),
        ]
        for (label, name, peak) in peaks {
            let base = srgb(.windowBackgroundColor, name)
            let eff = over(srgb(accent, name), alpha: peak, base)
            let delta = abs(luminance(eff) - luminance(base))
            XCTAssertGreaterThanOrEqual(delta, 0.022, "flash Δluminance (\(label)) = \(delta)")
        }
    }

    /// The "LATEST" chip is white on the positive (moss) fill — must clear 3:1.
    func testLatestChipReadable() {
        let positive = NSColor(Tokens.positive)
        for (label, name) in appearances {
            let ratio = contrast(RGB(r: 1, g: 1, b: 1), srgb(positive, name))
            XCTAssertGreaterThanOrEqual(ratio, 3.0, "white on positive (\(label)) = \(ratio)")
        }
    }
}

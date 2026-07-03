# TandemClip Design System

TandemClip shares one visual family with **Tonebox** (warm paper + terracotta),
based on **Tonebox Design System v1** (`~/Projects/tonebox/docs/design/DESIGN_SYSTEM.md`).
This document is the tandemclip-specific adaptation — same language and scale,
its own domain semantics (clipboard / sync / security instead of
recording / transcript).

**Source of truth for values:** `Sources/tandemclip/Theme.swift` (`Tokens`).
This doc explains intent; the code enforces it. When they disagree, fix the doc
to match the code, or the code to match this doc — never let a third set of raw
numbers appear in a view.

---

## 1. Visual language

- **Warm surfaces**, not system grey — the app rides paper, not blue.
- **Crisp, minimal corner radius** — cards are `6`, controls `4`, chips `3`.
  Never rounded/pill for containers. (Tonebox tried a soft 12–24 scale in app
  and rejected it: large radii balloon small controls and waste space.)
- **Flat** — no skeuomorphic depth, no drop shadows, no hover *lift*. Hover may
  **tint**, never elevate.
- **Dense, functional** — space is information, not decoration.
- **Typography-first** — hierarchy comes from weight and size on a fixed scale,
  not from boxes and color.
- **Subtle motion** — 160–240 ms ease-out.

## 2. Color

TandemClip is menu-bar utility software: the palette is small and semantic.

| Token | Value | Role |
|-------|-------|------|
| `accent` | `#C7693D` (AA-safe terracotta) | Selection, active controls, links, focus, small brand fills |
| `brandAccent` | `#F26B3A` (pure terracotta) | Large brand fills / the app icon only — **never** small text or strokes (fails WCAG AA there) |
| `positive` | moss `rgb(102,143,92)` | Success that shouldn't shout: "synced", a healthy peer, the What's-New **LATEST** chip |
| `warning` | amber `rgb(217,133,48)` | Held/paused attention states: privacy hold, secret-guard hold, sync paused, "Fixed" release notes |
| system `.red` | — | Genuinely destructive / error only (delete, failed) |

Surfaces come from AppKit semantic colors so light/dark both work:
`windowBackgroundColor`, `controlBackgroundColor`, `textBackgroundColor`, with
`Color.secondary.opacity(0.04–0.12)` for card fills and hairline strokes.

**Rules**
- The accent **never** colors a failure or destructive control.
- `warning` (amber) is for *held/paused*, not for errors — those are `.red`.
- Every text input gets a clear **✕** (see `searchField` in `InfoWindows.swift`).
- Light / Dark / System is honored app-wide via `AppTheme` → `NSApp.appearance`.

## 3. Typography (`Tokens.FontScale`)

Native SF faces — SF system (Display) for UI/body, SF Rounded for brand moments
(the app name in About). **No half-point sizes** — the old code sprawled across
9.5 / 10.5 / 11.5 / 12.5 / 13.5; pick the nearest step instead.

| Token | Size / weight | Use |
|-------|---------------|-----|
| `display` | 21 semibold rounded | Brand title (About) |
| `title` | 20 semibold | Pane / page titles (Help detail header) |
| `sectionHeader` | 15 semibold | Card / group headers |
| `body` | 13 | Reading body text |
| `bodyStrong` | 13 medium | Emphasized body / row titles |
| `small` | 12 | Metadata, captions, secondary rows |
| `tiny` | 11 | Eyebrow labels, shortcut chips |
| `micro` | 9 bold | Badge text (pair with `.tracking(0.4–0.5)`) |

## 4. Radius (`Tokens.Radius`)

`chip 3` · `control 4` · `card 6` · `sheet 8`.

Do **not** set a window or sheet corner radius — macOS owns that curve; any
explicit value lands off-by-one against the host chrome.

## 5. Spacing (`Tokens.Space`)

4-pt scale with descriptive names: `row 4` · `row6 6` · `tight 8` · `medium 10`
· `snug 12` · `element 14` · `regular 16` · `wide 24` · `pane 28` · `hero 48`.
Plus `ChipPadding` = h6 / v2 for every pill and badge.

## 6. Icons (`Tokens.IconSize`)

`tiny 9` (chevrons, eyebrows) · `small 11` (inline meta) · `medium 13`
(sidebar/toolbar) · `regular 18` (prominent header/action).

## 7. Motion (`Tokens.Motion`)

- `microCurve` — 0.16 s ease-out: hover, selection, chip toggles.
- `paneCurve` — 0.20 s ease-out: in-pane reveals, toasts, fold/unfold.
- `shellCurve` — 0.24 s spring (0.86 damping): window/panel-level moves.

No hover elevation (flat language). Respect Reduce Motion where practical.

## 8. Components — canonical patterns

- **Two-pane reader** (Help): fixed 244-pt sidebar + flexible detail pane, in a
  resizable window (min 620×420). Sidebar = `List(.sidebar)` with `Section`s;
  detail = pinned header (icon + `title` + eyebrow badge) over a scrolling body.
- **Card**: `Radius.card` fill of `secondary.opacity(0.04–0.05)` with a
  `secondary.opacity(0.12)` hairline stroke. Flat — no shadow.
- **Badge / chip**: `FontScale.micro` uppercased, `.tracking(0.4)`,
  `ChipPadding` inside a `Capsule` tinted at ~0.14 of its semantic color.
- **Key cap**: `FontScale.tiny` rounded, `Radius.control`, `secondary.opacity(0.14)`.

## 9. Adoption status

| Surface | State |
|---------|-------|
| `Theme.swift` tokens | ✅ full scale (colors, radius, space, type, icons, motion) |
| Help / About (`InfoWindows.swift`) | ✅ tokenized — the reference implementation |
| `SettingsWindow.swift` | ✅ tokenized; controls accent-tinted |
| `ClipboardPicker.swift` | ✅ tokenized (radii, accent, and compact type via `CompactSize`) |

**The whole app now draws from `Tokens`.** The design-drift lint in
`Scripts/check-release.sh` enforces it: no raw `cornerRadius: <n>` or
`.system(size: <n>` in any view (only SF-Rounded faces are exempt).

### The picker's compact type — `Tokens.CompactSize`

The picker is the app's densest surface and needs a finer type ramp than the
reading-oriented `FontScale`. That ramp lives in **`Tokens.CompactSize`**
(`mini 6` · `tiny 8` · `badge 9` · `label 10` · `meta 11` · `rowText 12` ·
`rowTitle 13` · `hero 27`) — raw CGFloat sizes so call sites keep their own
`weight:` / `design:`. These replaced a sprawl of half-point literals
(`6.5`/`8.5`/`9.5`/`10.5`/`11.5`/`12.5`/`13.5`), each rounded **down** to the
nearest clean value (smaller text can't overflow a frame the larger size
already fit).

**Verified, not guessed.** The picker can't be rendered from a lightweight
standalone harness (its models pull in the whole sync engine), so a
DEBUG-only, env-gated renderer — `DebugRender.swift`, driven by
`TANDEMCLIP_RENDER_PICKER=list|hover|compose` — hosts a seeded `PickerModel`
in a window and screenshots it. Every picker state was compared before/after
the token migration; use it again before changing picker type.

**Migration rule:** when you next touch a view, replace its raw `cornerRadius`,
`.system(size:)`, and `.padding()` numbers with the nearest `Tokens` value.
Don't introduce a new raw number — if the scale lacks it, add a named token
here and in `Theme.swift` first.

# Changelog

All notable changes to TandemClip are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html) (pre-1.0).

## [0.23.0] — 2026-07-22
- Automatic reconnect: the LAN transport is rebuilt after the Mac wakes from
  sleep and when the network path changes (Wi-Fi roam or SSID change, Ethernet,
  VPN, network returning). Manual Reconnect stays as the escape hatch.
- Fix a permanent dead end in discovery: `NWBrowser` had no state handler, so a
  failed browser was never rebuilt and the 5s reconcile timer — which only dials
  endpoints the browser reported — silently found nothing for the rest of the
  session. The browser and listener now self-heal on `.failed` with capped
  backoff, without disturbing healthy peer connections.
- Add a conservative watchdog that rebuilds the transport when no peer has been
  connected for a growing interval (60s → 15m). It only ever fires on a Mac that
  has synced at least once, so a solo Mac never churns its transport.
- Cancel outbound dials stuck in `.preparing` past 15s; their key previously
  stayed reserved forever, so that peer could never be re-dialed.
- Refresh the menu-bar status on network change, so the Wi-Fi allowlist verdict
  no longer stays stale until the next copy.
- Manual Reconnect no longer clears cached peer clipboard metadata, so the
  picker doesn't blank while peers re-announce.
- Internal: tests no longer read the installed app's Keychain items. A
  `DEBUG`-only `TANDEMCLIP_KEYCHAIN_SERVICE` override lets the test binary use
  its own service, so `SecItemCopyMatching` can't block the suite on an ACL
  prompt. Release builds always use the real service.

## [0.22.9] — 2026-07-19
- Add a Reconnect menu-bar item that rebuilds the LAN transport to re-establish
  peer sync after sleep/wake, a Wi-Fi roam, or a long idle period.
- Harden the public release path: opt-in Sentry with the DSN kept out of the
  tree, plus a pre-push guard.

## [0.22.8] — 2026-07-03
- TandemClip is now open source under the MIT license.
- Internal: split the clipboard picker into focused files, reworded comments to
  be self-contained, and added CI, SECURITY.md, CONTRIBUTING.md, and this
  changelog. No user-facing behavior change.

## [0.22.7] — 2026-07-03
- First-run Welcome window: onboarding for new users.
- Smart-title mark: crisp accent sparkles glyph instead of an inline emoji.
- Gate automatic AI toggles on the master "Enable AI text cleanup" switch; log
  smart-title failures.
- Fix drag-out: dragging a clip no longer moves the window instead of lifting it.
- Help: light/dark contrast check; help buttons in the picker and hover preview;
  deep-links from Settings names to the exact spot in Help.
- Full marketing landing page with auto-publish on release.

## [0.21.0] — Help & design system
- Two-pane left-nav Help center with expanded articles, a "What's New"
  release-history panel, on-device semantic search, and a resizable window.
- Shared design token set (`Theme.swift`) with a design doc and a drift lint in
  `Scripts/check-release.sh`; Help, Settings, and the picker fully tokenized.

## [0.19.0] — AI auth modes
- Bring-your-own-LLM parity: multiple model presets, API-key / no-auth / OAuth
  auth modes (including ChatGPT sign-in), fallback endpoint, and a
  degraded-reroute latch.

## [0.18.0]
- Light / Dark / System appearance theme.

## [0.17.0] — Intelligence bundle
- Secret guard: likely credentials are held until released.
- Pinned clips: up to 20 permanent, synced, restart-proof clips.
- Chunked transfers: clips up to 100 MB travel as signed 1 MB slices.
- "Send to TandemClip" in every app's Services menu (text + files).
- On-device semantic search over history + OCR'd screenshot text.
- AI on clips: Summarize, opt-in smart titles + incoming-clip translation, and
  retrieval-grounded "Ask your clipboard".
- Quick actions from the hover preview (open link / email / phone / save).

## [0.16.0]
- AirDrop a clip from the picker to nearby Apple devices.

## [0.15.0]
- Terracotta design tokens: accent, motion, honest toasts.
- Accept file-promise drags (Outlook/Mail emails, Photos, browser images).

## [0.14.0]
- Folders sync as `.zip` archives; help overhaul; honest toasts.

## [0.13.0]
- Auto-apply incoming clips (hands-free receive even in Manual mode).
- Settings: bullet-list descriptions on every section.

## [0.12.0]
- QuickLook hover previews (PDF pages, Office docs, video frames, durations).
- Picker fixes: transient-unless-pinned dismissal; compose draft discard.

## [0.10.0]
- AI text cleanup: bring-your-own-LLM compose area (OpenAI-compatible endpoints,
  local Ollama/LM Studio), editable tone presets, HTTPS enforced off-LAN.
- Settings sidebar navigation.

## [0.9.0]
- Menu reorganization; privacy hold (✋) and pin (📌).

## [0.8.0]
- Configurable received-files storage limit with oldest-first eviction.

## [0.5.0]–[0.7.0]
- Picker organization: per-Mac collapsible groups with per-type sub-sections,
  count badges, and per-item sizes.

## [0.4.0]
- Delete-everywhere: removing a clip erases it across every Mac (signed, relayed).

## [0.3.0]
- Drop-to-share (drag files onto the picker) and always-capture to history.

## [0.2.0] — Security hardening
- Pairing code moved to the Keychain; PSK derived with PBKDF2-HMAC-SHA256
  (600k iterations).
- Cryptographic device identity (Curve25519 signatures) with a key-pinned
  trusted-device allowlist and real revocation.
- Received files revealed in Finder only (never auto-opened); transport
  connection/size/rate/replay limits.

## [0.1.x]
- Initial LAN clipboard sync over PSK-TLS (Bonjour discovery): text, rich text,
  images, and files by content; in-app pairing-code entry with live re-key;
  clipboard history.

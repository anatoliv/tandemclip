# TandemClip — Security Audit

**Scope:** Swift source in `Sources/tandemclip`, packaging, appcast, web serving.
**Threat model:** attacker on the same LAN; a rogue/revoked device that once knew the pairing code; a network MITM against the update channel; another local user on the same Mac.
**Latest review:** 2026-07-03, against v0.17.1 (build 36).

## Summary

The design is sound and, as of v0.2.0, the previously-identified gaps are closed. Every peer connection is TLS 1.3 with an external pre-shared key; device identity is now cryptographically bound (Curve25519 signatures) rather than self-asserted; the pairing code is stretched with a high-work-factor KDF and gated by a strength floor; received files are never auto-opened; and the transport has connection, size, rate, and replay limits. Auto-updates remain gated by Sparkle EdDSA signatures over an HTTPS feed, and the release pipeline refuses to publish an unverifiable or version-regressed appcast.

This document records the audit history and the final state of each finding.

## Finding status (v0.2.0)

| # | Severity | Issue | Status |
|---|----------|-------|--------|
| 1 | High | Weak/custom pairing codes brute-forceable | **Fixed** — 12-char + alphabet + diversity floor; weak stored codes rotated |
| A | Med | Fast KDF, brute-force work factor | **Fixed** — PBKDF2-HMAC-SHA256 600k iters, cached |
| 2 | High | Auto-opening pulled files → RCE | **Fixed** — received files reveal-in-Finder only, never opened |
| 3 | High | Allowlist spoofable / no real revocation | **Fixed** — Curve25519 signed identity, key-pinned trust |
| 4 | Med | No receive-side size/rate/DoS limits | **Fixed** — dynamic frame cap, max 16 conns, rate limit, cache eviction |
| 5 | Med | Secret exposed via env/bootstrap file | **Fixed** — file owner/perms/type validated; code masked; concealed-type copy |
| 6 | Low | Keychain items backup-eligible | **Fixed** — `…AfterFirstUnlockThisDeviceOnly` on add + update |
| 7 | Low | Verbose logs to world-readable /tmp | **Fixed** — LaunchAgent no longer redirects to /tmp; unified logging |
| 8 | Low | Update origin serves plain HTTP | **Mitigated** — HSTS + hardening headers added; TLS at proxy; signatures gate updates |
| 9 | Info | Concealed-type filtering best-effort | **Improved** — changeCount re-check closes TOCTOU; convention limit remains |
| R | Low | Signed-clip replay across mesh | **Fixed** — seen-signature cache within a 10-min window |

## What the fixes do

**Pairing code & KDF (1, A).** `isAcceptablePairingCode` requires ≥12 symbols from the unambiguous alphabet and ≥6 distinct characters, enforced for custom codes, env vars, and the bootstrap file; a stored weak code is rotated to a fresh generated one. `derivePSK` uses PBKDF2-HMAC-SHA256 at 600,000 iterations (via CommonCrypto, no new dependency), adding a real work factor to any offline attack on a captured handshake. The result is cached and recomputed only when the code changes. *This derivation is intentionally incompatible with pre-0.2.0 builds — every Mac must be updated for a fleet to reconnect.*

**Cryptographic device identity (3).** Each install holds a Curve25519 signing keypair (`DeviceIdentity`, stored in the Keychain). Every message carries the public key and a signature over its canonical form; receivers drop messages whose signature doesn't verify, and the allowlist pins `deviceID → publicKey`. A rogue device cannot spoof a trusted ID, and removing a device from the allowlist actually revokes it (a new keypair won't match). Disabling the allowlist also disables identity verification — documented as intended.

**Received files (2).** `openFiles` now only reveals files in Finder; it never calls `NSWorkspace.open` on peer-supplied bytes. Files are still written `0600` in a `0700` per-clip directory, atomically, and quarantined.

**Transport limits (4, R).** Frame cap is `min(48MB, max(2MB, maxClipBytes*2))` — scaled to the local clip-size preference so a PSK-holding peer can't force oversized allocations, since the whole frame is buffered before the rate check runs (worst-case transient inbound memory is `maxConnections * maxFrameBytes`). At most 16 connections and 32 discovered endpoints; `.request` is limited to 1/sec/device; inbound frames are rate-limited per **connection** (un-spoofable, unlike a self-asserted deviceID) at 200 frames / 10 s, and a connection exceeding it is dropped; the on-disk received cache is capped at 200 MB with oldest-first eviction. Signed clips are checked against a seen-signature cache (10-min window) to block replays, plus a timestamp-freshness bound on mirror clips; genuine re-copies carry fresh timestamps and are unaffected.

**Local surface (5, 6, 7).** The bootstrap file is accepted only if it's a regular file owned by the user with no group/other permissions; the pairing code is masked in the menu and copied via a concealed-type pasteboard item so it won't sync or be captured. Keychain items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (set on both add and update). The LaunchAgent no longer writes logs to `/tmp`.

**Update channel (8).** Sparkle EdDSA signatures over the HTTPS feed remain the primary control (an HTTP-MITM cannot push a malicious build). The nginx config now emits HSTS and hardening headers; the release script blocks publishing without a verified, non-regressed appcast (`release.sh`, `check-release.sh`). Confirm the fronting proxy enforces HTTPS + redirect.

## v0.2.1 review pass (build 13)

A re-audit against the current tree found no open Critical/High. Applied hardening:

- **Inbound frame cap scaled to the clip-size setting.** Was a flat 48 MB regardless of `maxClipBytes`; now `min(48MB, max(2MB, maxClipBytes*2))`, so worst-case buffered inbound memory (`maxConnections * maxFrameBytes`) tracks the local preference instead of a fixed 768 MB. Legitimate clips are unaffected (`Transport.receiveHeader`).
- **Received-filename edge cases.** `lastPathComponent` already defused `../` traversal and absolute paths; now the pathological basenames `""`, `"."`, and `".."` (which would resolve the destination to the clip dir or its parent) are mapped to a `file` fallback (`ClipboardWatcher.writeReceivedFiles`).
- **Doc accuracy.** Corrected two drifted claims: the frame cap (was described as dynamic while the code was flat) and the inbound rate limit (200 frames/10s per **connection**, not "40/10s per device"). README's KDF description was also wrong (said HKDF; the code is PBKDF2-HMAC-SHA256, 600k iters) and is now fixed.
- **Allowlist-off default surfaced.** The trusted-device allowlist (hence per-device revocation) is off by default — the PSK is the trust boundary. This is now documented in-app (Settings → Security footer) and in the README so users know how to revoke a device that once knew the code.
- **Password-manager guarantee stated honestly.** Help + README now spell out that concealed-type filtering is best-effort and depends on the source app setting the marker.

## v0.14.0 review pass (build 31)

The surface grew substantially between v0.2.1 and v0.14.0. A re-audit of every
new mechanism found two issues, both fixed in this pass; no open Critical/High.

**Delete-everywhere (`delete` message, v0.4.0).** Signed and hash-keyed;
requires a valid identity signature (unsigned deletes are dropped), a fresh
timestamp (10-min bound), and passes the seen-signature cache — which also
stops relay loops. A replayed or forged delete cannot remove a re-copied clip.
Deletes are honored from trusted peers even while receiving is disabled and
are deliberately exempt from privacy hold: they reveal only the hash of
content the peer already holds, and privacy is when removals matter most.
Older builds fail to decode the unknown type and skip the frame.

**Relay-echo handling (v0.4.0).** Frames carrying our own deviceID on an
*identified* peer connection are now skipped instead of cancelling the
connection (gossip echoes used to churn every link on every clip). Genuine
self-dials — first frame, no identity learned — are still cancelled. Skipped
frames are never processed, so a peer replaying our messages at us gains
nothing beyond wasted bytes.

**Privacy hold (v0.9.0).** While on: no clip broadcasts, no pull serving, no
drop-shares, announces carry identity only, and — FIXED in this pass — AI
cleanup calls are refused too (previously compose could send typed text to
the AI endpoint during a hold, contradicting "nothing leaves this Mac").
Receiving and local capture continue; deletes still propagate (above).

**Auto-apply incoming (v0.13.0).** Manual-mode auto-apply carries Mirror's
full receive guards: allowlist trust, signature verification, the 10-min
freshness bound, seen-signature dedup, and hash dedup — and never relays, so
a Manual Mac cannot be turned into a sender.

**AI text cleanup (v0.10.0, bring-your-own-LLM).** Off by default; text goes
directly from this Mac to a user-chosen endpoint (no proxy). API keys live in
the Keychain (`AfterFirstUnlockThisDeviceOnly`), never in preferences. Input
capped at 20k chars/run. FIXED in this pass: plain `http` endpoints are now
rejected unless the host is loopback, `.local`, or RFC-1918 — a typo'd
`http://api.…` would have sent the Bearer key and clipboard text across the
internet in the clear. The same rule gates the fallback endpoint and the
settings probe. Model output lands only in the compose editor for review —
nothing auto-pastes or auto-sends; the §§CHANGES§§ changelog is parsed as
plain text and stripped from what can reach the clipboard.

**QuickLook previews (v0.12.0).** Peer-supplied file bytes are staged to the
per-user temp dir just long enough for `QLThumbnailGenerator` — which parses
out-of-process in sandboxed extensions — then deleted; results (and misses)
are cached by content hash. Parsing attacker-supplied files is confined to
Apple's sandboxed preview stack; we never parse them in-process.

**Folder zipping (v0.14.0).** Copied folders travel as zip archives built by
`/usr/bin/ditto` (absolute path, argv passed directly — no shell
interpretation of folder names). A pre-flight size walk rejects folders whose
uncompressed contents exceed 4× the clip cap before any CPU is spent, and the
resulting archive must itself fit the cap.

**Storage / eviction (v0.8.0).** The received-files cache cap is
user-configurable (10 MB–1 GB); eviction is oldest-first and never removes
the clip whose URLs are currently on the pasteboard.

**Help search (v0.14.0).** Semantic matching runs entirely on-device
(NaturalLanguage embeddings) — help queries generate no network traffic.

## v0.17.0 review pass (build 35) — intelligence bundle

Twelve features landed at once; each new mechanism was reviewed as built.
No open Critical/High.

**Secret guard.** Local-only heuristics (known credential prefixes,
private-key blocks, JWTs, Luhn-valid card numbers, mod-97-valid IBANs, lone
high-entropy tokens) hold a text copy from broadcast, pull serving, AND
announce metadata until explicitly released from the menu; the next copy
clears the hold. Secret-held clips also never feed AI features or pin
broadcasts. Default on; heuristics are documented as best-effort.

**Pinned clips (`pin`/`unpin` messages).** Same guard stack as delete:
valid signature required, 10-min freshness, seen-signature replay cache
(doubles as relay-loop stop). `pin` is content delivery → gated on
receiveAllowed with a size cap (2× local clip limit) and a 20-pin cap;
`unpin` is data-minimizing → honored from any trusted peer. Pins persist in
a 0600 `pins.json`. Delete-everywhere unpins.

**Chunked transfers (`chunk` messages).** Slices are individually signed —
`chunkIndex`/`chunkTotal`/`chunkData` are inside the signed payload, so a
relay can't reorder or substitute bytes undetected (tested). Reassembly is
bounded: ≤256 slices, per-transfer byte cap of 3× the local clip limit,
120-second staleness sweep, replay-guarded slices. The reassembled inner
message then faces the ENTIRE normal receive path — its own signature,
trust, freshness, and dedup — so chunking adds transport capacity without
adding a trust shortcut.

**Services entry.** "Send to TandemClip" hands selected text/files to the
same explicit-share paths as drop-to-share (role/pause/privacy-hold/network
gates, size caps). Input arrives via the system Services pasteboard only on
user invocation; nothing is registered for automatic invocation.

**On-device intelligence (ClipIndex).** Embeddings (NaturalLanguage) and
OCR (Vision, in-process image decode of clips we already hold) never leave
the Mac. OCR output is treated as clip-derived text: searchable locally,
offered to quick actions, and included in Ask context only when the user
invokes AI.

**AI-on-receive (opt-in).** Smart titles and incoming-clip translation send
clip text to the user-configured endpoint automatically — both default OFF,
labeled as such in Settings, blocked during privacy hold, and never run on
secret-held clips. Ask/Summarize remain user-invoked. Model output is
sandboxed to display surfaces (labels are sanitized + length-capped so a
runaway response can't flood the picker; translations/answers render in the
preview/compose only).

**Drag-out / quick actions.** Save-to-Downloads reuses the received-file
basename defusing; staged drag-out files live in per-user temp with hourly
sweeps. "Open link" launches URLs from clip content on explicit click —
same trust as the user pasting the link themselves.

## Residual notes (accepted / low)

- **Concealed-type filtering (9)** still depends on source apps setting the nspasteboard markers; apps that don't will have secrets synced. Inherent to the convention. Now stated plainly in the Help window and README.
- **Env-var code injection** exposure to same-user processes remains for the headless/deploy path; it's strength-gated and documented.
- **Origin HTTP (8)** relies on the external proxy for TLS termination; the fronting proxy MUST enforce HTTPS + HTTP→HTTPS redirect for `SUFeedURL`. Update integrity is EdDSA-gated regardless, but plain HTTP would let a MITM withhold/stall security updates. Verify with `curl -sSI http://tandemclip.com/appcast.xml`.
- **Trusted-peer DoS.** A peer holding the PSK can still open up to 16 connections and push frames at the per-connection rate cap; bounded, and outside the "unpaired attacker" threat model.
- **AI endpoint trust.** With AI cleanup enabled, composed/cleaned text is disclosed to whatever endpoint the user configures — that third party is chosen and trusted by the user (local Ollama/LM Studio keeps it on-machine). TLS is enforced off-LAN; content policy at the provider is out of scope.
- **Secret-guard heuristics are best-effort.** v0.17.1 widened coverage — Stripe/HF/DO/Google-OAuth prefixes plus a `KEY=value` credential-in-text matcher (placeholder-aware) that catches env/config leaks like `DB_PASSWORD=…`. Still pattern/entropy-based: misses secrets phrased as prose (privacy hold ✋ is the catch-all there) and can false-positive on random-looking IDs (one click to release). Narrows, doesn't close, the unmarked-secret gap.
- **AI client wire path is now tested end to end** (v0.17.1): AIClientLiveTests drives the real `URLSession.bytes` path against a localhost HTTP server — SSE streaming, request format (method/auth/JSON body), HTTP-error mapping with server detail, and cross-endpoint fallback — the exact code every AI feature (summarize/titles/translate/ask/cleanup) runs.
- **Pins/chunks require current builds mesh-wide.** Older peers ignore the new message types safely but won't receive pins or >25 MB clips until updated.
- **QuickLook parser surface.** Preview generation feeds attacker-controllable bytes to Apple's QL extensions. They are sandboxed and out-of-process, and patched by macOS updates, but the parser surface itself is Apple's, not ours.

## What's done well (keep)

PSK-TLS 1.3 with a work-factor KDF; ~59-bit generated codes; signed cryptographic identity with real revocation; Sparkle EdDSA over HTTPS; concealed-type check before reading data; filename sanitization; fail-closed network guard; "unreadable Keychain ⇒ don't regenerate"; Sentry gated on a baked-in DSN with PII off; a `SecurityTests` suite covering code strength, KDF, identity signing, and allowlist binding.

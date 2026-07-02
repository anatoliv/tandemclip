# TandemClip — Security Audit

**Scope:** Swift source in `Sources/tandemclip`, packaging, appcast, web serving.
**Threat model:** attacker on the same LAN; a rogue/revoked device that once knew the pairing code; a network MITM against the update channel; another local user on the same Mac.
**Latest review:** 2026-07-02, against v0.2.0 (build 11).

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

**Transport limits (4, R).** Frame cap is `min(48MB, max(1.5MB, maxClipBytes*2))`; at most 16 connections and 32 discovered endpoints; `.request` is limited to 1/sec/device and all inbound to 40 messages/10s/device; the on-disk received cache is capped at 200 MB with oldest-first eviction. Signed clips are checked against a seen-signature cache (10-min window) to block replays; genuine re-copies carry fresh timestamps and are unaffected.

**Local surface (5, 6, 7).** The bootstrap file is accepted only if it's a regular file owned by the user with no group/other permissions; the pairing code is masked in the menu and copied via a concealed-type pasteboard item so it won't sync or be captured. Keychain items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (set on both add and update). The LaunchAgent no longer writes logs to `/tmp`.

**Update channel (8).** Sparkle EdDSA signatures over the HTTPS feed remain the primary control (an HTTP-MITM cannot push a malicious build). The nginx config now emits HSTS and hardening headers; the release script blocks publishing without a verified, non-regressed appcast (`release.sh`, `check-release.sh`). Confirm the fronting proxy enforces HTTPS + redirect.

## Residual notes (accepted / low)

- **Concealed-type filtering (9)** still depends on source apps setting the nspasteboard markers; apps that don't will have secrets synced. Inherent to the convention.
- **Env-var code injection** exposure to same-user processes remains for the headless/deploy path; it's strength-gated and documented.
- **Origin HTTP (8)** relies on the external proxy for TLS termination; verify HSTS/redirect there.

## What's done well (keep)

PSK-TLS 1.3 with a work-factor KDF; ~59-bit generated codes; signed cryptographic identity with real revocation; Sparkle EdDSA over HTTPS; concealed-type check before reading data; filename sanitization; fail-closed network guard; "unreadable Keychain ⇒ don't regenerate"; Sentry gated on a baked-in DSN with PII off; a `SecurityTests` suite covering code strength, KDF, identity signing, and allowlist binding.

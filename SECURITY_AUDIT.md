# TandemClip — Security Audit

**Scope:** Swift source in `Sources/tandemclip` (v0.1.8, build 9), packaging, appcast, web serving.
**Threat model:** attacker on the same LAN; a rogue/revoked device that once knew the pairing code; a network MITM against the update channel; another local user on the same Mac.
**Date:** 2026-07-02

## Summary

The core design is sound. Every peer connection is TLS 1.3 with an external pre-shared key derived from the pairing code via HKDF-SHA256, so "same Wi-Fi" genuinely is not enough to join — an attacker without the code fails the handshake and learns nothing. Auto-updates are gated by Sparkle EdDSA signatures over an HTTPS feed, which is the correct posture. Concealed clipboard types are checked before the data is read, and received filenames are stripped to their last path component (no path traversal).

The real weaknesses are: (1) **user-chosen pairing codes have no strength floor**, which undercuts the whole PSK gate; (2) **the "trusted-device allowlist" is not an enforceable security control** because device identity is self-asserted; and (3) **pulled files are auto-opened**, turning a trusted-but-malicious peer into code execution. Everything else is defense-in-depth hardening.

| # | Severity | Issue | Location |
|---|----------|-------|----------|
| 1 | High | Custom pairing codes have no minimum strength; captured handshake is brute-forceable offline | `Config.setPairingCode` :272; `SettingsWindow` |
| 2 | High | Auto-opening pulled files → remote code execution from a trusted peer | `SyncEngine.openFiles` :240, `applyIncomingClip` :203/:221 |
| 3 | High | Trusted-device allowlist is spoofable / not a real revocation mechanism | `SyncEngine.handleRemote` :169, `Transport.receiveBody` :271, `Config.isTrusted` :224 |
| 4 | Medium | No receive-side size/rate limit; 48 MB frames + unbounded on-disk file cache | `Transport.receiveHeader` :251, `ClipboardWatcher.writeReceivedFiles` :149 |
| 5 | Medium | Pairing secret exposed via env vars and a plaintext bootstrap file | `Config` :64–76, :300 |
| 6 | Low | Keychain item is backup-eligible (not `ThisDeviceOnly`) | `KeychainStore.set` :43 |
| 7 | Low | Verbose logs go to world-readable `/tmp` | `LaunchAgent/com.tandemclip.plist`, `Log` :24 |
| 8 | Low | Update origin nginx serves plain HTTP; no TLS/HSTS enforced in-repo | `web/nginx/default.conf` |
| 9 | Info | Concealed-type filtering depends on sender apps setting markers | `ClipboardWatcher.poll` :52 |

---

## Findings

### 1. Custom pairing codes have no strength requirement — High

Auto-generated codes are strong: `generateCode()` produces 12 symbols from a 31-char alphabet (~59 bits), well beyond offline brute-force (`Config.swift:279`). But `setPairingCode(_:)` (`Config.swift:272`) and the Settings UI accept **any** string — including `"test"`, `"1234"`, or a short word.

The PSK is derived directly from that string with a **fixed, public salt** (`"com.tandemclip.psk"`, `Config.swift:256–263`). An attacker on the LAN can capture the TLS 1.3 PSK handshake and run an **offline** dictionary/brute-force attack against it. With a weak custom code this is trivial; success means full decryption of all clipboard traffic *and* the ability to inject clips and join as a trusted device. The fixed salt also means no per-fleet work factor and allows precomputation against common codes.

**Fix.** Enforce a strength floor on custom codes (reject < ~40 bits of entropy / short or low-charset strings) in `setPairingCode` and validate in the Settings field before saving. Strengthen the KDF against brute-force by making derivation expensive — swap HKDF for a memory-hard PBKDF (scrypt/Argon2, or at minimum PBKDF2 with a high iteration count) for the PSK. Keep the salt fixed only if you must interoperate; better, mix in a fleet-specific value. Example floor:

```swift
static func isAcceptable(_ code: String) -> Bool {
    let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
    let distinct = Set(c).count
    return c.count >= 10 && distinct >= 6   // ~ tune to your alphabet
}
```

### 2. Auto-opening pulled files enables remote code execution — High

When the user pulls a peer's clipboard, `pullOpen` is set and the reply's files are passed to `openFiles()`, which calls `NSWorkspace.shared.open(url)` on each materialized file (`SyncEngine.swift:203, :221, :240–250`). The file content is entirely controlled by the peer. A trusted-but-malicious (or compromised) peer can send a `.command`, `.app`, `.terminal`, or a document crafted to exploit its default handler; the pull auto-opens it and it executes. `applyHistory` (`:272`) also opens files unconditionally.

Filenames are correctly sanitized to `lastPathComponent` (`ClipboardWatcher.swift:158`), so this is *not* path traversal — the risk is the auto-open itself.

**Fix.** Do not auto-open received files. Reveal in Finder instead of `open`, or gate opening behind an explicit user confirmation that shows the filename and type. At minimum, refuse to `open` executable/script/app bundle types and quarantine received files (set `com.apple.quarantine` via `NSFileManager`/xattr) so Gatekeeper vets them:

```swift
// prefer reveal over open for received content
NSWorkspace.shared.activateFileViewerSelecting(urls)
```

### 3. Trusted-device allowlist is not enforceable — High

`handleRemote` filters on `config.isTrusted(msg.deviceID)` (`SyncEngine.swift:169`), and the connection's identity is whatever the peer puts in `msg.deviceID` (`Transport.swift:271–272`). Device IDs are **self-asserted** and never bound to anything cryptographic. Any party that knows the pairing code can:

- set `deviceID` to a value on your allowlist and bypass it, or spoof another Mac's `deviceName` in the UI, and
- **defeat revocation**: a device you "untrust" in the allowlist can simply pick a new/allowed `deviceID` and reconnect. The only true revocation is rotating the pairing code.

The README markets the allowlist as a security feature, so this gap is material even though the pairing code is the primary gate.

**Fix.** Either (a) reframe the allowlist honestly in docs as a convenience filter, not a security boundary, or (b) make identity cryptographic: give each device a keypair, advertise the public key, pin it in the allowlist, and require the peer to prove possession (e.g., per-connection challenge signature) before `isTrusted` passes. Real revocation then means removing a pinned key, independent of the shared code.

### 4. No receive-side size or rate limiting — Medium

The frame cap is 48 MB (`Transport.swift:251`), far above the 5 MB `maxClipBytes`, and `maxBytes` is only enforced on the *send* side (`ClipboardWatcher`). Received clips are decoded in full, and file clips are written to `Application Support/TandemClip/Received/…` (`ClipboardWatcher.swift:149–162`) with **no total-disk cap** and purge only on manual "Clear history." A trusted peer (or one with the code) can push a stream of large/unique clips to exhaust memory and disk, amplified across the mesh by the mirror-mode relay (`SyncEngine.swift:207–210`).

**Fix.** Enforce `config.maxClipBytes` on receive (drop oversized clips before decode). Cap the on-disk Received cache (size + age eviction). Add simple per-peer rate limiting on inbound clips/relays.

### 5. Pairing secret exposed via env vars and plaintext file — Medium

The code can be supplied through `TANDEMCLIP_SET_CODE` / `TANDEMCLIP_PAIRING_CODE` (`Config.swift:72–76`) and via `pairing-code.txt` in Application Support (`consumeBootstrapCode` :300). Environment variables are readable by other same-user processes and can land in shell history/logs; the bootstrap file is a plaintext secret on disk (briefly) before deletion.

**Fix.** Keep these strictly for headless/deploy use and document the exposure. For the file path, create it with `0600` perms, overwrite before unlink, and prefer this over env vars. Consider disabling the env overrides in release builds.

### 6. Keychain item is backup-eligible — Low

`kSecAttrAccessibleAfterFirstUnlock` (`KeychainStore.swift:43`) is reasonable for a background agent, but without `…ThisDeviceOnly` the pairing secret is included in device backups. Use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so the shared secret never leaves the machine via backup. (It's correctly *not* `kSecAttrSynchronizable`, so it isn't iCloud-synced — good.)

### 7. Verbose logs go to world-readable /tmp — Low

The LaunchAgent writes stdout/stderr to `/tmp/tandemclip.out.log` / `.err.log`, which other local users can read. Verbose tracing logs peer names, sizes, and content *labels* (not clipboard contents, which is good), plus previews are never logged — but `/tmp` placement is still poor. Move logs under the user's `~/Library/Logs` and ensure previews/content are never logged even at verbose level.

### 8. Update origin serves plain HTTP in-repo — Low

`web/nginx/default.conf` listens on `:80` only; TLS is presumably terminated by the external `proxy_net`. Sparkle verifies EdDSA signatures on every enclosure (`Info.plist` `SUPublicEDKey`, :41), so an HTTP-MITM cannot push a malicious build — the residual risk is update *suppression* (freezing users on an old version) and, in theory, offering an older signed version. Confirm the fronting proxy enforces HTTPS + redirect + HSTS for `tandemclip.com`, and that Sparkle is configured to reject downgrades. This is the reason the update path is otherwise solid — keep it that way.

### 9. Concealed-type filtering is best-effort — Info

`poll()` correctly reads pasteboard *types* and skips the copy if any nspasteboard concealed/transient/auto-generated marker is present, before ever reading the data (`ClipboardWatcher.swift:52–54`) — the right approach. The limitation is inherent: a password manager or app that doesn't set these markers will have its secrets synced. Document this clearly, and consider an optional allow/deny by source app or a "pause on password fields" affordance. (There is also a benign TOCTOU between reading types and data; the `changeCount` guard makes it low-risk.)

---

## What's done well (keep)

- **PSK-TLS 1.3 with HKDF-derived key** — same-Wi-Fi is genuinely insufficient; wrong code fails the handshake (`Transport.swift:90–105`, `Config.swift:256`).
- **Auto-generated codes are ~59 bits** (`Config.swift:279`).
- **Sparkle EdDSA signatures over an HTTPS feed** — the correct update-security model (`Info.plist:37–42`).
- **Concealed-type check happens before reading data** (`ClipboardWatcher.swift:52`).
- **Filename sanitization** to `lastPathComponent` prevents path traversal (`ClipboardWatcher.swift:158`).
- **Fail-closed network guard** when the SSID can't be read (`NetworkGuard.swift:63–70`).
- **"Unreadable Keychain ⇒ don't regenerate"** avoids silently un-pairing and overwriting the real secret (`Config.swift:80–84`).
- **Sentry gated on a baked-in DSN, PII off** — self-built copies don't phone home (`CrashReporting.swift`).

## Suggested fix order

1. **#1** enforce pairing-code strength + harden the KDF (cheap, closes the biggest hole).
2. **#2** stop auto-opening received files (small change, removes an RCE path).
3. **#4** enforce receive-side size limits + cap the file cache.
4. **#3** decide: reframe the allowlist honestly, or make identity cryptographic.
5. **#5–#8** hardening.

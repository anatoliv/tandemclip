import Foundation
import CryptoKit
import CommonCrypto
import Darwin

/// How this Mac participates in sync.
enum SyncMode: String { case mirror, manual }

/// How much a peer reveals about its clipboard before you pull it.
enum PreviewLevel: String { case metadata, preview, names }

/// This Mac's role. `canSend` = broadcast/announce/answer pulls; `canReceive` =
/// apply remote clips / pull from peers.
enum Role: String {
    case sendReceive, receiveOnly, sendOnly
    var canSend: Bool { self != .receiveOnly }
    var canReceive: Bool { self != .sendOnly }
}

/// Persistent configuration, preferences, and the derived pairing secret.
///
/// The pairing code is the single shared secret across all your Macs. It is
/// stretched into a 256-bit pre-shared key (PSK) that authenticates and
/// encrypts every peer connection (PSK-TLS). Same code on every machine =
/// they trust each other; wrong code = the TLS handshake fails and the peer
/// is rejected. This is what makes "same Wi-Fi" NOT sufficient to join.
///
/// Everything here is stored in `UserDefaults` (domain `com.tandemclip`),
/// so any setting is also editable with `defaults write` or an MDM profile.
final class Config {
    /// Posted (on main) whenever any persisted setting changes.
    static let didChange = Notification.Name("TandemClipConfigDidChange")

    private let defaults = UserDefaults.standard

    let serviceType = "_tandemclip._tcp"

    /// Stable per-install identity, used for the trusted-device allowlist and
    /// for addressing pull requests to a specific Mac.
    let deviceID: String
    let identity = DeviceIdentity()

    private(set) var pairingCode: String
    private(set) var paused: Bool

    /// Derived PSK is expensive to compute (PBKDF2, 600k iters), so cache it and
    /// invalidate only when the pairing code changes. Guarded by `pskLock`
    /// because `psk` is read from the transport queue.
    private var pskCache: Data?
    private let pskLock = NSLock()

    init() {
        // Device ID — generated once, then stable.
        if let id = defaults.string(forKey: "deviceID"), !id.isEmpty {
            deviceID = id
        } else {
            let id = Config.newDeviceID()
            defaults.set(id, forKey: "deviceID")
            deviceID = id
        }

        // Pairing code resolution, in order:
        //  - TANDEMCLIP_SET_CODE  → persist this code into the Keychain (one-shot
        //    heal that re-pairs a Mac under the current app's ACL).
        //  - TANDEMCLIP_PAIRING_CODE → in-memory only (headless testing).
        //  - Keychain → the stored secret.
        //  - legacy UserDefaults → migrate into the Keychain.
        //  - nothing stored → generate a fresh code.
        // CRUCIAL: if the Keychain item EXISTS but can't be read (access denied
        // after a re-sign, or locked), we must NOT generate a new code — doing so
        // overwrites the real secret and silently un-pairs this Mac from the fleet.
        let env = ProcessInfo.processInfo.environment
        let bootstrapCode = Config.consumeBootstrapCode()
        if let fileCode = bootstrapCode, Config.isAcceptablePairingCode(fileCode) {
            // A one-shot code file dropped by deploy tooling. The app persists it
            // into the Keychain here (running in the GUI session, so the write
            // succeeds), then deletes the file. This heals a diverged fleet even
            // when the Keychain can't be written from a headless ssh session.
            KeychainStore.delete("pairingCode")
            let code = Config.normalizedPairingCode(fileCode)
            KeychainStore.set("pairingCode", code)
            pairingCode = code
        } else if let setCode = env["TANDEMCLIP_SET_CODE"], Config.isAcceptablePairingCode(setCode) {
            KeychainStore.delete("pairingCode")
            let code = Config.normalizedPairingCode(setCode)
            KeychainStore.set("pairingCode", code)
            pairingCode = code
        } else if let envCode = env["TANDEMCLIP_PAIRING_CODE"], Config.isAcceptablePairingCode(envCode) {
            pairingCode = Config.normalizedPairingCode(envCode)
        } else {
            if bootstrapCode != nil { Log.error("ignoring bootstrap pairing code because it is too weak") }
            if env["TANDEMCLIP_SET_CODE"] != nil { Log.error("ignoring TANDEMCLIP_SET_CODE because it is too weak") }
            if env["TANDEMCLIP_PAIRING_CODE"] != nil { Log.error("ignoring TANDEMCLIP_PAIRING_CODE because it is too weak") }
            let (kcCode, status) = KeychainStore.getStatus("pairingCode")
            if let code = kcCode {
                if Config.isAcceptablePairingCode(code) {
                    pairingCode = Config.normalizedPairingCode(code)
                } else {
                    Log.error("stored pairing code is too weak — rotating to a new generated code")
                    let code = Config.generateCode()
                    KeychainStore.set("pairingCode", code)
                    pairingCode = code
                }
            } else if status != errSecItemNotFound {
                Log.error("pairing code present but unreadable (status \(status)) — not regenerating (would un-pair this Mac)")
                pairingCode = ""
            } else if let legacy = defaults.string(forKey: "pairingCode"), Config.isAcceptablePairingCode(legacy) {
                let code = Config.normalizedPairingCode(legacy)
                KeychainStore.set("pairingCode", code)
                defaults.removeObject(forKey: "pairingCode")
                pairingCode = code
            } else {
                let code = Config.generateCode()
                KeychainStore.set("pairingCode", code)
                pairingCode = code
            }
        }

        // Migration: 0.2.0 changed trustedDevices values from display names to
        // base64 signing keys. Drop any legacy name-valued entries so a stale
        // name can never be treated as a pinned key — it would never match a real
        // key and would silently keep a device untrusted when the allowlist is on.
        if let trusted = defaults.dictionary(forKey: "trustedDevices") as? [String: String],
           trusted.contains(where: { !Config.looksLikeSigningKey($0.value) }) {
            defaults.set(trusted.filter { Config.looksLikeSigningKey($0.value) }, forKey: "trustedDevices")
        }

        // Runtime pause starts from the persisted preference.
        paused = defaults.bool(forKey: "paused") || defaults.bool(forKey: "startPaused")

        // Test/headless override for mode (mirrors the pairing-code override).
        if let m = ProcessInfo.processInfo.environment["TANDEMCLIP_MODE"],
           let parsed = SyncMode(rawValue: m) {
            defaults.set(parsed.rawValue, forKey: "mode")
        }
    }

    // MARK: - Identity

    /// Name shown to peers: the user override if set, else the system name.
    var deviceName: String {
        let override = defaults.string(forKey: "deviceDisplayName")
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty { return override }
        return Host.current().localizedName ?? "Mac"
    }

    var deviceDisplayName: String {
        get { defaults.string(forKey: "deviceDisplayName") ?? "" }
        set { set("deviceDisplayName", newValue) }
    }

    // MARK: - Sync preferences

    var mode: SyncMode {
        get { SyncMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .mirror }
        set { set("mode", newValue.rawValue) }
    }

    var previewLevel: PreviewLevel {
        get { PreviewLevel(rawValue: defaults.string(forKey: "previewLevel") ?? "") ?? .metadata }
        set { set("previewLevel", newValue.rawValue) }
    }

    var role: Role {
        get { Role(rawValue: defaults.string(forKey: "role") ?? "") ?? .sendReceive }
        set { set("role", newValue.rawValue) }
    }

    /// 5 MB default (fits screenshots). Stored value of 0/absent → default.
    var maxClipBytes: Int {
        get { let v = defaults.integer(forKey: "maxClipBytes"); return v > 0 ? v : 5_000_000 }
        set { set("maxClipBytes", newValue) }
    }

    /// Which content kinds to sync. Text is always on. Rich text + images
    /// default on; toggled in Settings. Stored as rawValue strings.
    var enabledKinds: Set<ClipKind> {
        get {
            guard let arr = defaults.array(forKey: "enabledKinds") as? [String] else {
                return [.text, .rtf, .png, .tiff]   // default: everything
            }
            var s: Set<ClipKind> = [.text]          // text is always enabled
            for r in arr { if let k = ClipKind(rawValue: r) { s.insert(k) } }
            return s
        }
        set { set("enabledKinds", newValue.map { $0.rawValue }) }
    }

    var syncRichText: Bool {
        get { enabledKinds.contains(.rtf) }
        set { var k = enabledKinds; if newValue { k.insert(.rtf) } else { k.remove(.rtf) }; enabledKinds = k }
    }
    var syncImages: Bool {
        get { enabledKinds.contains(.png) || enabledKinds.contains(.tiff) }
        set {
            var k = enabledKinds
            if newValue { k.insert(.png); k.insert(.tiff) } else { k.remove(.png); k.remove(.tiff) }
            enabledKinds = k
        }
    }

    /// Transfer copied files by content. Off by default (opt-in; larger payloads).
    var syncFiles: Bool {
        get { defaults.bool(forKey: "syncFiles") }
        set { set("syncFiles", newValue) }
    }

    /// Keep a recent-clipboard history (in-memory, this session only). On by
    /// default now that the picker is the primary way to grab clips.
    var historyEnabled: Bool {
        get { defaults.object(forKey: "historyEnabled") == nil ? true : defaults.bool(forKey: "historyEnabled") }
        set { set("historyEnabled", newValue) }
    }
    /// How many entries to retain.
    var historyLimit: Int {
        get { let v = defaults.integer(forKey: "historyLimit"); return v > 0 ? v : 50 }
        set { set("historyLimit", newValue) }
    }
    /// How many entries the picker shows at once.
    var pickerShowCount: Int {
        get { let v = defaults.integer(forKey: "pickerShowCount"); return v > 0 ? v : 12 }
        set { set("pickerShowCount", newValue) }
    }

    // MARK: - Startup & behavior

    var startPaused: Bool {
        get { defaults.bool(forKey: "startPaused") }
        set { set("startPaused", newValue) }
    }

    var launchAtLogin: Bool {
        // Defaults to true when never set.
        get { defaults.object(forKey: "launchAtLogin") == nil ? true : defaults.bool(forKey: "launchAtLogin") }
        set { set("launchAtLogin", newValue) }
    }

    var verboseLogging: Bool {
        get { defaults.bool(forKey: "verboseLogging") }
        set { set("verboseLogging", newValue) }
    }

    // MARK: - Security

    /// Opt-in device pinning. Off by default: the pairing-code-derived PSK is
    /// what makes "same Wi-Fi" insufficient, and turning this on with an empty
    /// trust list would silently drop every peer. Enabling it lets the user pin
    /// specific deviceID→publicKey pairs so trust is enforceable and revocable.
    var allowlistEnabled: Bool {
        get { defaults.bool(forKey: "allowlistEnabled") }
        set { set("allowlistEnabled", newValue) }
    }

    /// Device IDs permitted when the allowlist is on. Values are each device's
    /// signing public key, base64-encoded.
    var trustedDevices: [String: String] {
        get { defaults.dictionary(forKey: "trustedDevices") as? [String: String] ?? [:] }
        set { set("trustedDevices", newValue) }
    }

    func isTrusted(_ id: String, publicKey: String?) -> Bool {
        Self.isTrusted(allowlistEnabled: allowlistEnabled,
                       ownDeviceID: deviceID,
                       ownPublicKey: identity.publicKeyBase64,
                       trustedDevices: trustedDevices,
                       id: id,
                       publicKey: publicKey)
    }

    func setTrusted(_ id: String, publicKey: String?, trusted: Bool) {
        guard id != deviceID, let publicKey, !publicKey.isEmpty else { return }
        var t = trustedDevices
        if trusted { t[id] = publicKey } else { t[id] = nil }
        trustedDevices = t
    }

    var networkAllowlistEnabled: Bool {
        get { defaults.bool(forKey: "networkAllowlistEnabled") }
        set { set("networkAllowlistEnabled", newValue) }
    }

    var allowedSSIDs: [String] {
        get { defaults.stringArray(forKey: "allowedSSIDs") ?? [] }
        set { set("allowedSSIDs", newValue) }
    }

    /// When the Wi-Fi name can't be read (no Location permission / wired / VPN)
    /// and the network allowlist is on, sync PAUSES by default (fail-closed).
    /// Enable this to allow sync anyway. Default false = fail-closed.
    var wifiFailOpen: Bool {
        get { defaults.bool(forKey: "wifiFailOpen") }
        set { set("wifiFailOpen", newValue) }
    }

    // MARK: - Secret

    /// True when we hold a usable pairing secret. When the Keychain item exists
    /// but can't be read, `pairingCode` is left empty (rather than overwriting the
    /// real secret) — and `derivePSK` then falls back to a fixed, publicly-known
    /// key. Networking MUST NOT come up in that state, or any LAN peer could
    /// complete the PSK-TLS handshake. Callers gate `transport.start()` on this.
    var hasPairingSecret: Bool { !pairingCode.isEmpty }

    /// 256-bit pre-shared key derived from the pairing code with PBKDF2-HMAC-SHA256
    /// at a high iteration count, adding a brute-force work factor against a
    /// captured PSK-TLS handshake. All peers must run the same derivation (same
    /// code, salt, iterations) to connect. Cached; recomputed only when the code
    /// changes.
    var psk: Data {
        pskLock.lock(); defer { pskLock.unlock() }
        if let cached = pskCache { return cached }
        let key = Config.derivePSK(from: pairingCode)
        pskCache = key
        return key
    }

    /// PBKDF2-HMAC-SHA256, 600,000 iterations, 32-byte output. The salt is a
    /// fixed application constant: it must be identical fleet-wide (the only
    /// shared secret between Macs is the code itself), and the iteration count —
    /// not salt secrecy — is what provides the work factor.
    static func derivePSK(from code: String) -> Data {
        guard !code.isEmpty else { return Data(count: 32) }
        let pw = Array(code.utf8).map { CChar(bitPattern: $0) }
        let salt = Array("com.tandemclip.psk.v2".utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            pw, pw.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            600_000,
            &out, out.count)
        return status == Int32(kCCSuccess) ? Data(out) : Data(count: 32)
    }

    // MARK: - Mutators

    func setPaused(_ value: Bool) {
        paused = value
        set("paused", value)
    }

    func setPairingCode(_ code: String) {
        let normalized = Config.normalizedPairingCode(code)
        guard Config.isAcceptablePairingCode(normalized) else { return }
        pairingCode = normalized
        pskLock.lock(); pskCache = nil; pskLock.unlock()   // re-derive on next use
        KeychainStore.set("pairingCode", normalized)   // secret lives in the Keychain, not defaults
        DispatchQueue.main.async { NotificationCenter.default.post(name: Config.didChange, object: nil) }
    }

    /// Human-typeable code, e.g. "K7QM-3PXF". Excludes ambiguous chars (0/O, 1/I).
    static func generateCode() -> String {
        // 12 symbols from a 31-char alphabet ≈ 59 bits — well beyond offline
        // brute-force of a captured PSK-TLS handshake (the old 8 was ~40 bits).
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var out = ""
        for i in 0..<12 {
            if i == 4 || i == 8 { out.append("-") }
            out.append(alphabet.randomElement()!)
        }
        return out
    }

    static func normalizedPairingCode(_ code: String) -> String {
        let chars = code.uppercased().filter { $0.isLetter || $0.isNumber }
        guard chars.count > 4 else { return String(chars) }
        var out = ""
        for (i, ch) in chars.enumerated() {
            if i > 0 && i % 4 == 0 { out.append("-") }
            out.append(ch)
        }
        return out
    }

    static func isAcceptablePairingCode(_ code: String) -> Bool {
        let chars = code.uppercased().filter { $0.isLetter || $0.isNumber }
        let alphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        guard chars.count >= 12, chars.allSatisfy({ alphabet.contains($0) }) else { return false }
        // Reject low-diversity codes (e.g. "AAAA-AAAA-AAAA", "ABAB-ABAB-ABAB")
        // that pass the length/alphabet test but carry almost no entropy.
        return Set(chars).count >= 6
    }

    static func isTrusted(allowlistEnabled: Bool,
                          ownDeviceID: String,
                          ownPublicKey: String,
                          trustedDevices: [String: String],
                          id: String,
                          publicKey: String?) -> Bool {
        if !allowlistEnabled { return true }
        if id == ownDeviceID { return publicKey == nil || publicKey == ownPublicKey }
        guard let publicKey else { return false }
        return trustedDevices[id] == publicKey
    }

    /// A base64-encoded Curve25519 signing public key decodes to exactly 32
    /// bytes. Used to tell a real pinned key from a legacy display-name entry.
    static func looksLikeSigningKey(_ value: String) -> Bool {
        Data(base64Encoded: value)?.count == 32
    }

    static func newDeviceID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return "d-" + (0..<12).map { _ in String(alphabet.randomElement()!) }.joined()
    }

    /// One-shot heal: read (and delete) a pairing code dropped as a plain file at
    /// <AppSupport>/TandemClip/pairing-code.txt. Lets deploy tooling set the code
    /// over ssh (file write) while the Keychain write happens here in the GUI
    /// session. Returns nil if the file is absent/empty.
    static func consumeBootstrapCode() -> String? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let url = support.appendingPathComponent("TandemClip/pairing-code.txt")
        guard secureBootstrapFile(url) else { return nil }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        try? fm.removeItem(at: url)
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? nil : code
    }

    private static func secureBootstrapFile(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            Log.error("ignoring pairing-code.txt because it is not a regular file")
            return false
        }
        guard st.st_uid == getuid() else {
            Log.error("ignoring pairing-code.txt because it is not owned by this user")
            return false
        }
        guard (st.st_mode & 0o077) == 0 else {
            Log.error("ignoring pairing-code.txt because group/other permissions are too broad")
            return false
        }
        return true
    }

    private func set(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
        DispatchQueue.main.async { NotificationCenter.default.post(name: Config.didChange, object: nil) }
    }
}

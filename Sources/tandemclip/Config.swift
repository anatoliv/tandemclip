import Foundation
import CryptoKit

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

    private(set) var pairingCode: String
    private(set) var paused: Bool

    init() {
        // Device ID — generated once, then stable.
        if let id = defaults.string(forKey: "deviceID"), !id.isEmpty {
            deviceID = id
        } else {
            let id = Config.newDeviceID()
            defaults.set(id, forKey: "deviceID")
            deviceID = id
        }

        // Pairing code: env override (in-memory only, for headless testing) >
        // Keychain > migrate legacy UserDefaults code into the Keychain > new.
        if let envCode = ProcessInfo.processInfo.environment["TANDEMCLIP_PAIRING_CODE"],
           !envCode.isEmpty {
            pairingCode = envCode
        } else if let code = KeychainStore.get("pairingCode"), !code.isEmpty {
            pairingCode = code
        } else if let legacy = defaults.string(forKey: "pairingCode"), !legacy.isEmpty {
            // One-time migration off plaintext UserDefaults into the Keychain.
            KeychainStore.set("pairingCode", legacy)
            defaults.removeObject(forKey: "pairingCode")
            pairingCode = legacy
        } else {
            let code = Config.generateCode()
            KeychainStore.set("pairingCode", code)
            pairingCode = code
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

    var allowlistEnabled: Bool {
        get { defaults.bool(forKey: "allowlistEnabled") }
        set { set("allowlistEnabled", newValue) }
    }

    /// Device IDs permitted when the allowlist is on. Format: "id|displayName".
    var trustedDevices: [String: String] {
        get { defaults.dictionary(forKey: "trustedDevices") as? [String: String] ?? [:] }
        set { set("trustedDevices", newValue) }
    }

    func isTrusted(_ id: String) -> Bool {
        !allowlistEnabled || id == deviceID || trustedDevices[id] != nil
    }

    func setTrusted(_ id: String, name: String, trusted: Bool) {
        var t = trustedDevices
        if trusted { t[id] = name } else { t[id] = nil }
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

    // MARK: - Secret

    /// 256-bit pre-shared key derived from the pairing code via HKDF-SHA256
    /// (fixed salt + info). All peers must run the same derivation to connect.
    var psk: Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(pairingCode.utf8)),
            salt: Data("com.tandemclip.psk".utf8),
            info: Data("tandemclip-psk-v1".utf8),
            outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: - Mutators

    func setPaused(_ value: Bool) {
        paused = value
        set("paused", value)
    }

    func setPairingCode(_ code: String) {
        pairingCode = code
        KeychainStore.set("pairingCode", code)   // secret lives in the Keychain, not defaults
        DispatchQueue.main.async { NotificationCenter.default.post(name: Config.didChange, object: nil) }
    }

    /// Human-typeable code, e.g. "K7QM-3PXF". Excludes ambiguous chars (0/O, 1/I).
    static func generateCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var out = ""
        for i in 0..<8 {
            if i == 4 { out.append("-") }
            out.append(alphabet.randomElement()!)
        }
        return out
    }

    static func newDeviceID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return "d-" + (0..<12).map { _ in String(alphabet.randomElement()!) }.joined()
    }

    private func set(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
        DispatchQueue.main.async { NotificationCenter.default.post(name: Config.didChange, object: nil) }
    }
}

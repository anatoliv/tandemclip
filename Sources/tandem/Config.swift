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
/// Everything here is stored in `UserDefaults` (domain `net.amnesia.tandem`),
/// so any setting is also editable with `defaults write` or an MDM profile.
final class Config {
    /// Posted (on main) whenever any persisted setting changes.
    static let didChange = Notification.Name("TandemConfigDidChange")

    private let defaults = UserDefaults.standard

    let serviceType = "_tandem._tcp"

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

        if let envCode = ProcessInfo.processInfo.environment["TANDEM_PAIRING_CODE"],
           !envCode.isEmpty {
            // Env override wins — useful for headless testing where the bare
            // binary's UserDefaults domain doesn't match `net.amnesia.tandem`.
            defaults.set(envCode, forKey: "pairingCode")
            pairingCode = envCode
        } else if let code = defaults.string(forKey: "pairingCode"), !code.isEmpty {
            pairingCode = code
        } else {
            let code = Config.generateCode()
            defaults.set(code, forKey: "pairingCode")
            pairingCode = code
        }

        // Runtime pause starts from the persisted preference.
        paused = defaults.bool(forKey: "paused") || defaults.bool(forKey: "startPaused")
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

    /// 1 MB default. Stored value of 0/absent falls back to the default.
    var maxClipBytes: Int {
        get { let v = defaults.integer(forKey: "maxClipBytes"); return v > 0 ? v : 1_000_000 }
        set { set("maxClipBytes", newValue) }
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

    /// 256-bit key derived from the pairing code. (SHA-256 is a stand-in for a
    /// proper KDF; swap in HKDF with a fixed salt when you harden this.)
    var psk: Data {
        Data(SHA256.hash(data: Data(pairingCode.utf8)))
    }

    // MARK: - Mutators

    func setPaused(_ value: Bool) {
        paused = value
        set("paused", value)
    }

    func setPairingCode(_ code: String) {
        pairingCode = code
        set("pairingCode", code)
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

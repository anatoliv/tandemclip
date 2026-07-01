import Foundation
import CryptoKit

/// Persistent configuration + derived pairing secret.
///
/// The pairing code is the single shared secret across all your Macs. It is
/// stretched into a 256-bit pre-shared key (PSK) that authenticates and
/// encrypts every peer connection (PSK-TLS). Same code on every machine =
/// they trust each other; wrong code = the TLS handshake fails and the peer
/// is rejected. This is what makes "same Wi-Fi" NOT sufficient to join.
final class Config {
    private let defaults = UserDefaults.standard

    let deviceName: String
    let serviceType = "_clipboardd._tcp"

    private(set) var pairingCode: String
    private(set) var paused: Bool
    var maxClipBytes: Int = 1_000_000   // 1 MB cap for the text MVP

    init() {
        deviceName = Host.current().localizedName ?? "Mac"

        if let code = defaults.string(forKey: "pairingCode"), !code.isEmpty {
            pairingCode = code
        } else {
            let code = Config.generateCode()
            defaults.set(code, forKey: "pairingCode")
            pairingCode = code
        }
        paused = defaults.bool(forKey: "paused")
    }

    /// 256-bit key derived from the pairing code. (SHA-256 is a stand-in for a
    /// proper KDF; swap in HKDF with a fixed salt when you harden this.)
    var psk: Data {
        Data(SHA256.hash(data: Data(pairingCode.utf8)))
    }

    func setPaused(_ value: Bool) {
        paused = value
        defaults.set(value, forKey: "paused")
    }

    func setPairingCode(_ code: String) {
        pairingCode = code
        defaults.set(code, forKey: "pairingCode")
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
}

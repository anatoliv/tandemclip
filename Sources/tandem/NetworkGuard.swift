import Foundation
import CoreWLAN

/// "Sync only on these Wi-Fi networks." Auto-pauses when the current SSID isn't
/// in the allowlist.
///
/// Caveat: on macOS 14+, reading the SSID requires Location authorization. If we
/// can't read it (no permission, or wired/VPN), we **fail open** (allow) and log
/// a warning rather than silently killing sync — the Settings window surfaces
/// that Location is needed to actually enforce this.
enum NetworkGuard {
    static func currentSSID() -> String? {
        CWWiFiClient.shared().interface()?.ssid()
    }

    static func syncAllowed(_ config: Config) -> Bool {
        guard config.networkAllowlistEnabled, !config.allowedSSIDs.isEmpty else { return true }
        guard let ssid = currentSSID(), !ssid.isEmpty else {
            Log.trace("net", "SSID unreadable (wired/VPN or missing Location permission) — allowing")
            return true
        }
        let ok = config.allowedSSIDs.contains(ssid)
        if !ok { Log.trace("net", "SSID \(ssid) not in allowlist — sync paused") }
        return ok
    }
}

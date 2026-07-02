import Foundation
import CoreWLAN
import CoreLocation

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

    /// Whether we currently hold Location authorization (required to read SSID).
    static var locationAuthorized: Bool {
        switch LocationAuthorizer.shared.status {
        case .authorizedAlways, .authorized: return true
        default: return false
        }
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

/// Requests + tracks Location authorization so CoreWLAN can return the SSID.
/// macOS gates `ssid()` behind Location; without this the name reads as nil and
/// "Add current network" silently does nothing.
final class LocationAuthorizer: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAuthorizer()
    private let manager = CLLocationManager()
    private var pending: [(Bool) -> Void] = []

    override init() {
        super.init()
        manager.delegate = self
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }

    /// Ensure we're authorized, prompting once if undetermined, then call back on
    /// the main thread with the result.
    func ensureAuthorized(_ completion: @escaping (Bool) -> Void) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorized:
            completion(true)
        case .notDetermined:
            pending.append(completion)
            manager.requestWhenInUseAuthorization()
        default:
            completion(false)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        let ok = manager.authorizationStatus == .authorizedAlways
            || manager.authorizationStatus == .authorized
        let waiters = pending; pending = []
        DispatchQueue.main.async { waiters.forEach { $0(ok) } }
    }
}

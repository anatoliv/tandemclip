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
        // Primary: CoreWLAN (needs Location auth on modern macOS).
        if let s = CWWiFiClient.shared().interface()?.ssid(), !s.isEmpty { return s }
        // Fallback that does NOT need Location: parse `ipconfig getsummary`.
        return ssidFromIpconfig()
    }

    /// Read the Wi-Fi SSID via `/usr/sbin/ipconfig getsummary <iface>` — works
    /// without Location permission (which CoreWLAN's ssid() requires and which
    /// re-signing the app resets). Returns nil off Wi-Fi.
    private static func ssidFromIpconfig() -> String? {
        let iface = CWWiFiClient.shared().interface()?.interfaceName ?? "en0"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        proc.arguments = ["getsummary", iface]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("SSID : ") {
                let name = String(line.dropFirst("SSID : ".count)).trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : name
            }
        }
        return nil
    }

    /// Whether we currently hold Location authorization (required to read SSID).
    static var locationAuthorized: Bool {
        switch LocationAuthorizer.shared.status {
        case .authorizedAlways, .authorized: return true
        default: return false
        }
    }

    static func syncAllowed(_ config: Config) -> Bool {
        guard config.networkAllowlistEnabled else { return true }
        // Allowlist on but nothing selected → restricted to an empty set of
        // networks → never sync (until the user adds one).
        guard !config.allowedSSIDs.isEmpty else {
            Log.trace("net", "network allowlist on but empty — pausing")
            return false
        }
        guard let ssid = currentSSID(), !ssid.isEmpty else {
            // Can't verify the network. Fail CLOSED (pause) so an unverifiable
            // network isn't silently trusted — unless the user opted to allow.
            if config.wifiFailOpen {
                Log.trace("net", "SSID unreadable — allowing (fail-open enabled)")
                return true
            }
            Log.trace("net", "SSID unreadable — pausing (fail-closed)")
            return false
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

import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService (registers the app itself as a login item).
/// This replaces the external `~/Library/LaunchAgents` plist so the in-app
/// toggle actually controls startup. Requires the app to run from its installed
/// location (e.g. /Applications) and be signed.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            switch (enabled, SMAppService.mainApp.status) {
            case (true, let s) where s != .enabled:
                try SMAppService.mainApp.register()
                Log.trace("startup", "registered login item")
            case (false, .enabled):
                try SMAppService.mainApp.unregister()
                Log.trace("startup", "unregistered login item")
            default:
                break   // already in desired state
            }
        } catch {
            Log.error("launch-at-login set(\(enabled)) failed: \(error)")
        }
    }
}

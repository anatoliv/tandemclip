import AppKit
import Sparkle

/// Thin wrapper over Sparkle's standard updater. Reads SUFeedURL / SUPublicEDKey
/// from the bundle Info.plist. Only meaningful when running as an installed
/// .app (a bare/headless binary has no bundle feed).
final class Updater {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    /// User-initiated "Check for Updates…". As an accessory app we're never
    /// active, so without an explicit activate Sparkle's window opens behind
    /// the frontmost app and the check looks like a no-op (a second click only
    /// raised the already-running session). Scheduled background checks don't
    /// go through here and stay non-intrusive.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

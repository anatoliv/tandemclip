import Foundation
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

    /// User-initiated "Check for Updates…".
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

import AppKit

/// Owns the app's long-lived objects and wires the status UI to the engine.
final class AppController: NSObject, NSApplicationDelegate {
    private let config = Config()
    private lazy var engine = SyncEngine(config: config)
    private var menuBar: MenuBarController?
    private lazy var settingsWindow = SettingsWindowController(config: config, engine: engine)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Reflect persisted settings that live outside Config's own storage.
        Log.verbose = Log.verbose || config.verboseLogging
        LaunchAtLogin.set(config.launchAtLogin)
        engine.networkAllowed = { [config] in NetworkGuard.syncAllowed(config) }

        let menuBar = MenuBarController(config: config, engine: engine) { [weak self] in
            self?.settingsWindow.show()
        }
        self.menuBar = menuBar
        engine.onStatusChange = { [weak menuBar] in menuBar?.refresh() }

        // Settings changed from the window → refresh the menu/icon.
        NotificationCenter.default.addObserver(forName: Config.didChange, object: nil, queue: .main) { [weak menuBar] _ in
            menuBar?.refresh()
        }

        engine.start()
    }
}

import AppKit

/// Owns the app's long-lived objects and wires the status UI to the engine.
final class AppController: NSObject, NSApplicationDelegate {
    private let config = Config()
    private lazy var engine = SyncEngine(config: config)
    private var menuBar: MenuBarController?
    private lazy var settingsWindow = SettingsWindowController(config: config, engine: engine)
    private lazy var picker = ClipboardPickerController(config: config, engine: engine)
    private var hotKey: GlobalHotKey?
    private let updater = Updater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        CrashReporting.start()   // gated on Info.plist SentryDSN; off if absent
        if ProcessInfo.processInfo.environment["TANDEMCLIP_TEST_SENTRY"] != nil {
            CrashReporting.captureTest()
        }

        // Reflect persisted settings that live outside Config's own storage.
        Log.verbose = Log.verbose || config.verboseLogging
        LaunchAtLogin.set(config.launchAtLogin)
        engine.networkAllowed = { [config] in NetworkGuard.syncAllowed(config) }

        // Global hotkey (⇧⌘V) to summon the clipboard picker.
        hotKey = GlobalHotKey { [weak self] in self?.picker.toggle() }

        // Test hook: auto-open the picker after launch (env-gated, inert in prod).
        if ProcessInfo.processInfo.environment["TANDEMCLIP_TEST_PICKER"] != nil {
            Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in self?.picker.show() }
        }

        let menuBar = MenuBarController(config: config, engine: engine,
            onOpenSettings: { [weak self] in self?.settingsWindow.show() },
            onCheckForUpdates: { [weak self] in self?.updater.checkForUpdates() },
            onOpenPicker: { [weak self] in self?.picker.show() })
        self.menuBar = menuBar
        engine.onStatusChange = { [weak self, weak menuBar] in
            menuBar?.refresh()
            self?.picker.refreshIfVisible()   // live-update the picker if open
        }

        // Settings changed from the window → refresh the menu/icon.
        NotificationCenter.default.addObserver(forName: Config.didChange, object: nil, queue: .main) { [weak menuBar] _ in
            menuBar?.refresh()
        }

        engine.start()
    }
}

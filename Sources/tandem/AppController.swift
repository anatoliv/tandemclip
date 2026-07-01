import AppKit

/// Owns the app's long-lived objects and wires the status UI to the engine.
final class AppController: NSObject, NSApplicationDelegate {
    private let config = Config()
    private lazy var engine = SyncEngine(config: config)
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menuBar = MenuBarController(config: config, engine: engine)
        self.menuBar = menuBar
        engine.onStatusChange = { [weak menuBar] in menuBar?.refresh() }
        engine.start()
    }
}

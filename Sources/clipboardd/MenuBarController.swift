import AppKit

/// Menu-bar status + controls: pause/resume, peer count, last sync source, and
/// the pairing code (needed to onboard another Mac).
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let config: Config
    private let engine: SyncEngine

    init(config: Config, engine: SyncEngine) {
        self.config = config
        self.engine = engine
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "📋"
        rebuildMenu()
    }

    func refresh() { rebuildMenu() }

    private func rebuildMenu() {
        let menu = NSMenu()

        let state = config.paused ? "Paused" : "Syncing"
        menu.addItem(disabled: "clipboardd — \(state)")
        menu.addItem(disabled: "Peers connected: \(engine.peerCount)")
        if let src = engine.lastSyncSource {
            menu.addItem(disabled: "Last sync: \(src)")
        }

        menu.addItem(.separator())
        menu.addItem(action: config.paused ? "Resume" : "Pause",
                     selector: #selector(togglePause), target: self)

        menu.addItem(.separator())
        menu.addItem(disabled: "Pairing code: \(config.pairingCode)")
        menu.addItem(action: "Copy pairing code",
                     selector: #selector(copyPairing), target: self)

        menu.addItem(.separator())
        menu.addItem(action: "Quit clipboardd", selector: #selector(quit),
                     target: self, key: "q")

        statusItem.menu = menu
    }

    @objc private func togglePause() {
        config.setPaused(!config.paused)
        rebuildMenu()
    }

    @objc private func copyPairing() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(config.pairingCode, forType: .string)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private extension NSMenu {
    func addItem(disabled title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }

    func addItem(action title: String, selector: Selector, target: AnyObject, key: String = "") {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = target
        addItem(item)
    }
}

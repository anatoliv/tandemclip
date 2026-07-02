import AppKit

/// Menu-bar status + controls: mode, per-peer pull (Manual), pause, settings,
/// and the pairing code.
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let config: Config
    private let engine: SyncEngine
    private let onOpenSettings: () -> Void
    private let onCheckForUpdates: () -> Void

    init(config: Config, engine: SyncEngine,
         onOpenSettings: @escaping () -> Void,
         onCheckForUpdates: @escaping () -> Void) {
        self.config = config
        self.engine = engine
        self.onOpenSettings = onOpenSettings
        self.onCheckForUpdates = onCheckForUpdates
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        applyStatusIcon()
        rebuildMenu()
    }

    func refresh() {
        applyStatusIcon()
        rebuildMenu()
    }

    /// Monochrome template glyph that adapts to light/dark menu bars. Shows the
    /// sync arrows normally and a pause glyph when paused.
    private func applyStatusIcon() {
        guard let button = statusItem.button else { return }
        let symbol = config.paused ? "pause.circle" : "arrow.triangle.2.circlepath"
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TandemClip")?
            .withSymbolConfiguration(symbolConfig) {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
        } else {
            button.image = nil
            button.title = "T"
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let modeName = config.mode == .mirror ? "Mirror" : "Manual"
        let state = config.paused ? "Paused" : modeName
        menu.addItem(disabled: "TandemClip — \(state)")
        menu.addItem(disabled: "Peers connected: \(engine.peerCount)")
        if let src = engine.lastSyncSource {
            menu.addItem(disabled: "Last sync: \(src)")
        }

        // Manual mode: pull a specific peer's clipboard.
        if config.mode == .manual {
            menu.addItem(.separator())
            menu.addItem(disabled: "Get clipboard from:")
            let peers = engine.sortedPeers()
            if peers.isEmpty {
                menu.addItem(disabled: "   (no peers)")
            } else {
                for peer in peers {
                    let item = NSMenuItem(title: "   " + peerLabel(peer.clip),
                                          action: #selector(pullFromPeer(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = peer.id
                    item.isEnabled = peer.clip.online && config.role.canReceive
                    menu.addItem(item)
                }
            }
        }

        // Mode toggle.
        menu.addItem(.separator())
        let modeMenu = NSMenu()
        addCheck(modeMenu, "Mirror (auto-sync)", on: config.mode == .mirror, sel: #selector(setMirror))
        addCheck(modeMenu, "Manual (pull on demand)", on: config.mode == .manual, sel: #selector(setManual))
        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        menu.addItem(action: config.paused ? "Resume" : "Pause",
                     selector: #selector(togglePause), target: self)

        menu.addItem(.separator())
        menu.addItem(action: "Settings…", selector: #selector(openSettings), target: self, key: ",")
        menu.addItem(action: "Check for Updates…", selector: #selector(checkForUpdates), target: self)
        menu.addItem(disabled: "Pairing code: \(config.pairingCode)")
        menu.addItem(action: "Copy pairing code", selector: #selector(copyPairing), target: self)

        menu.addItem(.separator())
        menu.addItem(action: "Quit TandemClip", selector: #selector(quit), target: self, key: "q")

        statusItem.menu = menu
    }

    private func peerLabel(_ clip: PeerClip) -> String {
        var parts: [String] = [clip.name]
        if !clip.online { parts.append("(offline)") }
        else if let pv = clip.preview, !pv.isEmpty { parts.append("“\(pv.prefix(24))”") }
        else {
            var meta: [String] = []
            if let k = clip.kindLabel, k != "text" { meta.append(k) }   // "image" / "rich text"
            if let s = clip.size { meta.append(ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file)) }
            if clip.timestamp > 0 { meta.append(age(clip.timestamp)) }
            if !meta.isEmpty { parts.append(meta.joined(separator: " · ")) }
        }
        return parts.joined(separator: "   ")
    }

    private func age(_ ts: Double) -> String {
        let s = Int(Date().timeIntervalSince1970 - ts)
        if s < 5 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    private func addCheck(_ menu: NSMenu, _ title: String, on: Bool, sel: Selector) {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        menu.addItem(item)
    }

    // MARK: - Actions

    @objc private func pullFromPeer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        engine.pull(from: id)
    }

    @objc private func setMirror() { config.mode = .mirror; refresh() }
    @objc private func setManual() { config.mode = .manual; refresh() }

    @objc private func togglePause() {
        config.setPaused(!config.paused)
        refresh()
    }

    @objc private func openSettings() { onOpenSettings() }

    @objc private func checkForUpdates() { onCheckForUpdates() }

    @objc private func copyPairing() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(config.pairingCode, forType: .string)
    }

    @objc private func quit() { NSApp.terminate(nil) }
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

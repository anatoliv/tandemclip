import AppKit

/// Menu-bar status + controls: mode, per-peer pull (Manual), pause, settings,
/// and the pairing code.
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let config: Config
    private let engine: SyncEngine
    private let onOpenSettings: () -> Void
    private let onCheckForUpdates: () -> Void
    private let onOpenPicker: () -> Void
    private let onOpenAbout: () -> Void
    private let onOpenHelp: () -> Void

    init(config: Config, engine: SyncEngine,
         onOpenSettings: @escaping () -> Void,
         onCheckForUpdates: @escaping () -> Void,
         onOpenPicker: @escaping () -> Void,
         onOpenAbout: @escaping () -> Void,
         onOpenHelp: @escaping () -> Void) {
        self.config = config
        self.engine = engine
        self.onOpenSettings = onOpenSettings
        self.onCheckForUpdates = onCheckForUpdates
        self.onOpenPicker = onOpenPicker
        self.onOpenAbout = onOpenAbout
        self.onOpenHelp = onOpenHelp
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
        let symbol = config.paused ? "pause.circle"
            : config.privacyHold ? "hand.raised.circle"
            : "arrow.triangle.2.circlepath"
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

    private static func sizeString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // Status: two lines — state + peer count, and what's on the clipboard
        // (with where it came from).
        let modeName = config.mode == .mirror ? "Mirror" : "Manual"
        var state = config.paused ? "Paused" : modeName
        if config.privacyHold { state += " · Private" }
        let n = engine.peerCount
        menu.addItem(disabled: "TandemClip — \(state) · \(n) Mac\(n == 1 ? "" : "s")")
        if let info = engine.currentClipInfo {
            let origin = engine.clipOrigin.map { "from \($0), \(age(engine.localTimestamp))" } ?? "local"
            menu.addItem(disabled: "Clipboard: \(info.kind) · \(Self.sizeString(info.bytes)) · \(origin)")
        } else {
            menu.addItem(disabled: "Clipboard: empty")
        }
        if config.networkAllowlistEnabled, !NetworkGuard.syncAllowed(config) {
            menu.addItem(disabled: "⚠︎ Paused — Wi-Fi not allowed/verified")
        }
        if let held = engine.heldSecret {
            menu.addItem(disabled: "⚠︎ Copy held — looks like a \(held.reason)")
            menu.addItem(action: "Send Held Clip Anyway", selector: #selector(releaseHeldSecret), target: self)
        }

        // Manual mode: pull a specific peer's clipboard.
        if config.mode == .manual {
            menu.addItem(.separator())
            menu.addItem(disabled: "Get Clipboard From:")
            // syncablePeers() is empty (and shows no previews) when receiving
            // isn't allowed — so a paused / disallowed-network / send-only Mac
            // reveals no peer clipboard metadata here.
            let peers = engine.syncablePeers()
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

        // Clipboard picker (⇧⌘V) — the visual browser.
        menu.addItem(.separator())
        let pick = NSMenuItem(title: "Clipboard Picker…", action: #selector(openPicker), keyEquivalent: "v")
        pick.keyEquivalentModifierMask = [.command, .shift]
        pick.target = self
        menu.addItem(pick)

        // Mode toggle — the current mode reads in the item title without
        // opening the submenu. (History browsing lives in the picker; the old
        // History submenu was a worse duplicate of it.)
        menu.addItem(.separator())
        let modeMenu = NSMenu()
        addCheck(modeMenu, "Mirror (auto-sync)", on: config.mode == .mirror, sel: #selector(setMirror))
        addCheck(modeMenu, "Manual (pull on demand)", on: config.mode == .manual, sel: #selector(setManual))
        let modeItem = NSMenuItem(title: "Mode: \(modeName)", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        menu.addItem(action: config.paused ? "Resume" : "Pause",
                     selector: #selector(togglePause), target: self)

        menu.addItem(.separator())
        menu.addItem(action: "Settings…", selector: #selector(openSettings), target: self, key: ",")
        menu.addItem(action: "Copy Pairing Code", selector: #selector(copyPairing), target: self)

        menu.addItem(.separator())
        menu.addItem(action: "About TandemClip", selector: #selector(openAbout), target: self)
        menu.addItem(action: "Check for Updates…", selector: #selector(checkForUpdates), target: self)
        menu.addItem(action: "Help — Keyboard & Tips", selector: #selector(openHelp), target: self)

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

    @objc private func releaseHeldSecret() { engine.releaseHeldSecret() }

    @objc private func togglePause() {
        config.setPaused(!config.paused)
        refresh()
    }

    @objc private func openPicker() { onOpenPicker() }

    @objc private func openSettings() { onOpenSettings() }

    @objc private func openAbout() { onOpenAbout() }

    @objc private func openHelp() { onOpenHelp() }

    @objc private func checkForUpdates() { onCheckForUpdates() }

    @objc private func copyPairing() {
        SecretPasteboard.copy(config.pairingCode)
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

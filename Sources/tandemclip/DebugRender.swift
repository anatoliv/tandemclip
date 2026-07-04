#if DEBUG
import AppKit
import SwiftUI

/// Debug-only offscreen renderer for the clipboard picker — the app's densest,
/// most layout-sensitive surface, whose models pull in the whole sync engine
/// so it can't be rendered from a lightweight standalone harness.
///
/// Gated behind BOTH `#if DEBUG` and the `TANDEMCLIP_RENDER_PICKER` env var, so
/// it never exists in a release build and never runs unless explicitly asked.
/// This is the verification mechanism referenced in `docs/design/DESIGN_SYSTEM.md`
/// §9 — it lets the picker's compact type be checked against real seeded state
/// (list / hover preview / compose) before any change ships.
///
/// Usage (debug binary):
///   TANDEMCLIP_RENDER_PICKER=list \
///   TANDEMCLIP_RENDER_OUT=/tmp/picker-list.png \
///   .build/debug/tandemclip
enum DebugRender {
    /// Returns true (and never actually returns — the app terminates after the
    /// screenshot) when the env var requested a render; false otherwise so the
    /// normal app launch proceeds.
    /// Strong reference to the app delegate: `NSApplication.delegate` is weak,
    /// so a freshly-created delegate would be deallocated immediately without
    /// this. Held for the process lifetime of a render run.
    private static var renderDelegate: NSApplicationDelegate?

    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        let out = env["TANDEMCLIP_RENDER_OUT"] ?? "/tmp/tandemclip-render.png"
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        // Unbundled debug binaries have no app icon, so surfaces that show
        // `NSApp.applicationIconImage` (Welcome, About) render a generic one.
        // Point TANDEMCLIP_RENDER_ICON at Packaging/AppIcon.icns for a faithful shot.
        if let iconPath = env["TANDEMCLIP_RENDER_ICON"], let icon = NSImage(contentsOfFile: iconPath) {
            app.applicationIconImage = icon
        }
        if let state = env["TANDEMCLIP_RENDER_PICKER"] {
            renderDelegate = PickerRenderDelegate(state: state, out: out)
        } else if env["TANDEMCLIP_RENDER_SETTINGS"] != nil {
            renderDelegate = SettingsRenderDelegate(tab: env["TANDEMCLIP_RENDER_SETTINGS"] ?? "sync", out: out)
        } else if env["TANDEMCLIP_RENDER_WELCOME"] != nil {
            renderDelegate = WelcomeRenderDelegate(out: out)
        } else {
            return false
        }
        app.delegate = renderDelegate
        app.run()
        return true
    }
}

/// Renders a Settings tab (env `TANDEMCLIP_RENDER_SETTINGS=general|sync|content|ai|security`)
/// so the footer "learn more" links can be verified. Constructs a bare
/// Config + SyncEngine but never calls `engine.start()`, so nothing binds a
/// socket.
private final class SettingsRenderDelegate: NSObject, NSApplicationDelegate {
    let tab: String
    let out: String
    var window: NSWindow!
    init(tab: String, out: String) { self.tab = tab; self.out = out }

    func applicationDidFinishLaunching(_: Notification) {
        let config = Config()
        let engine = SyncEngine(config: config)
        let model = SettingsModel(config: config, engine: engine)
        UserDefaults.standard.set(tab.capitalized, forKey: "settingsSelectedTab")
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            let p = Process()
            p.launchPath = "/usr/sbin/screencapture"
            p.arguments = ["-l", String(window.windowNumber), "-o", "-x", out]
            try? p.run(); p.waitUntilExit()
            NSApp.terminate(nil)
        }
    }
}

/// Renders the first-run Welcome window (env `TANDEMCLIP_RENDER_WELCOME=1`) so
/// the onboarding layout/copy can be checked without a fresh install.
private final class WelcomeRenderDelegate: NSObject, NSApplicationDelegate {
    let out: String
    var window: NSWindow!
    init(out: String) { self.out = out }

    func applicationDidFinishLaunching(_: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 660),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.contentView = NSHostingView(rootView: WelcomeView(
            openSettings: { _ in }, openHelp: {}, dismiss: {}))
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            let p = Process()
            p.launchPath = "/usr/sbin/screencapture"
            p.arguments = ["-l", String(window.windowNumber), "-o", "-x", out]
            try? p.run(); p.waitUntilExit()
            NSApp.terminate(nil)
        }
    }
}

private final class PickerRenderDelegate: NSObject, NSApplicationDelegate {
    let state: String
    let out: String
    var window: NSWindow!

    init(state: String, out: String) {
        self.state = state
        self.out = out
    }

    func applicationDidFinishLaunching(_: Notification) {
        let model = PickerModel(
            onPickHistory: { _ in }, onPullPeer: { _ in }, onDropFiles: { _ in },
            onDeleteHistory: { _ in }, onClose: {}
        )
        model.aiConfigured = true
        model.airDropAvailable = true

        let items = Self.sampleItems()
        model.reload(history: items, peers: Self.samplePeers(), showCount: 20,
                     clipUsage: "6 clips · 2.3 MB")
        model.pinnedItems = [items[0]]

        switch state {
        case "compose":
            model.composing = true
            model.composeText = "hey just confirming the meeting moved to 3pm tomorrow does that still work for you"
        case "hover":
            model.beginHover(items[1])   // long text — exercises the preview card
        default:
            break
        }

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.contentView = NSHostingView(rootView: PickerView(model: model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Wait past the 0.35s hover delay before shooting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            let p = Process()
            p.launchPath = "/usr/sbin/screencapture"
            p.arguments = ["-l", String(window.windowNumber), "-o", "-x", out]
            try? p.run()
            p.waitUntilExit()
            NSApp.terminate(nil)
        }
    }

    private static func sampleItems() -> [HistoryItem] {
        func text(_ s: String, _ src: String, ago: Double) -> HistoryItem {
            HistoryItem(
                snapshot: ClipSnapshot(parts: [.text: Data(s.utf8)]),
                hash: UUID().uuidString,
                timestamp: Date().timeIntervalSince1970 - ago,
                label: s, source: src
            )
        }
        var items: [HistoryItem] = [
            text(HistoryItem.smartTitlePrefix + "Quarterly Revenue Summary", "MacBook Pro", ago: 15),
            text("https://tandemclip.com/download", "MacBook Pro", ago: 30),
            text("The quarterly numbers are in — revenue up 18% QoQ, churn down to 2.1%. Full breakdown in the deck; the headline is we beat plan on every line except EMEA, which slipped on the FX move.",
                 "MacBook Pro", ago: 120),
            text("docker run --rm -it -v $PWD:/app node:20 bash", "Mac mini", ago: 300),
        ]
        let img = NSImage(size: NSSize(width: 64, height: 64))
        img.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        img.unlockFocus()
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            items.append(HistoryItem(
                snapshot: ClipSnapshot(parts: [.png: png]),
                hash: UUID().uuidString,
                timestamp: Date().timeIntervalSince1970 - 200,
                label: "Screenshot", source: "Mac mini"
            ))
        }
        items.append(HistoryItem(
            snapshot: ClipSnapshot(parts: [:], files: [ClipFile(name: "Q3-report.pdf", data: Data(count: 240_000))]),
            hash: UUID().uuidString,
            timestamp: Date().timeIntervalSince1970 - 400,
            label: "Q3-report.pdf", source: "MacBook Pro"
        ))
        return items
    }

    private static func samplePeers() -> [(id: String, clip: PeerClip)] {
        [("peer1", PeerClip(name: "Mac mini", online: true,
                            timestamp: Date().timeIntervalSince1970 - 60,
                            size: 4200, preview: "meeting notes"))]
    }
}
#endif

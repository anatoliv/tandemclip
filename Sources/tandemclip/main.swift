import AppKit

#if DEBUG
// Debug-only, env-gated offscreen picker renderer for design verification.
// No-op unless TANDEMCLIP_RENDER_PICKER is set; compiled out of release builds.
if DebugRender.runIfRequested() { exit(0) }
#endif

if CommandLine.arguments.contains("--no-menubar") {
    // Headless mode: no NSApplication / menu bar / WindowServer dependency.
    // The clipboard watcher and network transport run on the main RunLoop.
    // Intended for testing over SSH (drive/observe via pbcopy/pbpaste).
    let config = Config()
    let engine = SyncEngine(config: config)
    engine.start()
    Log.trace("app", "running headless as \"\(config.deviceName)\"")

    // Test hook: in Manual mode, auto-pull from the first online peer after a
    // delay (lets the Manual pull path be exercised without a GUI menu click).
    if ProcessInfo.processInfo.environment["TANDEMCLIP_TEST_PULL"] != nil {
        Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { _ in
            if let peer = engine.sortedPeers().first(where: { $0.clip.online }) {
                Log.trace("app", "test-pull from \(peer.clip.name)")
                engine.pull(from: peer.id)
            }
        }
    }

    // Test hook: re-key the transport at runtime (same code) to prove peers
    // reconnect after a pairing-code change without a relaunch.
    if ProcessInfo.processInfo.environment["TANDEMCLIP_TEST_REKEY"] != nil {
        Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { _ in
            Log.trace("app", "test-rekey: reloadPairing")
            engine.reloadPairing()
        }
    }

    // Test hook: fake a wake-from-sleep to exercise the automatic transport
    // rebuild without actually sleeping the Mac.
    if ProcessInfo.processInfo.environment["TANDEMCLIP_TEST_WAKE"] != nil {
        Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { _ in
            Log.trace("app", "test-wake: posting didWakeNotification")
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.didWakeNotification, object: nil)
        }
    }

    RunLoop.main.run()
} else {
    // Run as an "accessory" app: no Dock icon, menu-bar only. This is the
    // runtime equivalent of LSUIElement, so it works even when launched as a
    // bare binary during development (before packaging into a signed .app).
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let controller = AppController()
    app.delegate = controller
    app.run()
}

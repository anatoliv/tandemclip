import AppKit

if CommandLine.arguments.contains("--no-menubar") {
    // Headless mode: no NSApplication / menu bar / WindowServer dependency.
    // The clipboard watcher and network transport run on the main RunLoop.
    // Intended for testing over SSH (drive/observe via pbcopy/pbpaste).
    let config = Config()
    let engine = SyncEngine(config: config)
    engine.start()
    Log.trace("app", "running headless as \"\(config.deviceName)\"")
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

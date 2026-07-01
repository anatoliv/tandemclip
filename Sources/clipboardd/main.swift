import AppKit

// Run as an "accessory" app: no Dock icon, menu-bar only. This is the runtime
// equivalent of LSUIElement, so it works even when launched as a bare binary
// during development (before it's packaged into a signed .app bundle).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = AppController()
app.delegate = controller
app.run()

import AppKit

/// macOS Services entry: "Send to TandemClip" appears in every app's
/// application menu ▸ Services (and the right-click Services submenu) for
/// selected text and files — share-from-anywhere without an app-extension
/// target. Registered via NSServices in Info.plist; routed here through
/// NSApp.servicesProvider.
final class ServicesProvider: NSObject {
    private let engine: SyncEngine

    init(engine: SyncEngine) {
        self.engine = engine
    }

    /// NSMessage "sendToTandemClip" → this selector (Services appends
    /// `:userData:error:`).
    @objc func sendToTandemClip(_ pboard: NSPasteboard, userData: String,
                                error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = ((pboard.readObjects(forClasses: [NSURL.self],
                     options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? [])
                     .filter { $0.isFileURL }
        if !urls.isEmpty {
            let outcome = engine.shareFiles(urls)
            Log.trace("services", "shared \(outcome.sent) file(s) to \(outcome.peers) peer(s)")
            return
        }
        if let text = pboard.string(forType: .string), !text.isEmpty {
            let ok = engine.shareText(text)
            Log.trace("services", "shared text: \(ok)")
            return
        }
        error.pointee = "Nothing shareable in the selection." as NSString
    }
}

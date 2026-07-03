import AppKit

/// "AirDrop this clip": materialize a history item into shareable file URLs
/// and hand them to the system AirDrop sheet (NSSharingService — the one
/// public AirDrop API). This is the escape hatch to devices outside the mesh:
/// iPhones, iPads, Macs that will never hold the pairing code.
enum AirDropPayload {
    /// Write the item's content into `dir` and return the URLs to share.
    /// Text becomes a .txt named after the clip; bitmap clips become .png;
    /// file clips keep their (sanitized) names.
    static func urls(for item: HistoryItem, in dir: URL) -> [URL] {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []

        if !item.snapshot.files.isEmpty {
            for f in item.snapshot.files {
                // Same basename defusing as writeReceivedFiles: names are
                // peer-controlled.
                let base = (f.name as NSString).lastPathComponent
                let safe = (base.isEmpty || base == "." || base == "..") ? "file" : base
                let dest = dir.appendingPathComponent(safe)
                if (try? f.data.write(to: dest, options: [.atomic])) != nil { urls.append(dest) }
            }
        } else if let png = item.snapshot.parts[.png] ?? item.snapshot.parts[.tiff] {
            let dest = dir.appendingPathComponent("\(fileStem(for: item)).png")
            let data: Data
            if item.snapshot.parts[.png] != nil { data = png }
            else if let rep = NSBitmapImageRep(data: png),
                    let converted = rep.representation(using: .png, properties: [:]) { data = converted }
            else { data = png }
            if (try? data.write(to: dest, options: [.atomic])) != nil { urls.append(dest) }
        } else if let text = item.snapshot.plainText, !text.isEmpty {
            let dest = dir.appendingPathComponent("\(fileStem(for: item)).txt")
            if (try? Data(text.utf8).write(to: dest, options: [.atomic])) != nil { urls.append(dest) }
        }
        return urls
    }

    /// A short, filesystem-safe stem from the clip's label ("deploy checklist"
    /// → "deploy checklist", junk → "Clip").
    static func fileStem(for item: HistoryItem) -> String {
        let raw = item.label.prefix(40)
        let cleaned = raw.map { c -> Character in
            (c.isLetter || c.isNumber || c == " " || c == "-" || c == "_") ? c : " "
        }
        let stem = String(cleaned).trimmingCharacters(in: .whitespaces)
        return stem.isEmpty ? "Clip" : stem
    }
}

/// Stages clips for drag-out of the picker (files land wherever the user
/// drops them; Finder copies from our staging dir). Staging can't be cleaned
/// on drop (no callback), so old dirs are swept on each new drag.
enum DragOutStager {
    private static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tandemclip-dragout", isDirectory: true)

    /// An NSItemProvider for dragging this clip out. Plain text drags as a
    /// string; anything with bytes drags as file URL(s) — a single file
    /// directly, multi-file clips as a folder named after the clip.
    static func provider(for item: HistoryItem) -> NSItemProvider {
        if item.snapshot.files.isEmpty, item.imageData == nil,
           let text = item.snapshot.plainText {
            return NSItemProvider(object: text as NSString)
        }
        sweep()
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let urls = AirDropPayload.urls(for: item, in: dir)
        if urls.count == 1, let provider = NSItemProvider(contentsOf: urls[0]) { return provider }
        if urls.count > 1 {
            // Wrap the batch in a folder named after the clip so the drop
            // lands as one tidy unit.
            let named = dir.appendingPathComponent(AirDropPayload.fileStem(for: item), isDirectory: true)
            try? FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
            for u in urls {
                try? FileManager.default.moveItem(
                    at: u, to: named.appendingPathComponent(u.lastPathComponent))
            }
            if let provider = NSItemProvider(contentsOf: named) { return provider }
        }
        return NSItemProvider()
    }

    private static func sweep() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for url in entries {
            let age = -(((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast).timeIntervalSinceNow)
            if age > 3600 { try? fm.removeItem(at: url) }
        }
    }
}

/// Owns the AirDrop share lifecycle: stages files, keeps them alive until the
/// transfer finishes (deleting too early aborts the send), then cleans up.
/// Stale staging dirs (a cancelled sheet fires no delegate callback) are swept
/// on each new share.
final class AirDropper: NSObject, NSSharingServiceDelegate {
    static let shared = AirDropper()

    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tandemclip-airdrop", isDirectory: true)
    private var pending: [ObjectIdentifier: URL] = [:]   // service → staging dir

    static var isAvailable: Bool {
        NSSharingService(named: .sendViaAirDrop) != nil
    }

    /// Present the system AirDrop sheet for this clip. Returns false when
    /// there was nothing shareable (or AirDrop is unavailable).
    @discardableResult
    func share(_ item: HistoryItem) -> Bool {
        guard let service = NSSharingService(named: .sendViaAirDrop) else { return false }
        sweepStale()
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let urls = AirDropPayload.urls(for: item, in: dir)
        guard !urls.isEmpty, service.canPerform(withItems: urls) else {
            try? FileManager.default.removeItem(at: dir)
            return false
        }
        service.delegate = self
        pending[ObjectIdentifier(service)] = dir
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
        return true
    }

    func sharingService(_ service: NSSharingService, didShareItems items: [Any]) {
        cleanup(service)
    }

    func sharingService(_ service: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        cleanup(service)
    }

    private func cleanup(_ service: NSSharingService) {
        if let dir = pending.removeValue(forKey: ObjectIdentifier(service)) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Remove staging dirs older than an hour — covers cancelled sheets, which
    /// fire neither delegate callback.
    private func sweepStale() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let live = Set(pending.values.map(\.path))
        for url in entries where !live.contains(url.path) {
            let age = -(((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast).timeIntervalSinceNow)
            if age > 3600 { try? fm.removeItem(at: url) }
        }
    }
}

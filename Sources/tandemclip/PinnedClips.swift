import Foundation

/// A pinned clip: a small set of clips that survive restarts and sync across
/// Macs (addresses, signatures, license keys). Content travels in wire form
/// so pins round-trip the same way clips do.
struct PinnedClip: Codable, Equatable, Identifiable {
    let hash: String
    let label: String
    let source: String
    let timestamp: Double
    let parts: [ClipPart]
    let files: [ClipFileWire]

    var id: String { hash }

    var snapshot: ClipSnapshot? { ClipSnapshot(wire: parts, wireFiles: files) }

    /// Display form for the picker (rides the same row UI as history).
    var historyItem: HistoryItem? {
        guard let snap = snapshot else { return nil }
        return HistoryItem(snapshot: snap, hash: hash, timestamp: timestamp,
                           label: label, source: source)
    }
}

/// Disk persistence for pins: one JSON file, 0600, atomic writes.
enum PinStore {
    static let maxPins = 20

    static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support.appendingPathComponent("TandemClip", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pins.json")
    }

    static func load(from url: URL = fileURL) -> [PinnedClip] {
        guard let data = try? Data(contentsOf: url),
              let pins = try? JSONDecoder().decode([PinnedClip].self, from: data) else { return [] }
        return pins
    }

    static func save(_ pins: [PinnedClip], to url: URL = fileURL) {
        guard let data = try? JSONEncoder().encode(pins) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

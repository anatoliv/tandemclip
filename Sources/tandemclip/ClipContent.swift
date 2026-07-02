import AppKit
import CryptoKit

/// A clipboard representation we're willing to sync. A single copy usually has
/// several (e.g. rich text also carries plain text); we capture and transmit all
/// enabled ones so pasting keeps full fidelity on the far side.
enum ClipKind: String, Codable, CaseIterable {
    case text, rtf, png, tiff

    var pasteboardType: NSPasteboard.PasteboardType {
        switch self {
        case .text: return .string
        case .rtf:  return .rtf
        case .png:  return .png
        case .tiff: return .tiff
        }
    }

    /// Human label for menus / previews.
    var label: String {
        switch self {
        case .text: return "text"
        case .rtf:  return "rich text"
        case .png, .tiff: return "image"
        }
    }
}

/// One representation on the wire: raw bytes base64-encoded.
struct ClipPart: Codable {
    let kind: ClipKind
    let b64: String
}

/// A copied file, transferred by *content* (not just its path).
struct ClipFile {
    let name: String
    let data: Data
}
struct ClipFileWire: Codable {
    let name: String
    let b64: String
}

/// The set of representations for one clipboard state.
struct ClipSnapshot {
    var parts: [ClipKind: Data]
    var files: [ClipFile] = []

    var isEmpty: Bool { parts.isEmpty && files.isEmpty }
    var totalBytes: Int {
        parts.values.reduce(0) { $0 + $1.count } + files.reduce(0) { $0 + $1.data.count }
    }

    var plainText: String? {
        parts[.text].flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Human label for menus / previews. RTF outranks image parts: apps that
    /// copy formatted text (Excel, Word, …) often add a TIFF *rendering* of the
    /// selection alongside, which is still a text copy to the user — while a
    /// genuine image copy never carries RTF.
    var contentLabel: String {
        if !files.isEmpty { return files.count == 1 ? "file" : "\(files.count) files" }
        if parts[.rtf] != nil { return "rich text" }
        if parts[.png] != nil || parts[.tiff] != nil { return "image" }
        return "text"
    }

    /// Stable content hash for dedup / echo-loop prevention.
    var hash: String {
        var hasher = SHA256()
        for kind in ClipKind.allCases {
            guard let d = parts[kind] else { continue }
            hasher.update(data: Data(kind.rawValue.utf8))
            hasher.update(data: d)
        }
        for f in files {
            hasher.update(data: Data("file:\(f.name):".utf8))
            hasher.update(data: f.data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Wire conversion

    var wireParts: [ClipPart] {
        ClipKind.allCases.compactMap { kind in
            parts[kind].map { ClipPart(kind: kind, b64: $0.base64EncodedString()) }
        }
    }
    var wireFiles: [ClipFileWire] {
        files.map { ClipFileWire(name: $0.name, b64: $0.data.base64EncodedString()) }
    }

    init(parts: [ClipKind: Data], files: [ClipFile] = []) {
        self.parts = parts
        self.files = files
    }

    init?(wire: [ClipPart]?, wireFiles: [ClipFileWire]? = nil) {
        var p: [ClipKind: Data] = [:]
        for part in wire ?? [] {
            if let d = Data(base64Encoded: part.b64) { p[part.kind] = d }
        }
        var f: [ClipFile] = []
        for wf in wireFiles ?? [] {
            if let d = Data(base64Encoded: wf.b64) { f.append(ClipFile(name: wf.name, data: d)) }
        }
        guard !p.isEmpty || !f.isEmpty else { return nil }
        self.parts = p
        self.files = f
    }
}

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

/// Coarse user-facing category of a clip — drives the picker's filter chips,
/// group badges, sub-sections, and row icons. Structured (not string-matched)
/// so classification changes can't silently break filters. Note: a *file* whose
/// content is a picture counts as `.image` — to the user it's an image either
/// way; pasting still pastes the file.
enum ClipCategory {
    case text, richText, image, file
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

    /// File extensions treated as pictures for classification/thumbnails.
    static let imageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "webp", "bmp", "ico"]

    /// True when this is a file clip and every file is a picture.
    var filesAreAllImages: Bool {
        !files.isEmpty && files.allSatisfy {
            Self.imageExtensions.contains(($0.name as NSString).pathExtension.lowercased())
        }
    }

    /// See ClipCategory. RTF outranks image parts: apps that copy formatted
    /// text (Excel, Word, …) often add a TIFF *rendering* of the selection
    /// alongside, which is still a text copy to the user — while a genuine
    /// image copy never carries RTF.
    var category: ClipCategory {
        if !files.isEmpty { return filesAreAllImages ? .image : .file }
        if parts[.rtf] != nil { return .richText }
        if parts[.png] != nil || parts[.tiff] != nil { return .image }
        return .text
    }

    /// Human label for menus / previews / peer metadata (display only —
    /// classification logic uses `category`).
    var contentLabel: String {
        if !files.isEmpty {
            let noun = filesAreAllImages ? "image file" : "file"
            return files.count == 1 ? noun : "\(files.count) \(noun)s"
        }
        switch category {
        case .richText: return "rich text"
        case .image:    return "image"
        default:        return "text"
        }
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

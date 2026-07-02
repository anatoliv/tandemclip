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

/// The set of representations for one clipboard state.
struct ClipSnapshot {
    var parts: [ClipKind: Data]

    var isEmpty: Bool { parts.isEmpty }
    var totalBytes: Int { parts.values.reduce(0) { $0 + $1.count } }

    var plainText: String? {
        parts[.text].flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Richest representation present (image > rich text > text) — for labels.
    var richestKind: ClipKind {
        if parts[.png] != nil || parts[.tiff] != nil { return .png }
        if parts[.rtf] != nil { return .rtf }
        return .text
    }

    /// Stable content hash for dedup / echo-loop prevention.
    var hash: String {
        var hasher = SHA256()
        for kind in ClipKind.allCases {
            guard let d = parts[kind] else { continue }
            hasher.update(data: Data(kind.rawValue.utf8))
            hasher.update(data: d)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Wire conversion

    var wireParts: [ClipPart] {
        ClipKind.allCases.compactMap { kind in
            parts[kind].map { ClipPart(kind: kind, b64: $0.base64EncodedString()) }
        }
    }

    init(parts: [ClipKind: Data]) { self.parts = parts }

    init?(wire: [ClipPart]?) {
        guard let wire, !wire.isEmpty else { return nil }
        var p: [ClipKind: Data] = [:]
        for part in wire {
            if let d = Data(base64Encoded: part.b64) { p[part.kind] = d }
        }
        guard !p.isEmpty else { return nil }
        self.parts = p
    }
}

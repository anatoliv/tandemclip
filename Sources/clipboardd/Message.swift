import Foundation

/// Wire format for a synced clipboard entry. JSON body, length-prefixed on the
/// wire (see Transport). `hash` is the SHA-256 of the UTF-8 text and is the key
/// used for deduplication and echo-loop prevention on both ends.
struct ClipMessage: Codable {
    let version: Int
    let type: String        // "clip"
    let contentType: String // "text" (rtf/png/tiff/file-url come later)
    let timestamp: Double    // epoch seconds; used for last-writer-wins
    let hash: String
    let source: String       // device name that originated the copy
    let text: String
}

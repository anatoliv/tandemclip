import Foundation

/// Message kinds on the wire.
/// - `announce`: identity + clipboard *metadata* (no text). Sent on connect and
///   whenever the local clipboard changes. Populates the peer table / allowlist.
/// - `clip`: full clipboard content. Broadcast in Mirror mode, or sent as the
///   reply to a `request` in Manual mode.
/// - `request`: "send me your current clipboard" — addressed to one peer.
/// - `delete`: "remove the history item with this `hash` everywhere" — a signed
///   user action, broadcast and relayed like a clip. Older builds fail to decode
///   the unknown type and skip the frame, so this is forward-compatible.
/// - `pin` / `unpin`: a clip pinned (full content, label in `preview`) or
///   unpinned (hash only) — signed user actions, relayed like clips.
enum MessageType: String, Codable { case announce, clip, request, delete, pin, unpin }

/// Wire format. JSON body, length-prefixed on the wire (see Transport). Every
/// message carries the sender's identity so peers can be listed, addressed, and
/// allow-listed. `hash` keys deduplication / echo-loop prevention.
struct Message: Codable {
    var version: Int = 2
    var type: MessageType

    // Sender identity (present on every message).
    var deviceID: String
    var deviceName: String
    var identityPublicKey: String?
    var identitySignature: String?

    // Clipboard payload (announce carries metadata; clip also carries content).
    var contentType: String = "text"   // richest kind label: "text"/"rich text"/"image"
    var timestamp: Double = 0
    var hash: String?
    var size: Int?
    var preview: String?   // included only when previewLevel == .preview
    var text: String?      // plain-text representation (preview / legacy)
    var parts: [ClipPart]? // full multi-representation payload on `clip`
    var files: [ClipFileWire]? // copied files, transferred by content
}

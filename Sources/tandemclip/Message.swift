import Foundation

/// Message kinds on the wire.
/// - `announce`: identity + clipboard *metadata* (no text). Sent on connect and
///   whenever the local clipboard changes. Populates the peer table / allowlist.
/// - `clip`: full clipboard content. Broadcast in Mirror mode, or sent as the
///   reply to a `request` in Manual mode.
/// - `request`: "send me your current clipboard" — addressed to one peer.
enum MessageType: String, Codable { case announce, clip, request }

/// Wire format. JSON body, length-prefixed on the wire (see Transport). Every
/// message carries the sender's identity so peers can be listed, addressed, and
/// allow-listed. `hash` keys deduplication / echo-loop prevention.
struct Message: Codable {
    var version: Int = 2
    var type: MessageType

    // Sender identity (present on every message).
    var deviceID: String
    var deviceName: String

    // Clipboard payload (announce carries metadata; clip also carries content).
    var contentType: String = "text"   // richest kind label: "text"/"rich text"/"image"
    var timestamp: Double = 0
    var hash: String?
    var size: Int?
    var preview: String?   // included only when previewLevel == .preview
    var text: String?      // plain-text representation (preview / legacy)
    var parts: [ClipPart]? // full multi-representation payload on `clip`
}

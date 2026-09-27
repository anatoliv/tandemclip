import CryptoKit
import Foundation
import Security

/// Per-install signing identity used to bind the trusted-device allowlist to a
/// real key, instead of to a self-asserted deviceID inside the PSK-TLS channel.
struct DeviceIdentity {
    private let privateKey: Curve25519.Signing.PrivateKey?

    var isAvailable: Bool { privateKey != nil }

    var publicKeyBase64: String {
        privateKey?.publicKey.rawRepresentation.base64EncodedString() ?? ""
    }

    init() {
        let stored = KeychainStore.getDataStatus("identitySigningKey")
        if let data = stored.value {
            privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
            if privateKey == nil { Log.error("stored device signing key is invalid — sync disabled") }
            return
        }
        guard stored.status == errSecItemNotFound else {
            Log.error("device signing key unreadable (status \(stored.status)) — sync disabled")
            privateKey = nil
            return
        }
        let key = Curve25519.Signing.PrivateKey()
        privateKey = KeychainStore.setData("identitySigningKey", key.rawRepresentation) ? key : nil
        if privateKey == nil { Log.error("could not save device signing key — sync disabled") }
    }

    func sign(_ message: inout Message) {
        guard let privateKey else { return }
        message.identityPublicKey = publicKeyBase64
        message.identitySignature = nil
        let data = Self.canonicalData(for: message)
        if let signature = try? privateKey.signature(for: data) {
            message.identitySignature = signature.base64EncodedString()
        }
    }

    static func verifiedPublicKey(for message: Message) -> String? {
        guard let publicKeyBase64 = message.identityPublicKey,
              let signatureBase64 = message.identitySignature,
              let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let signature = Data(base64Encoded: signatureBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        else { return nil }

        return publicKey.isValidSignature(signature, for: canonicalData(for: message)) ? publicKeyBase64 : nil
    }

    static func fingerprint(for publicKey: String) -> String {
        guard let bytes = Data(base64Encoded: publicKey), bytes.count == 32 else { return "Unavailable" }
        let hex = SHA256.hash(data: bytes).prefix(16).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 4)
            return String(hex[start..<end])
        }.joined(separator: " ")
    }

    private static func canonicalData(for message: Message) -> Data {
        var copy = message
        copy.identitySignature = nil
        let payload = SignedMessagePayload(
            version: copy.version,
            type: copy.type.rawValue,
            deviceID: copy.deviceID,
            deviceName: copy.deviceName,
            contentType: copy.contentType,
            timestamp: copy.timestamp,
            hash: copy.hash,
            size: copy.size,
            preview: copy.preview,
            text: copy.text,
            parts: copy.parts?.sorted { $0.kind.rawValue < $1.kind.rawValue }
                .map { SignedPart(kind: $0.kind.rawValue, b64: $0.b64) },
            files: copy.files?.map { SignedFile(name: $0.name, b64: $0.b64) },
            identityPublicKey: copy.identityPublicKey,
            channelBinding: copy.channelBinding,
            chunkIndex: copy.chunkIndex,
            chunkTotal: copy.chunkTotal,
            chunkData: copy.chunkData
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(payload)) ?? Data()
    }
}

private struct SignedMessagePayload: Codable {
    let version: Int
    let type: String
    let deviceID: String
    let deviceName: String
    let contentType: String
    let timestamp: Double
    let hash: String?
    let size: Int?
    let preview: String?
    let text: String?
    let parts: [SignedPart]?
    let files: [SignedFile]?
    let identityPublicKey: String?
    let channelBinding: String?
    let chunkIndex: Int?
    let chunkTotal: Int?
    let chunkData: String?
}

private struct SignedPart: Codable {
    let kind: String
    let b64: String
}

private struct SignedFile: Codable {
    let name: String
    let b64: String
}

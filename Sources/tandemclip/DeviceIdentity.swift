import CryptoKit
import Foundation

/// Per-install signing identity used to bind the trusted-device allowlist to a
/// real key, instead of to a self-asserted deviceID inside the PSK-TLS channel.
struct DeviceIdentity {
    private let privateKey: Curve25519.Signing.PrivateKey

    var publicKeyBase64: String {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    init() {
        if let data = KeychainStore.getData("identitySigningKey"),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            privateKey = key
            return
        }
        let key = Curve25519.Signing.PrivateKey()
        KeychainStore.setData("identitySigningKey", key.rawRepresentation)
        privateKey = key
    }

    func sign(_ message: inout Message) {
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
            identityPublicKey: copy.identityPublicKey
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
}

private struct SignedPart: Codable {
    let kind: String
    let b64: String
}

private struct SignedFile: Codable {
    let name: String
    let b64: String
}

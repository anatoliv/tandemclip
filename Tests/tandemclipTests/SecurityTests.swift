import XCTest
@testable import tandemclip

final class SecurityTests: XCTestCase {
    func testPairingCodeValidationRequiresGeneratedStrengthAndAlphabet() {
        XCTAssertTrue(Config.isAcceptablePairingCode("ABCD-EFGH-JKLM"))
        XCTAssertTrue(Config.isAcceptablePairingCode("abcd efgh jklm"))

        XCTAssertFalse(Config.isAcceptablePairingCode("123456"))
        XCTAssertFalse(Config.isAcceptablePairingCode("ABCD-EFGH-JKLO"))
        XCTAssertFalse(Config.isAcceptablePairingCode("ABCD-EFGH-JKL0"))
        XCTAssertFalse(Config.isAcceptablePairingCode("ABCD-EFGH-JKL1"))
    }

    func testPairingCodeRejectsLowDiversity() {
        // Long enough and in-alphabet, but almost no entropy.
        XCTAssertFalse(Config.isAcceptablePairingCode("AAAA-AAAA-AAAA"))
        XCTAssertFalse(Config.isAcceptablePairingCode("ABAB-ABAB-ABAB"))
        XCTAssertFalse(Config.isAcceptablePairingCode("ABCA-BCAB-CABC"))
    }

    func testGeneratedCodeIsAlwaysAcceptable() {
        for _ in 0..<200 {
            XCTAssertTrue(Config.isAcceptablePairingCode(Config.generateCode()))
        }
    }

    func testDerivedPSKIsStableAndCodeDependent() {
        let a = Config.derivePSK(from: "ABCD-EFGH-JKLM")
        let b = Config.derivePSK(from: "ABCD-EFGH-JKLM")
        let c = Config.derivePSK(from: "ABCD-EFGH-JKLN")
        XCTAssertEqual(a.count, 32)
        XCTAssertEqual(a, b)              // deterministic for a given code
        XCTAssertNotEqual(a, c)           // different code -> different key
        XCTAssertNotEqual(a, Data(count: 32))
    }

    func testPairingCodeNormalizationGroupsSymbols() {
        XCTAssertEqual(Config.normalizedPairingCode(" abcd efgh jklm "), "ABCD-EFGH-JKLM")
        XCTAssertEqual(Config.normalizedPairingCode("abcd-efgh-jklm"), "ABCD-EFGH-JKLM")
    }

    func testSignedIdentityVerifiesAndRejectsTampering() {
        let identity = DeviceIdentity()
        var message = Message(type: .announce, deviceID: "d-peer", deviceName: "Peer")
        message.timestamp = 123
        message.hash = "abc"
        message.size = 42
        identity.sign(&message)

        XCTAssertEqual(DeviceIdentity.verifiedPublicKey(for: message), identity.publicKeyBase64)

        message.deviceName = "Impostor"
        XCTAssertNil(DeviceIdentity.verifiedPublicKey(for: message))
    }

    func testUnsignedIdentityDoesNotVerify() {
        let message = Message(type: .announce, deviceID: "d-peer", deviceName: "Peer")
        XCTAssertNil(DeviceIdentity.verifiedPublicKey(for: message))
    }

    func testLooksLikeSigningKeyDistinguishesKeysFromLegacyNames() {
        // A real Curve25519 signing public key is 32 raw bytes → base64.
        XCTAssertTrue(Config.looksLikeSigningKey(DeviceIdentity().publicKeyBase64))
        // Legacy trustedDevices values were display names, not keys.
        XCTAssertFalse(Config.looksLikeSigningKey("MacBook Pro"))
        XCTAssertFalse(Config.looksLikeSigningKey(""))
        // Base64 of the wrong length must not pass as a key.
        XCTAssertFalse(Config.looksLikeSigningKey(Data(count: 16).base64EncodedString()))
    }

    func testEmptyPairingCodeYieldsNoUsableSecretAndDistinctPSK() {
        // The "Keychain present but unreadable" path leaves an empty code. derivePSK
        // must not hand back a live key there — networking is gated on a non-empty
        // code so the fixed fallback is never used to key a real TLS handshake.
        let real = Config.derivePSK(from: "ABCD-EFGH-JKLM")
        XCTAssertNotEqual(real, Data(count: 32))
        XCTAssertEqual(Config.derivePSK(from: ""), Data(count: 32))
        XCTAssertNotEqual(Config.derivePSK(from: ""), real)
    }

    func testAllowlistBindsDeviceIDToPublicKey() {
        let trusted = ["d-peer": "peer-key"]

        XCTAssertTrue(Config.isTrusted(allowlistEnabled: false,
                                       ownDeviceID: "d-self",
                                       ownPublicKey: "self-key",
                                       trustedDevices: [:],
                                       id: "d-any",
                                       publicKey: nil))

        XCTAssertTrue(Config.isTrusted(allowlistEnabled: true,
                                       ownDeviceID: "d-self",
                                       ownPublicKey: "self-key",
                                       trustedDevices: trusted,
                                       id: "d-peer",
                                       publicKey: "peer-key"))

        XCTAssertFalse(Config.isTrusted(allowlistEnabled: true,
                                        ownDeviceID: "d-self",
                                        ownPublicKey: "self-key",
                                        trustedDevices: trusted,
                                        id: "d-peer",
                                        publicKey: "attacker-key"))

        XCTAssertFalse(Config.isTrusted(allowlistEnabled: true,
                                        ownDeviceID: "d-self",
                                        ownPublicKey: "self-key",
                                        trustedDevices: trusted,
                                        id: "d-peer",
                                        publicKey: nil))
    }
}

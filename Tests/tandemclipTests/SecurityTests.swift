import XCTest
import CryptoKit
import Network
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

    func testDevicePinRequiredEvenForOldDisabledPreference() {
        let defaults = UserDefaults.standard
        let oldSetting = defaults.object(forKey: "allowlistEnabled")
        defaults.set(false, forKey: "allowlistEnabled")
        defer {
            if let oldSetting { defaults.set(oldSetting, forKey: "allowlistEnabled") }
            else { defaults.removeObject(forKey: "allowlistEnabled") }
        }

        let config = Config()
        let previous = config.trustedDevices
        defer { config.trustedDevices = previous }
        let id = "d-test-\(UUID().uuidString)"
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()

        XCTAssertFalse(config.isTrusted(id, publicKey: key))
        XCTAssertFalse(config.isTrusted(id, publicKey: nil))
        config.trustedDevices = [id: key]
        XCTAssertTrue(config.isTrusted(id, publicKey: key))
        XCTAssertFalse(config.isTrusted(id, publicKey: "attacker-key"))
        XCTAssertFalse(config.isTrusted(config.deviceID, publicKey: config.identity.publicKeyBase64))
    }

    func testFirstFrameCarriesOnlySignedIdentity() {
        let identity = DeviceIdentity()
        let binding = Data(repeating: 0x42, count: 32)
        var hello = Message(type: .announce, deviceID: "d-peer", deviceName: "Peer")
        hello.channelBinding = binding.base64EncodedString()
        identity.sign(&hello)
        XCTAssertTrue(Transport.isIdentityHello(hello, binding: binding))
        XCTAssertEqual(DeviceIdentity.verifiedPublicKey(for: hello), identity.publicKeyBase64)

        let otherConnection = Data(repeating: 0x43, count: 32)
        XCTAssertFalse(Transport.isIdentityHello(hello, binding: otherConnection),
                       "a captured hello must not authenticate a different TLS connection")
        var forgedBinding = hello
        forgedBinding.channelBinding = otherConnection.base64EncodedString()
        XCTAssertNil(DeviceIdentity.verifiedPublicKey(for: forgedBinding),
                     "the signature must cover the TLS exporter")

        var oldVersion = hello
        oldVersion.version = 2
        XCTAssertFalse(Transport.isIdentityHello(oldVersion, binding: binding))

        hello.preview = "private clipboard"
        XCTAssertFalse(Transport.isIdentityHello(hello, binding: binding))
        hello.preview = nil
        hello.chunkData = "AA=="
        XCTAssertFalse(Transport.isIdentityHello(hello, binding: binding))
    }

    func testReconnectAnnouncementRespectsPauseAndNetworkGuard() {
        let config = Config()
        let previousRole = config.role
        let previousPreview = config.previewLevel
        let previousPause = config.paused
        let previousPrivacy = config.privacyHold
        defer {
            config.role = previousRole
            config.previewLevel = previousPreview
            config.setPaused(previousPause)
            config.privacyHold = previousPrivacy
        }
        config.role = .sendReceive
        config.previewLevel = .metadata
        config.setPaused(false)
        config.privacyHold = false
        let engine = SyncEngine(config: config)
        engine.networkAllowed = { true }
        let snapshot = ClipSnapshot(parts: [.text: Data("ordinary clip".utf8)])
        engine.watcher.onLocalCopy?(snapshot, snapshot.hash)
        XCTAssertEqual(engine.transport.trustedAnnounceProvider?()?.hash, snapshot.hash)

        config.setPaused(true)
        XCTAssertNil(engine.transport.trustedAnnounceProvider?()?.hash)
        config.setPaused(false)
        engine.networkAllowed = { false }
        XCTAssertNil(engine.transport.trustedAnnounceProvider?()?.hash)
    }

    func testTLSExporterMatchesBothEndsAndChangesPerConnection() throws {
        let transport = Transport(config: Config())
        let queue = DispatchQueue(label: "tandemclip.tests.tls-exporter")
        let listener = try NWListener(using: transport.tlsParameters(), on: .any)
        let listenerReady = expectation(description: "TLS listener ready")
        let serverReady = expectation(description: "server exporters")
        serverReady.expectedFulfillmentCount = 2
        let clientReady = expectation(description: "client exporters")
        clientReady.expectedFulfillmentCount = 2
        var accepted: [NWConnection] = []
        var serverBindings: [Data] = []
        var clientBindings: [Data] = []
        listener.newConnectionHandler = { connection in
            accepted.append(connection)
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    if let binding = Transport.channelBinding(on: connection) {
                        serverBindings.append(binding)
                    }
                    serverReady.fulfill()
                }
            }
            connection.start(queue: queue)
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady.fulfill() }
        }
        listener.start(queue: queue)
        defer { listener.cancel(); accepted.forEach { $0.cancel() } }
        wait(for: [listenerReady], timeout: 10)
        let port = try XCTUnwrap(listener.port)

        var clients: [NWConnection] = []
        defer { clients.forEach { $0.cancel() } }
        for _ in 0..<2 {
            let connection = NWConnection(host: "127.0.0.1", port: port,
                                          using: transport.tlsParameters())
            clients.append(connection)
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    if let binding = Transport.channelBinding(on: connection) {
                        clientBindings.append(binding)
                    }
                    clientReady.fulfill()
                }
            }
            connection.start(queue: queue)
        }
        wait(for: [serverReady, clientReady], timeout: 10)
        XCTAssertEqual(serverBindings.count, 2)
        XCTAssertEqual(clientBindings.count, 2)
        XCTAssertEqual(Set(serverBindings), Set(clientBindings))
        XCTAssertEqual(Set(serverBindings).count, 2)
    }

    func testChangedKeyNeedsExplicitReplacement() {
        let config = Config()
        let previous = config.trustedDevices
        defer { config.trustedDevices = previous }
        let id = "d-test-\(UUID().uuidString)"
        let first = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let replacement = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()

        XCTAssertFalse(config.replaceTrustedKey(id, with: replacement))
        XCTAssertTrue(config.trustNewDevice(id, publicKey: first))
        XCTAssertFalse(config.trustNewDevice(id, publicKey: replacement))
        XCTAssertTrue(config.isTrusted(id, publicKey: first))
        XCTAssertFalse(config.isTrusted(id, publicKey: replacement))

        XCTAssertTrue(config.replaceTrustedKey(id, with: replacement))
        XCTAssertFalse(config.isTrusted(id, publicKey: first))
        XCTAssertTrue(config.isTrusted(id, publicKey: replacement))
        config.revokeDevice(id)
        XCTAssertFalse(config.isTrusted(id, publicKey: replacement))
    }
}

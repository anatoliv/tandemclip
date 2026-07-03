import XCTest
@testable import tandemclip

final class SecretGuardTests: XCTestCase {
    func testKnownKeyShapesAreHeld() {
        XCTAssertEqual(SecretGuard.assess("sk-proj-abcDEF123456789012345678")?.reason, "API key")
        XCTAssertEqual(SecretGuard.assess("ghp_AbCdEf123456789012345678901234")?.reason, "GitHub token")
        XCTAssertEqual(SecretGuard.assess("AKIAIOSFODNN7EXAMPLE")?.reason, "AWS access key")
        XCTAssertEqual(SecretGuard.assess("token: xoxb-123456789-abcdefghij")?.reason, "Slack token")
        XCTAssertEqual(SecretGuard.assess("-----BEGIN RSA PRIVATE KEY-----\nMIIE...\n-----END RSA PRIVATE KEY-----")?.reason,
                       "private key")
    }

    func testJWTAndPaymentAndIBAN() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        XCTAssertEqual(SecretGuard.assess(jwt)?.reason, "JWT token")
        XCTAssertEqual(SecretGuard.assess("card: 4111 1111 1111 1111")?.reason, "payment card number")
        XCTAssertNil(SecretGuard.assess("order 4111 1111 1111 1112"), "Luhn-invalid must not trip")
        XCTAssertEqual(SecretGuard.assess("DE89370400440532013000")?.reason, "IBAN")
        XCTAssertNil(SecretGuard.assess("DE89370400440532013001"), "mod-97-invalid must not trip")
    }

    func testHighEntropyTokenOnlyWhenAlone() {
        XCTAssertEqual(SecretGuard.assess("aB3xK9mQ2wE7rT5yU1iP8oL4kJ6hG0fD")?.reason, "high-entropy token")
        XCTAssertNil(SecretGuard.assess("please review commit aB3xK9mQ2wE7rT5yU1iP8oL4kJ6hG0fD today"),
                     "tokens inside prose must not trip")
        XCTAssertNil(SecretGuard.assess("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), "low entropy")
        XCTAssertNil(SecretGuard.assess("supercalifragilisticexpialidocious"), "no digits/case mix")
    }

    func testOrdinaryContentPasses() {
        XCTAssertNil(SecretGuard.assess("Meet at 14:30 tomorrow, bring the slides."))
        XCTAssertNil(SecretGuard.assess("https://tandemclip.com/help?q=setup"))
        XCTAssertNil(SecretGuard.assess("call me at (555) 010-9999"))
        XCTAssertNil(SecretGuard.assess("ok"))
    }

    func testEngineHoldsAndReleases() {
        let engine = SyncEngine(config: Config())
        engine.config.historyEnabled = true
        engine.config.mode = .mirror
        engine.config.secretGuardEnabled = true
        defer { engine.config.mode = .mirror }

        let secret = "ghp_AbCdEf123456789012345678901234"
        let snap = ClipSnapshot(parts: [.text: Data(secret.utf8)])
        engine.watcher.onLocalCopy?(snap, snap.hash)

        // Captured but held: history yes, broadcast no.
        XCTAssertTrue(engine.history.contains { $0.hash == snap.hash })
        XCTAssertNil(engine.lastSyncSource)
        XCTAssertEqual(engine.heldSecret?.reason, "GitHub token")

        // Send anyway → broadcast happens.
        engine.releaseHeldSecret()
        XCTAssertNil(engine.heldSecret)
        XCTAssertNotNil(engine.lastSyncSource)

        // Guard off → same copy broadcasts immediately.
        engine.config.secretGuardEnabled = false
        let snap2 = ClipSnapshot(parts: [.text: Data((secret + "x").utf8)])
        engine.watcher.onLocalCopy?(snap2, snap2.hash)
        XCTAssertNil(engine.heldSecret)
        engine.config.secretGuardEnabled = true
    }
}

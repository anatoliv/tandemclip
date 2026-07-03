import XCTest
@testable import tandemclip

/// Privacy hold: while on, nothing of ours goes out — local copies aren't
/// broadcast and drop-shares are refused — but local capture (history) and
/// receiving keep working. Engine-level, no network (transport never started).
final class PrivacyHoldTests: XCTestCase {
    private var engine: SyncEngine!

    override func setUp() {
        super.setUp()
        engine = SyncEngine(config: Config())
        engine.config.historyEnabled = true
        engine.config.privacyHold = false
    }

    override func tearDown() {
        engine.config.privacyHold = false
        super.tearDown()
    }

    private func copyLocally(_ text: String) -> String {
        let snap = ClipSnapshot(parts: [.text: Data(text.utf8)])
        engine.watcher.onLocalCopy?(snap, snap.hash)
        return snap.hash
    }

    func testHoldBlocksBroadcastButStillCaptures() {
        engine.config.privacyHold = true
        let hash = copyLocally("secret-ish text")

        // Captured locally (history + shareable snapshot)…
        XCTAssertTrue(engine.history.contains { $0.hash == hash })
        XCTAssertNotNil(engine.currentClipInfo)
        // …but never broadcast (lastSyncSource is only set after a send).
        XCTAssertNil(engine.lastSyncSource)
    }

    func testNoHoldBroadcastsAsUsual() {
        engine.config.privacyHold = false
        _ = copyLocally("public text")
        XCTAssertNotNil(engine.lastSyncSource, "mirror broadcast should mark the sync source")
    }

    func testHoldRefusesDropShare() {
        engine.config.privacyHold = true
        let dir = FileManager.default.temporaryDirectory
        let f = dir.appendingPathComponent("hold-test.txt")
        try? Data("x".utf8).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        XCTAssertEqual(engine.shareFiles([f]).sent, 0)
    }
}

extension PrivacyHoldTests {
    func testShareTextBroadcastsAndRecordsHistory() {
        let engine = SyncEngine(config: Config())
        engine.config.historyEnabled = true
        engine.config.privacyHold = false
        XCTAssertTrue(engine.shareText("shared via services"))
        XCTAssertTrue(engine.history.contains { $0.label.contains("shared via services") })
        XCTAssertEqual(engine.lastSyncSource?.contains("(shared)"), true)

        engine.config.privacyHold = true
        XCTAssertFalse(engine.shareText("held"), "privacy hold blocks explicit text shares too")
        engine.config.privacyHold = false
        XCTAssertFalse(engine.shareText(""))
    }
}

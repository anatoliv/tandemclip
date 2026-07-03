import XCTest
import AppKit
@testable import tandemclip

/// "Apply incoming clips automatically": in Manual mode, an incoming broadcast
/// lands on the clipboard without a pull when the option is on, and is ignored
/// (as before) when off. Engine-level via the transport callback; no network.
final class AutoApplyTests: XCTestCase {
    private var engine: SyncEngine!
    private var savedItems: [NSPasteboardItem] = []

    override func setUp() {
        super.setUp()
        savedItems = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types {
                if let d = item.data(forType: t) { copy.setData(d, forType: t) }
            }
            return copy
        }
        engine = SyncEngine(config: Config())
        engine.config.historyEnabled = true
        engine.config.mode = .manual
    }

    override func tearDown() {
        engine.config.autoApplyIncoming = false
        engine.config.mode = .mirror
        NSPasteboard.general.clearContents()
        if !savedItems.isEmpty { NSPasteboard.general.writeObjects(savedItems) }
        super.tearDown()
    }

    private func incomingClip(_ text: String) -> Message {
        let identity = DeviceIdentity()
        var m = Message(type: .clip, deviceID: "d-test-peer", deviceName: "TestPeer")
        m.timestamp = Date().timeIntervalSince1970
        let snap = ClipSnapshot(parts: [.text: Data(text.utf8)])
        m.hash = snap.hash
        m.parts = snap.wireParts
        identity.sign(&m)
        return m
    }

    private func deliver(_ m: Message) {
        engine.transport.onMessage?(m, DeviceIdentity.verifiedPublicKey(for: m))
        let done = expectation(description: "main-queue delivery")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testManualModeIgnoresBroadcastByDefault() {
        engine.config.autoApplyIncoming = false
        deliver(incomingClip("unsolicited"))
        XCTAssertFalse(engine.history.contains { $0.label.contains("unsolicited") })
        XCTAssertNil(engine.lastSyncSource)
    }

    func testManualModeAppliesBroadcastWhenOptedIn() {
        engine.config.autoApplyIncoming = true
        deliver(incomingClip("auto landed"))
        XCTAssertTrue(engine.history.contains { $0.label.contains("auto landed") },
                      "broadcast should be applied without a pull")
        XCTAssertEqual(engine.lastSyncSource, "TestPeer")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "auto landed")
    }

    func testAutoApplyStillRejectsStaleClips() {
        engine.config.autoApplyIncoming = true
        let identity = DeviceIdentity()
        var m = Message(type: .clip, deviceID: "d-test-peer", deviceName: "TestPeer")
        m.timestamp = Date().timeIntervalSince1970 - 3600   // replayed capture
        let snap = ClipSnapshot(parts: [.text: Data("stale".utf8)])
        m.hash = snap.hash
        m.parts = snap.wireParts
        identity.sign(&m)
        deliver(m)
        XCTAssertFalse(engine.history.contains { $0.label.contains("stale") })
    }
}

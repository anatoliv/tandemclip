import XCTest
import AppKit
@testable import tandemclip

final class DeleteSyncTests: XCTestCase {
    // Deleting the current clip clears the system pasteboard — preserve the
    // user's clipboard across these tests.
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
    }

    override func tearDown() {
        NSPasteboard.general.clearContents()
        if !savedItems.isEmpty { NSPasteboard.general.writeObjects(savedItems) }
        super.tearDown()
    }
    /// A delete is a signed action keyed by hash — tampering with the hash must
    /// invalidate the signature, or a MITM could redirect a deletion at a
    /// different clip.
    func testDeleteMessageSignatureCoversHash() {
        let identity = DeviceIdentity()
        var m = Message(type: .delete, deviceID: "d-peer", deviceName: "Peer")
        m.timestamp = 456
        m.hash = "deadbeef"
        identity.sign(&m)
        XCTAssertEqual(DeviceIdentity.verifiedPublicKey(for: m), identity.publicKeyBase64)

        m.hash = "cafebabe"
        XCTAssertNil(DeviceIdentity.verifiedPublicKey(for: m))
    }

    func testDeleteMessageRoundTripsOnTheWire() throws {
        var m = Message(type: .delete, deviceID: "d-a", deviceName: "A")
        m.hash = "deadbeef"
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(Message.self, from: data)
        XCTAssertEqual(back.type, .delete)
        XCTAssertEqual(back.hash, "deadbeef")
    }

    /// Forward compatibility: builds that don't know a message type fail the
    /// decode and skip the frame (Transport wraps decoding in try?). This is
    /// what lets `delete` ship without a protocol version bump — assert the
    /// mechanism holds for the next unknown type too.
    func testUnknownMessageTypeFailsDecodeGracefully() throws {
        var m = Message(type: .delete, deviceID: "d-a", deviceName: "A")
        m.hash = "deadbeef"
        var json = try XCTUnwrap(String(data: JSONEncoder().encode(m), encoding: .utf8))
        json = json.replacingOccurrences(of: "\"delete\"", with: "\"purge-v9\"")
        XCTAssertNil(try? JSONDecoder().decode(Message.self, from: Data(json.utf8)))
    }

    // MARK: - Engine flow (no network, no UI: inject via the transport callback)

    /// Build an engine without calling start() — no watcher timer, no
    /// networking; broadcasts go to a transport with zero connections.
    private func makeEngine() -> SyncEngine {
        let engine = SyncEngine(config: Config())
        engine.config.historyEnabled = true
        return engine
    }

    private func seedLocalClip(_ engine: SyncEngine, _ text: String) -> String {
        let snap = ClipSnapshot(parts: [.text: Data(text.utf8)])
        engine.watcher.onLocalCopy?(snap, snap.hash)   // as if the user copied it
        return snap.hash
    }

    func testLocalDeleteRemovesFromHistory() {
        let engine = makeEngine()
        let hash = seedLocalClip(engine, "delete me locally")
        XCTAssertTrue(engine.history.contains { $0.hash == hash })

        engine.deleteHistory(hash: hash)
        XCTAssertFalse(engine.history.contains { $0.hash == hash })
    }

    func testRemoteDeleteRemovesFromHistory() {
        let engine = makeEngine()
        let hash = seedLocalClip(engine, "delete me remotely")
        XCTAssertTrue(engine.history.contains { $0.hash == hash })

        let peerIdentity = DeviceIdentity()
        var del = Message(type: .delete, deviceID: "d-test-peer", deviceName: "TestPeer")
        del.timestamp = Date().timeIntervalSince1970
        del.hash = hash
        peerIdentity.sign(&del)

        // Deliver exactly as Transport would (signature pre-verified there).
        engine.transport.onMessage?(del, DeviceIdentity.verifiedPublicKey(for: del))
        let done = expectation(description: "main-queue delivery")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)

        XCTAssertFalse(engine.history.contains { $0.hash == hash },
                       "signed remote delete must remove the item")
    }

    func testStaleRemoteDeleteIsIgnored() {
        let engine = makeEngine()
        let hash = seedLocalClip(engine, "replay target")

        let peerIdentity = DeviceIdentity()
        var del = Message(type: .delete, deviceID: "d-test-peer", deviceName: "TestPeer")
        del.timestamp = Date().timeIntervalSince1970 - 3600   // an hour old: replayed capture
        del.hash = hash
        peerIdentity.sign(&del)

        engine.transport.onMessage?(del, DeviceIdentity.verifiedPublicKey(for: del))
        let done = expectation(description: "main-queue delivery")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)

        XCTAssertTrue(engine.history.contains { $0.hash == hash },
                      "a stale (replayed) delete must not remove anything")
    }
}

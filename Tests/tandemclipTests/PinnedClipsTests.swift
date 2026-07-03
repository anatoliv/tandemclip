import XCTest
@testable import tandemclip

final class PinnedClipsTests: XCTestCase {
    private func item(_ text: String) -> HistoryItem {
        let snap = ClipSnapshot(parts: [.text: Data(text.utf8)])
        return HistoryItem(snapshot: snap, hash: snap.hash, timestamp: 0,
                           label: String(text.prefix(64)), source: "Home")
    }

    func testPinStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tc-pins-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let it = item("pinned content")
        let pin = PinnedClip(hash: it.hash, label: it.label, source: it.source, timestamp: 5,
                             parts: it.snapshot.wireParts, files: it.snapshot.wireFiles)
        PinStore.save([pin], to: url)
        let loaded = PinStore.load(from: url)
        XCTAssertEqual(loaded, [pin])
        XCTAssertEqual(loaded.first?.snapshot?.plainText, "pinned content")
        XCTAssertEqual(loaded.first?.historyItem?.label, "pinned content")
    }

    func testEnginePinUnpinAndIncomingPin() {
        let engine = SyncEngine(config: Config())
        engine.config.historyEnabled = true
        let it = item("pin me \(UUID().uuidString)")
        defer { engine.unpin(hash: it.hash) }   // leave no persisted residue

        XCTAssertTrue(engine.pin(it))
        XCTAssertTrue(engine.pins.contains { $0.hash == it.hash })
        // Re-pin dedupes.
        XCTAssertTrue(engine.pin(it))
        XCTAssertEqual(engine.pins.filter { $0.hash == it.hash }.count, 1)

        engine.unpin(hash: it.hash)
        XCTAssertFalse(engine.pins.contains { $0.hash == it.hash })

        // Incoming signed pin from a trusted peer lands in the store.
        let identity = DeviceIdentity()
        var m = Message(type: .pin, deviceID: "d-test-peer", deviceName: "TestPeer")
        m.timestamp = Date().timeIntervalSince1970
        let snap = ClipSnapshot(parts: [.text: Data("peer pinned this".utf8)])
        m.hash = snap.hash
        m.preview = "peer pinned this"
        m.parts = snap.wireParts
        identity.sign(&m)
        engine.transport.onMessage?(m, DeviceIdentity.verifiedPublicKey(for: m))
        let done = expectation(description: "delivery")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(engine.pins.contains { $0.hash == snap.hash })
        XCTAssertEqual(engine.pins.first { $0.hash == snap.hash }?.source, "TestPeer")
        engine.unpin(hash: snap.hash)
    }

    func testDeleteEverywhereUnpins() {
        let engine = SyncEngine(config: Config())
        engine.config.historyEnabled = true
        let it = item("delete unpins \(UUID().uuidString)")
        XCTAssertTrue(engine.pin(it))
        engine.deleteHistory(hash: it.hash)
        XCTAssertFalse(engine.pins.contains { $0.hash == it.hash })
    }

    func testOversizedClipRefusesToPin() {
        let engine = SyncEngine(config: Config())
        let big = HistoryItem(
            snapshot: ClipSnapshot(parts: [.text: Data(repeating: 65, count: engine.config.maxClipBytes + 1)]),
            hash: "big", timestamp: 0, label: "big", source: "Home")
        XCTAssertFalse(engine.pin(big))
    }
}

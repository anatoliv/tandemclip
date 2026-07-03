import XCTest
@testable import tandemclip

final class ChunkedTransferTests: XCTestCase {
    func testChunkerRoundTrip() {
        let payload = Data((0..<50_000).map { UInt8($0 % 251) })
        let slices = ClipChunker.slices(of: payload, sliceBytes: 7_000)
        XCTAssertEqual(slices.count, 8)
        XCTAssertEqual(slices.map(\.total), Array(repeating: 8, count: 8))

        var parts: [Int: Data] = [:]
        for s in slices.shuffled() { parts[s.index] = s.data }
        XCTAssertEqual(ClipChunker.assemble(parts, total: 8), payload)

        // Missing slice → nil.
        parts[3] = nil
        XCTAssertNil(ClipChunker.assemble(parts, total: 8))
        XCTAssertTrue(ClipChunker.slices(of: Data()).isEmpty)
    }

    func testChunkedClipReassemblesThroughEngine() {
        let engine = SyncEngine(config: Config())
        engine.config.historyEnabled = true
        engine.config.mode = .manual
        engine.config.autoApplyIncoming = true   // apply the inner broadcast
        defer {
            engine.config.autoApplyIncoming = false
            engine.config.mode = .mirror
        }

        // Build the inner (signed) clip message from a peer.
        let identity = DeviceIdentity()
        let text = "chunked payload " + String(repeating: "x", count: 40_000)
        let snap = ClipSnapshot(parts: [.text: Data(text.utf8)])
        var inner = Message(type: .clip, deviceID: "d-test-peer", deviceName: "TestPeer")
        inner.timestamp = Date().timeIntervalSince1970
        inner.hash = snap.hash
        inner.parts = snap.wireParts
        identity.sign(&inner)
        let payload = try! JSONEncoder().encode(inner)

        // Deliver as signed chunks (out of order, like a real network).
        for slice in ClipChunker.slices(of: payload, sliceBytes: 9_000).shuffled() {
            var chunk = Message(type: .chunk, deviceID: "d-test-peer", deviceName: "TestPeer")
            chunk.timestamp = Date().timeIntervalSince1970
            chunk.hash = snap.hash
            chunk.size = payload.count
            chunk.chunkIndex = slice.index
            chunk.chunkTotal = slice.total
            chunk.chunkData = slice.data.base64EncodedString()
            identity.sign(&chunk)
            engine.transport.onMessage?(chunk, DeviceIdentity.verifiedPublicKey(for: chunk))
        }
        let done = expectation(description: "delivery")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)

        XCTAssertTrue(engine.history.contains { $0.hash == snap.hash },
                      "reassembled clip should flow through the normal receive path")
        engine.deleteHistory(hash: snap.hash)
    }

    func testTamperedChunkSignatureIsRejected() {
        let engine = SyncEngine(config: Config())
        engine.config.historyEnabled = true

        let identity = DeviceIdentity()
        var chunk = Message(type: .chunk, deviceID: "d-test-peer", deviceName: "TestPeer")
        chunk.timestamp = Date().timeIntervalSince1970
        chunk.hash = "transfer"
        chunk.chunkIndex = 0
        chunk.chunkTotal = 1
        chunk.chunkData = Data("legit".utf8).base64EncodedString()
        identity.sign(&chunk)
        // Tamper with the slice after signing.
        chunk.chunkData = Data("evil!".utf8).base64EncodedString()
        XCTAssertNil(DeviceIdentity.verifiedPublicKey(for: chunk),
                     "signature must cover chunk bytes")
    }
}

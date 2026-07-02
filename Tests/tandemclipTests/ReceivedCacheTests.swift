import XCTest
import AppKit
@testable import tandemclip

/// Received-file cache: configurable cap, oldest-first eviction, and
/// protection of the clip whose URLs are currently on the pasteboard.
/// Runs against an injected temp root — never the real cache.
final class ReceivedCacheTests: XCTestCase {
    private var root: URL!
    private var savedItems: [NSPasteboardItem] = []

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tandemclip-cache-tests-\(UUID().uuidString)", isDirectory: true)
        savedItems = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types {
                if let d = item.data(forType: t) { copy.setData(d, forType: t) }
            }
            return copy
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        NSPasteboard.general.clearContents()
        if !savedItems.isEmpty { NSPasteboard.general.writeObjects(savedItems) }
        super.tearDown()
    }

    private func makeWatcher(capBytes: Int) -> ClipboardWatcher {
        let w = ClipboardWatcher()
        w.receivedRoot = root
        w.cacheCap = { capBytes }
        return w
    }

    private func fileSnapshot(_ name: String, bytes: Int, fill: UInt8) -> ClipSnapshot {
        ClipSnapshot(parts: [:], files: [ClipFile(name: name, data: Data(repeating: fill, count: bytes))])
    }

    func testOldestEvictedWhenOverCap_currentClipProtected() throws {
        let watcher = makeWatcher(capBytes: 2_500)

        // Three 1000-byte clips: the third write pushes the cache to 3000 > 2500.
        let a = fileSnapshot("a.bin", bytes: 1_000, fill: 1)
        let b = fileSnapshot("b.bin", bytes: 1_000, fill: 2)
        let c = fileSnapshot("c.bin", bytes: 1_000, fill: 3)
        XCTAssertEqual(watcher.write(a).count, 1)
        Thread.sleep(forTimeInterval: 1.1)   // distinct folder mtimes (1s resolution)
        XCTAssertEqual(watcher.write(b).count, 1)
        Thread.sleep(forTimeInterval: 1.1)
        let cURLs = watcher.write(c)
        XCTAssertEqual(cURLs.count, 1)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        // Oldest (a) evicted; b and c (c = current pasteboard clip) remain.
        XCTAssertEqual(remaining.count, 2)
        XCTAssertEqual(Set(remaining), [String(b.hash.prefix(12)), String(c.hash.prefix(12))])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cURLs[0].path))
        XCTAssertLessThanOrEqual(watcher.receivedCacheUsage(), 2_500)
    }

    func testLoweringCapEvictsImmediately() {
        let watcher = makeWatcher(capBytes: 10_000)
        _ = watcher.write(fileSnapshot("a.bin", bytes: 1_000, fill: 1))
        Thread.sleep(forTimeInterval: 1.1)
        _ = watcher.write(fileSnapshot("b.bin", bytes: 1_000, fill: 2))
        XCTAssertEqual(watcher.receivedCacheUsage(), 2_000)

        watcher.cacheCap = { 1_500 }
        watcher.enforceCacheCap()
        XCTAssertLessThanOrEqual(watcher.receivedCacheUsage(), 1_500)
        XCTAssertEqual(watcher.receivedCacheUsage(), 1_000)   // one clip evicted, one kept
    }

    func testUsageCountsAllCachedBytes() {
        let watcher = makeWatcher(capBytes: 1_000_000)
        XCTAssertEqual(watcher.receivedCacheUsage(), 0)
        _ = watcher.write(fileSnapshot("a.bin", bytes: 1_234, fill: 1))
        _ = watcher.write(fileSnapshot("b.bin", bytes: 4_321, fill: 2))
        XCTAssertEqual(watcher.receivedCacheUsage(), 5_555)
    }
}

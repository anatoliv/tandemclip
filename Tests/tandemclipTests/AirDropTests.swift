import XCTest
@testable import tandemclip

final class AirDropTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tc-airdrop-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func item(_ snap: ClipSnapshot, label: String) -> HistoryItem {
        HistoryItem(snapshot: snap, hash: label, timestamp: 0, label: label, source: "Home")
    }

    func testTextClipBecomesNamedTxt() throws {
        let it = item(ClipSnapshot(parts: [.text: Data("hello airdrop".utf8)]), label: "deploy: checklist!")
        let urls = AirDropPayload.urls(for: it, in: dir)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls[0].lastPathComponent, "deploy  checklist.txt")   // punctuation → spaces
        XCTAssertEqual(try String(contentsOf: urls[0], encoding: .utf8), "hello airdrop")
    }

    func testFileClipKeepsSanitizedNames() {
        let snap = ClipSnapshot(parts: [:], files: [
            ClipFile(name: "report.pdf", data: Data([1, 2])),
            ClipFile(name: "../evil", data: Data([3])),
        ])
        let urls = AirDropPayload.urls(for: item(snap, label: "x"), in: dir)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["report.pdf", "evil"])
        XCTAssertTrue(urls.allSatisfy { $0.path.hasPrefix(dir.path) })
    }

    func testImageClipBecomesPNG() {
        let snap = ClipSnapshot(parts: [.png: Data([0x89, 0x50, 0x4E, 0x47])])
        let urls = AirDropPayload.urls(for: item(snap, label: ""), in: dir)
        XCTAssertEqual(urls.first?.lastPathComponent, "Clip.png")   // empty label → fallback stem
    }

    func testEmptyClipYieldsNothing() {
        let urls = AirDropPayload.urls(for: item(ClipSnapshot(parts: [:]), label: "x"), in: dir)
        XCTAssertTrue(urls.isEmpty)
    }
}

extension AirDropTests {
    func testDragOutProviderKinds() {
        let text = HistoryItem(snapshot: ClipSnapshot(parts: [.text: Data("drag me".utf8)]),
                               hash: "t", timestamp: 0, label: "drag me", source: "Home")
        XCTAssertTrue(DragOutStager.provider(for: text)
            .canLoadObject(ofClass: NSString.self), "text clips drag as strings")

        let file = HistoryItem(snapshot: ClipSnapshot(parts: [:], files: [ClipFile(name: "r.pdf", data: Data([1]))]),
                               hash: "f", timestamp: 0, label: "r.pdf", source: "Home")
        let p = DragOutStager.provider(for: file)
        XCTAssertTrue(p.registeredTypeIdentifiers.contains { $0.contains("pdf") || $0.contains("file-url") || $0.contains("item") },
                      "file clips drag as file providers: \(p.registeredTypeIdentifiers)")
    }
}

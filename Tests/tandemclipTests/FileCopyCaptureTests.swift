import XCTest
import AppKit
@testable import tandemclip

/// A file copy must always be captured by the watcher (history / shareable
/// snapshot), independent of the auto-sync preference — that toggle gates
/// broadcasting in SyncEngine, not capture. Regression for the silent no-op
/// where a Finder file copy produced nothing at all.
final class FileCopyCaptureTests: XCTestCase {
    private var savedItems: [NSPasteboardItem] = []

    override func setUp() {
        super.setUp()
        // Preserve whatever the user had on the clipboard across the test.
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

    private func makeTempFile(_ name: String, _ contents: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tandemclip-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try! Data(contents.utf8).write(to: url)
        return url
    }

    /// Emulate a Finder file copy: file URL + filename string on the pasteboard.
    private func finderCopy(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        pb.setString(urls.map { $0.lastPathComponent }.joined(separator: "\n"), forType: .string)
    }

    func testFileCopyIsAlwaysCaptured() {
        let file = makeTempFile("capture.txt", "captured bytes")
        let watcher = ClipboardWatcher()
        var captured: ClipSnapshot?
        watcher.onLocalCopy = { snap, _ in captured = snap }
        watcher.start()
        finderCopy([file])
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        XCTAssertEqual(captured?.files.count, 1, "file copy was not captured")
        XCTAssertEqual(captured?.files.first?.name, "capture.txt")
        XCTAssertEqual(captured.flatMap { String(data: $0.files.first?.data ?? Data(), encoding: .utf8) },
                       "captured bytes")
        XCTAssertNil(captured?.parts[.text], "filename must not be captured as text")
    }
}

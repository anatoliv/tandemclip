import XCTest
import AppKit
@testable import tandemclip

final class PreviewThumbnailerTests: XCTestCase {
    private func pngData() -> Data {
        let img = NSImage(size: NSSize(width: 60, height: 40), flipped: false) { r in
            NSColor.systemPurple.setFill(); r.fill(); return true
        }
        return NSBitmapImageRep(data: img.tiffRepresentation!)!
            .representation(using: .png, properties: [:])!
    }

    private func item(_ name: String, _ data: Data) -> HistoryItem {
        let snap = ClipSnapshot(parts: [:], files: [ClipFile(name: name, data: data)])
        return HistoryItem(snapshot: snap, hash: "thumb-\(name)-\(data.count)", timestamp: 0,
                           label: name, source: "Home")
    }

    @MainActor
    func testQuickLookThumbnailForImageFile() async {
        let result = await PreviewThumbnailer.shared.preview(for: item("pic.png", pngData()))
        XCTAssertNotNil(result.image, "QuickLook should thumbnail a PNG file")
        XCTAssertNil(result.duration)

        // Second call must come from cache (same object identity).
        let again = await PreviewThumbnailer.shared.preview(for: item("pic.png", pngData()))
        XCTAssertTrue(again.image === result.image, "expected the cached thumbnail")
    }

    @MainActor
    func testUnthumbnailableFileYieldsNothingAndCachesTheMiss() async {
        let junk = item("blob.xyzunknown", Data([0x00, 0x01, 0x02, 0x03]))
        let result = await PreviewThumbnailer.shared.preview(for: junk)
        XCTAssertNil(result.image)
        let again = await PreviewThumbnailer.shared.preview(for: junk)
        XCTAssertNil(again.image)
    }

    func testDurationLabel() {
        XCTAssertEqual(PreviewThumbnailer.durationLabel(222), "3:42")
        XCTAssertEqual(PreviewThumbnailer.durationLabel(59.6), "1:00")
        XCTAssertEqual(PreviewThumbnailer.durationLabel(3727), "1:02:07")
    }
}

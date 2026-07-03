import XCTest
import AppKit
@testable import tandemclip

final class ClipIntelligenceTests: XCTestCase {
    private func textItem(_ text: String, label: String? = nil) -> HistoryItem {
        let snap = ClipSnapshot(parts: [.text: Data(text.utf8)])
        return HistoryItem(snapshot: snap, hash: "h-\(text.hashValue)", timestamp: 0,
                           label: label ?? String(text.prefix(64)), source: "Home")
    }

    /// Render a legible text image for OCR.
    private func textImageData(_ text: String) -> Data {
        let size = NSSize(width: 460, height: 80)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            (text as NSString).draw(at: NSPoint(x: 16, y: 24), withAttributes: [
                .font: NSFont.systemFont(ofSize: 26, weight: .medium),
                .foregroundColor: NSColor.black,
            ])
            return true
        }
        return NSBitmapImageRep(data: img.tiffRepresentation!)!
            .representation(using: .png, properties: [:])!
    }

    func testOCRRecognizesRenderedText() {
        let data = textImageData("Invoice 4821 due Friday")
        let text = ClipIndex.recognizeText(in: data)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("4821") == true, "got: \(text ?? "nil")")
    }

    func testIndexSemanticAndOCRSearch() {
        let index = ClipIndex()   // fresh instance, not the shared one
        let docker = textItem("docker compose up -d --build the whole stack after pulling latest images")
        let cake = textItem("grandma's carrot cake recipe: flour, sugar, carrots, walnuts")
        let shot = HistoryItem(snapshot: ClipSnapshot(parts: [.png: textImageData("Wire transfer 99031 confirmation")]),
                               hash: "h-img", timestamp: 0, label: "image", source: "Home")
        index.index([docker, cake, shot])
        index.waitForIndexing()

        // OCR text is retrievable and keyword-searchable.
        XCTAssertTrue(index.ocrText(for: "h-img")?.contains("99031") == true)

        // Semantic: paraphrase with no exact keyword ("container" vs docker).
        let matches = index.semanticHashes(for: "start the containers")
        if !matches.isEmpty {   // embeddings available on this machine
            XCTAssertTrue(matches.contains(docker.hash))
            XCTAssertFalse(matches.contains(cake.hash), "cake recipe should not match containers")
        }
    }

    func testPickerQueryUsesBodyOCRAndSemantic() {
        let model = PickerModel(onPickHistory: { _ in }, onPullPeer: { _ in }, onDropFiles: { _ in },
                                onDeleteHistory: { _ in }, onClose: {})
        let long = textItem("the quick brown fox jumped over the extremely lazy dog near the riverbank",
                            label: "the quick brown fox")
        model.reload(history: [long], peers: [], showCount: 20, clipUsage: "")

        // Body match beyond the 64-char label.
        model.query = "riverbank"
        XCTAssertEqual(model.filtered.count, 1)

        // OCR lookup match.
        model.ocrLookup = { _ in "serial ABC-777" }
        model.query = "ABC-777"
        XCTAssertEqual(model.filtered.count, 1)

        // Semantic lookup match.
        model.ocrLookup = nil
        model.semanticLookup = { _ in [long.hash] }
        model.query = "zzz nothing literal"
        XCTAssertEqual(model.filtered.count, 1)

        model.semanticLookup = { _ in [] }
        model.recomputeSemantic()   // what ClipIndex.onUpdate does in production
        XCTAssertTrue(model.filtered.isEmpty)
    }

    func testQuickActionDetection() {
        let item = textItem("Docs at https://tandemclip.com/help — write hello@example.com or call (555) 010-9999")
        let actions = QuickAction.detect(for: item, ocrText: nil)
        XCTAssertTrue(actions.contains { if case .openLink = $0.kind { return true }; return false })
        XCTAssertEqual(actions.count, 3)

        // File clips lead with Save to Downloads; OCR text feeds detection too.
        let file = HistoryItem(snapshot: ClipSnapshot(parts: [:], files: [ClipFile(name: "a.zip", data: Data([1]))]),
                               hash: "hf", timestamp: 0, label: "a.zip", source: "Home")
        let fileActions = QuickAction.detect(for: file, ocrText: "see https://example.org")
        XCTAssertEqual(fileActions.first?.kind, .saveToDownloads)
        XCTAssertTrue(fileActions.contains { if case .openLink = $0.kind { return true }; return false })
    }

    func testSummarizeCachesPerHashAndRespectsPrivacyHold() {
        let model = PickerModel(onPickHistory: { _ in }, onPullPeer: { _ in }, onDropFiles: { _ in },
                                onDeleteHistory: { _ in }, onClose: {})
        model.aiConfigured = true
        let long = textItem(String(repeating: "many words here. ", count: 60))

        model.makeSummaryStream = { _ in
            AsyncThrowingStream { c in c.yield("A short summary."); c.finish() }
        }
        model.summarize(long)
        let done = expectation(description: "summary")
        Task { @MainActor in
            while model.summarizingHash != nil { try? await Task.sleep(nanoseconds: 20_000_000) }
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(model.summaries[long.hash], "A short summary.")

        // Privacy hold blocks the call outright.
        let model2 = PickerModel(onPickHistory: { _ in }, onPullPeer: { _ in }, onDropFiles: { _ in },
                                 onDeleteHistory: { _ in }, onClose: {})
        model2.privacyHold = true
        var called = false
        model2.makeSummaryStream = { _ in called = true; return nil }
        model2.summarize(long)
        XCTAssertFalse(called)
    }
}

import XCTest
@testable import tandemclip

final class LooseEndsTests: XCTestCase {
    private func makeFolder(files: [(String, Int)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tc-zip-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, size) in files {
            try Data(repeating: 7, count: size).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    func testFolderCopySyncsAsZip() throws {
        let folder = try makeFolder(files: [("a.txt", 500), ("b.txt", 300)])
        defer { try? FileManager.default.removeItem(at: folder) }

        let (files, skipped) = ClipboardWatcher.collectFiles([folder], maxBytes: 5_000_000)
        XCTAssertEqual(skipped, 0)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.name, folder.lastPathComponent + ".zip")
        // Zip magic: PK
        XCTAssertEqual(files.first?.data.prefix(2), Data([0x50, 0x4B]))
    }

    func testHugeFolderIsSkippedAndCounted() throws {
        let folder = try makeFolder(files: [("big.bin", 2_000_000)])
        defer { try? FileManager.default.removeItem(at: folder) }

        // Cap far below the content (and below content/4) → skipped, no zip work.
        let (files, skipped) = ClipboardWatcher.collectFiles([folder], maxBytes: 10_000)
        XCTAssertTrue(files.isEmpty)
        XCTAssertEqual(skipped, 1)
    }

    func testOversizedFileCountsAsSkipped() throws {
        let dir = FileManager.default.temporaryDirectory
        let small = dir.appendingPathComponent("tc-small-\(UUID().uuidString).txt")
        let big = dir.appendingPathComponent("tc-big-\(UUID().uuidString).bin")
        try Data("ok".utf8).write(to: small)
        try Data(repeating: 1, count: 60_000).write(to: big)
        defer { try? FileManager.default.removeItem(at: small); try? FileManager.default.removeItem(at: big) }

        let (files, skipped) = ClipboardWatcher.collectFiles([small, big], maxBytes: 10_000)
        XCTAssertEqual(files.map(\.name), [small.lastPathComponent])
        XCTAssertEqual(skipped, 1)
    }

    func testAIEndpointSchemeRules() {
        func ok(_ s: String) -> Bool { AIClient.isAcceptableEndpoint(URL(string: s)!) }
        XCTAssertTrue(ok("https://api.anthropic.com/v1/chat/completions"))
        XCTAssertTrue(ok("http://localhost:11434/v1/chat/completions"))
        XCTAssertTrue(ok("http://127.0.0.1:1234/v1/chat/completions"))
        XCTAssertTrue(ok("http://mini.local:11434/v1/chat/completions"))
        XCTAssertTrue(ok("http://192.168.3.20:11434/v1/chat/completions"))
        XCTAssertTrue(ok("http://172.20.1.9:8080/v1/chat/completions"))
        XCTAssertFalse(ok("http://api.example.com/v1/chat/completions"), "key would cross the internet in the clear")
        XCTAssertFalse(ok("http://172.10.1.9:8080/x"), "172.10.x is public space")
        XCTAssertFalse(ok("ftp://example.com/x"))
    }

    func testPrivacyHoldPausesAICleanup() {
        let model = PickerModel(onPickHistory: { _ in }, onPullPeer: { _ in }, onDropFiles: { _ in },
                                onDeleteHistory: { _ in }, onClose: {})
        model.privacyHold = true
        model.startCompose()
        model.composeText = "sensitive words"
        var called = false
        model.makeCleanupStream = { _, _ in called = true; return nil }
        model.runCleanup()
        XCTAssertFalse(called, "no AI call may be attempted during privacy hold")
        XCTAssertTrue(model.composeError?.contains("Privacy hold") == true)
    }
}

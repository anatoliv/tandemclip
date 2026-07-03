import XCTest
@testable import tandemclip

/// LIVE verification against a real local Ollama endpoint. Not part of the
/// normal suite — run explicitly:
///   OLLAMA=1 swift test --filter AILiveEndpointVerify
/// Skips itself when OLLAMA isn't set so CI/normal runs never depend on it.
/// Uses only synthetic text; nothing from the real clipboard.
final class AILiveEndpointVerify: XCTestCase {
    private let endpoint = "http://localhost:11434/v1/chat/completions"
    private let model = "llama3.2:latest"

    private func liveClient() throws -> AIClient {
        guard ProcessInfo.processInfo.environment["OLLAMA"] == "1" else {
            throw XCTSkip("set OLLAMA=1 to run live endpoint verification")
        }
        return AIClient(endpoint: URL(string: endpoint)!, model: model, apiKey: "")
    }

    /// Build a PickerModel wired to the real endpoint exactly like the
    /// controller does (preset + changelog for cleanup; summarize preset; ask
    /// with supplied context).
    private func liveModel(_ client: AIClient, history: [HistoryItem] = []) -> PickerModel {
        let m = PickerModel(onPickHistory: { _ in }, onPullPeer: { _ in }, onDropFiles: { _ in },
                            onDeleteHistory: { _ in }, onClose: {})
        m.aiConfigured = true
        m.makeCleanupStream = { text, preset in
            client.stream([.init(role: .system, content: preset.prompt + "\n\n" + AIClient.changesInstruction),
                           .init(role: .user, content: text)])
        }
        m.makeSummaryStream = { text in
            client.stream([.init(role: .system, content: AIPreset.bundled[4].prompt),
                           .init(role: .user, content: text)])
        }
        m.makeAskStream = { question in
            let context = history.enumerated().map { i, it in
                "[\(i + 1)] from \(it.source): \(it.snapshot.plainText ?? it.label)"
            }.joined(separator: "\n\n")
            let system = "You answer using ONLY the clips below. If not present, say so. Cite [n]. No preamble."
            return (client.stream([.init(role: .system, content: system),
                                   .init(role: .user, content: "QUESTION: \(question)\n\nCLIPS:\n\(context)")]),
                    history.map { String($0.label.prefix(28)) })
        }
        return m
    }

    private func drainCompose(_ m: PickerModel, timeout: TimeInterval = 90) {
        let e = expectation(description: "compose")
        Task { @MainActor in
            while m.composeBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
            e.fulfill()
        }
        wait(for: [e], timeout: timeout)
    }

    // 1. Raw connectivity + the exact probe Settings → Test Connection sends.
    func testProbe() async throws {
        let client = try liveClient()
        let reply = try await client.complete([.init(role: .user, content: "Reply with the single word OK.")])
        print("── PROBE reply:", reply.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(reply.uppercased().contains("OK"))
    }

    // 2. Cleanup — real rewrite + §§CHANGES§§ parsing through the model.
    func testCleanup() async throws {
        let client = try liveClient()
        let m = liveModel(client)
        m.startCompose()
        m.composeText = "so basically we need to like ship the thing by fridya, and um make sure the tests pass ok"
        m.runCleanup()
        drainCompose(m)
        print("── CLEANUP result:", m.composeText)
        print("── CLEANUP changelog:", m.composeChanges ?? "(none)")
        XCTAssertFalse(m.composeText.contains("§§CHANGES§§"), "sentinel must be stripped")
        XCTAssertNil(m.composeError)
        XCTAssertGreaterThan(m.composeText.count, 10)
    }

    // 3. Summarize — long text → short summary via the preview-card path.
    func testSummarize() async throws {
        let client = try liveClient()
        let long = HistoryItem(snapshot: ClipSnapshot(parts: [.text: Data("""
            The quarterly review covered three areas. First, revenue grew 12% driven by the new \
            enterprise tier. Second, churn dropped to 3% after the onboarding redesign. Third, the \
            mobile app shipped on schedule but crash rates need attention next sprint. Action items: \
            hire two support engineers, fix the top three crashes, and prepare the board deck.
            """.utf8)]), hash: "sum1", timestamp: 0, label: "quarterly review", source: "Home")
        let m = liveModel(client)
        let e = expectation(description: "summary")
        m.summarize(long)
        Task { @MainActor in
            while m.summarizingHash != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            e.fulfill()
        }
        wait(for: [e], timeout: 90)
        print("── SUMMARY:", m.summaries[long.hash] ?? "(none)")
        XCTAssertNotNil(m.summaries[long.hash])
        XCTAssertGreaterThan(m.summaries[long.hash]?.count ?? 0, 10)
    }

    // 4. Ask your clipboard — grounded answer from supplied clips.
    func testAsk() async throws {
        let client = try liveClient()
        let clips = [
            HistoryItem(snapshot: ClipSnapshot(parts: [.text: Data("Office door code is 4471#".utf8)]),
                        hash: "c1", timestamp: 0, label: "Office door code is 4471#", source: "Home"),
            HistoryItem(snapshot: ClipSnapshot(parts: [.text: Data("Wifi password: sunflower-garden-88".utf8)]),
                        hash: "c2", timestamp: 0, label: "Wifi password", source: "Home"),
        ]
        let m = liveModel(client, history: clips)
        m.startCompose()
        m.composeText = "what is the door code?"
        m.askClipboard()
        let e = expectation(description: "ask")
        Task { @MainActor in
            while m.askBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
            e.fulfill()
        }
        wait(for: [e], timeout: 90)
        print("── ASK answer:", m.askAnswer ?? "(none)")
        print("── ASK sources:", m.askSources)
        XCTAssertTrue(m.askAnswer?.contains("4471") == true, "should find the code in the clips")
    }

    // 5. Smart title — engine's exact prompt + sanitizer against a real model.
    func testSmartTitle() async throws {
        let client = try liveClient()
        let prompt = """
            Give this text a short title of 3-7 words in Title Case that captures \
            what it is. Output only the title - no quotes, no trailing punctuation.
            """
        let body = "Steps to reset the staging database, re-seed test users, and re-run the migration suite before the Friday demo."
        let raw = try await client.complete([.init(role: .system, content: prompt),
                                             .init(role: .user, content: body)])
        let title = SyncEngine.sanitizeTitle(raw)
        print("── TITLE raw:", raw.trimmingCharacters(in: .whitespacesAndNewlines))
        print("── TITLE sanitized:", title)
        XCTAssertGreaterThan(title.count, 3)
        XCTAssertLessThanOrEqual(title.count, 60)
        XCTAssertFalse(title.contains("\n"))
    }

    // 6. Translate — on-device detection + real translation via the preset.
    func testTranslate() async throws {
        let client = try liveClient()
        let spanish = "Reunión mañana a las diez en la oficina principal. Traigan las diapositivas."
        XCTAssertEqual(SyncEngine.dominantLanguage(of: spanish), "es")
        let translated = try await client.complete([
            .init(role: .system, content: AIPreset.bundled[5].prompt),   // Translate to English
            .init(role: .user, content: spanish),
        ])
        print("── TRANSLATE:", translated.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(translated.lowercased().contains("office") || translated.lowercased().contains("meeting"),
                      "English translation should mention office/meeting")
    }
}

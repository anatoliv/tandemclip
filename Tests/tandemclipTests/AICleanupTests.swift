import XCTest
@testable import tandemclip

final class AICleanupTests: XCTestCase {
    // MARK: Client wire format

    func testRequestShapeMatchesOpenAICompat() async throws {
        let client = AIClient(endpoint: URL(string: "https://api.example.com/v1/chat/completions")!,
                              model: "test-model", apiKey: "sk-123")
        let req = try await client.makeRequest([
            .init(role: .system, content: "clean it"),
            .init(role: .user, content: "the text"),
        ], stream: true)

        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-123")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "test-model")
        XCTAssertEqual(body?["stream"] as? Bool, true)
        let messages = body?["messages"] as? [[String: String]]
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?.first?["role"], "system")
        // Deliberately minimal, like tonebox: no temperature / max_tokens.
        XCTAssertNil(body?["temperature"])
        XCTAssertNil(body?["max_tokens"])
    }

    func testNoAuthHeaderForLocalServers() async throws {
        let client = AIClient(endpoint: URL(string: "http://localhost:11434/v1/chat/completions")!,
                              model: "llama3.2:3b", apiKey: "")
        let req = try await client.makeRequest([.init(role: .user, content: "hi")], stream: false)
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    func testAzureUsesApiKeyHeaderNotBearer() async throws {
        let client = AIClient(endpoint: URL(string: "https://x.openai.azure.com/openai/deployments/d/chat/completions?api-version=2024-10-21")!,
                              model: "gpt-4o", auth: .azureApiKey("az-key"))
        let req = try await client.makeRequest([.init(role: .user, content: "hi")], stream: true)
        XCTAssertEqual(req.value(forHTTPHeaderField: "api-key"), "az-key")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    func testDecodeResponsesDeltaParsesCodexEvent() {
        let event = #"{"type":"response.output_text.delta","delta":"Hi"}"#
        XCTAssertEqual(AIClient.decodeResponsesDelta(event), "Hi")
        // Non-text events (created/completed/reasoning) yield nothing.
        XCTAssertNil(AIClient.decodeResponsesDelta(#"{"type":"response.created"}"#))
    }

    func testDecodeDeltaParsesChatChunk() {
        let chunk = #"{"choices":[{"delta":{"content":"Hel"}}]}"#
        XCTAssertEqual(AIClient.decodeDelta(chunk), "Hel")
        XCTAssertNil(AIClient.decodeDelta(#"{"choices":[{"delta":{}}]}"#))
        XCTAssertNil(AIClient.decodeDelta("not json"))
    }

    func testServerDetailExtraction() {
        XCTAssertEqual(AIClient.serverDetail(from: #"{"error":{"message":"invalid model"}}"#), "invalid model")
        XCTAssertEqual(AIClient.serverDetail(from: #"{"detail":"quota exceeded"}"#), "quota exceeded")
        XCTAssertNil(AIClient.serverDetail(from: "<html>oops</html>"))
    }

    // MARK: Config

    func testAIConfigDefaultsAndPresets() {
        let config = Config()
        let savedEnabled = config.aiEnabled
        let savedPresets = config.aiPresets
        defer { config.aiEnabled = savedEnabled; config.aiPresets = savedPresets }

        config.aiEnabled = false
        XCTAssertNil(AIClient.fromConfig(config), "client must be nil while disabled")

        // Bundled presets are the seed; edits round-trip through defaults.
        XCTAssertEqual(AIPreset.bundled.first?.id, "cleanup")
        XCTAssertTrue(Config.defaultAICleanupPrompt.contains("Output only the cleaned text"))
        var presets = config.aiPresets
        presets[0].prompt = "customized"
        config.aiPresets = presets
        XCTAssertEqual(config.aiPresets[0].prompt, "customized")
        XCTAssertEqual(config.aiPresets.count, AIPreset.bundled.count)
    }

    func testChangesSentinelSplit() {
        let (body, changes) = AIClient.splitChanges("Clean text here.\n§§CHANGES§§\nFixed grammar and typos.")
        XCTAssertEqual(body, "Clean text here.")
        XCTAssertEqual(changes, "Fixed grammar and typos.")

        // Partial stream that hasn't reached the sentinel yet.
        let partial = AIClient.splitChanges("Clean text so f")
        XCTAssertEqual(partial.body, "Clean text so f")
        XCTAssertNil(partial.changes)
    }

    func testRetryPredicateMatchesToneboxRules() {
        XCTAssertTrue(AIClient.isRetryable(AIClient.AIError.httpStatus(429, "")))
        XCTAssertTrue(AIClient.isRetryable(AIClient.AIError.httpStatus(503, "")))
        XCTAssertTrue(AIClient.isRetryable(URLError(.timedOut)))
        XCTAssertFalse(AIClient.isRetryable(AIClient.AIError.httpStatus(401, "")), "bad key must not fail over")
        XCTAssertFalse(AIClient.isRetryable(AIClient.AIError.httpStatus(404, "")))
        XCTAssertFalse(AIClient.isRetryable(URLError(.cancelled)))
    }

    func testAutoToneClassification() {
        XCTAssertEqual(AIAutoTone.destination(forBundleID: "com.apple.mail"), .email)
        XCTAssertEqual(AIAutoTone.destination(forBundleID: "com.tinyspeck.slackmacgap"), .chat)
        XCTAssertEqual(AIAutoTone.destination(forBundleID: "com.googlecode.iterm2"), .codeOrTerminal)
        XCTAssertEqual(AIAutoTone.destination(forBundleID: "md.obsidian"), .notes)
        XCTAssertNil(AIAutoTone.destination(forBundleID: "com.apple.Safari"))
        XCTAssertNil(AIAutoTone.destination(forBundleID: nil))
        XCTAssertNotNil(AIAutoTone.instruction(forBundleID: "com.apple.mail"))
    }

    // MARK: Compose flow (stubbed stream, no network)

    private func makeModel() -> PickerModel {
        PickerModel(onPickHistory: { _ in }, onPullPeer: { _ in }, onDropFiles: { _ in },
                    onDeleteHistory: { _ in }, onClose: {})
    }

    func testCleanupStreamsIntoEditorAndUndoRestores() {
        let model = makeModel()
        model.startCompose()
        model.composeText = "teh original text"
        model.makeCleanupStream = { _, _ in
            AsyncThrowingStream { c in
                c.yield("The ")
                c.yield("original ")
                c.yield("text.")
                c.finish()
            }
        }
        model.runCleanup()
        let done = expectation(description: "stream drained")
        Task { @MainActor in
            while model.composeBusy { try? await Task.sleep(nanoseconds: 20_000_000) }
            done.fulfill()
        }
        wait(for: [done], timeout: 3)

        XCTAssertEqual(model.composeText, "The original text.")
        XCTAssertNil(model.composeError)
        model.undoCleanup()
        XCTAssertEqual(model.composeText, "teh original text")

        // Closing/cancelling compose discards the draft.
        model.endCompose()
        XCTAssertEqual(model.composeText, "")
        XCTAssertFalse(model.composing)
    }

    func testCleanupFailureRestoresOriginalAndSurfacesError() {
        let model = makeModel()
        model.startCompose()
        model.composeText = "keep me safe"
        model.makeCleanupStream = { _, _ in
            AsyncThrowingStream { c in
                c.yield("partial")
                c.finish(throwing: URLError(.timedOut))
            }
        }
        model.runCleanup()
        let done = expectation(description: "stream failed")
        Task { @MainActor in
            while model.composeBusy { try? await Task.sleep(nanoseconds: 20_000_000) }
            done.fulfill()
        }
        wait(for: [done], timeout: 3)

        XCTAssertEqual(model.composeText, "keep me safe", "failure must never lose the user's words")
        XCTAssertNotNil(model.composeError)
    }

    func testCleanupParsesChangelogSentinelIntoChangesLine() {
        let model = makeModel()
        model.startCompose()
        model.composeText = "raw"
        model.makeCleanupStream = { _, _ in
            AsyncThrowingStream { c in
                c.yield("Nice text.")
                c.yield("\n§§CHANGES§§\nFixed grammar.")
                c.finish()
            }
        }
        model.runCleanup()
        let done = expectation(description: "drained")
        Task { @MainActor in
            while model.composeBusy { try? await Task.sleep(nanoseconds: 20_000_000) }
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(model.composeText, "Nice text.", "sentinel tail must never reach the editor")
        XCTAssertEqual(model.composeChanges, "Fixed grammar.")
    }

    func testCleanUpItemOpensComposeWithClipText() {
        let model = makeModel()
        let snap = ClipSnapshot(parts: [.text: Data("clip words".utf8)])
        let item = HistoryItem(snapshot: snap, hash: "h", timestamp: 0, label: "clip words", source: "Home")
        model.makeCleanupStream = { text, preset in
            XCTAssertEqual(text, "clip words")
            XCTAssertEqual(preset.id, "cleanup")   // default selected preset
            return AsyncThrowingStream { c in c.yield("Clip words."); c.finish() }
        }
        model.cleanUpItem(item)
        XCTAssertTrue(model.composing)
        let done = expectation(description: "drained")
        Task { @MainActor in
            while model.composeBusy { try? await Task.sleep(nanoseconds: 20_000_000) }
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(model.composeText, "Clip words.")
    }

    func testCleanupWithoutAIConfiguredPointsAtSettings() {
        let model = makeModel()
        model.startCompose()
        model.composeText = "something"
        model.makeCleanupStream = { _, _ in nil }   // what the controller returns when unconfigured
        model.runCleanup()
        XCTAssertEqual(model.composeError, "Set up AI cleanup in Settings → AI first.")
    }
}

extension AICleanupTests {
    func testAskClipboardStreamsAnswerWithSources() {
        let model = makeModel()
        model.startCompose()
        model.composeText = "what was the wifi password?"
        model.makeAskStream = { question in
            XCTAssertTrue(question.contains("wifi"))
            return (AsyncThrowingStream { c in c.yield("It was "); c.yield("hunter2 [1]."); c.finish() },
                    ["router setup notes"])
        }
        model.askClipboard()
        let done = expectation(description: "answer")
        Task { @MainActor in
            while model.askBusy { try? await Task.sleep(nanoseconds: 20_000_000) }
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(model.askAnswer, "It was hunter2 [1].")
        XCTAssertEqual(model.askSources, ["router setup notes"])

        model.clearAsk()
        XCTAssertNil(model.askAnswer)

        // Privacy hold gates Ask like every other AI call.
        let held = makeModel()
        held.privacyHold = true
        held.startCompose()
        held.composeText = "anything"
        var called = false
        held.makeAskStream = { _ in called = true; return nil }
        held.askClipboard()
        XCTAssertFalse(called)
        XCTAssertTrue(held.composeError?.contains("Privacy hold") == true)
    }
}

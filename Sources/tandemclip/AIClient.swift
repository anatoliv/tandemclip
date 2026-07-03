import Foundation

/// Minimal LLM client for the AI text-cleanup feature, modeled on tonebox's
/// LLMClient: hand-rolled URLSession against the OpenAI-compatible
/// `/v1/chat/completions` wire format so one client serves OpenAI, Anthropic
/// (compat shim), OpenRouter, Groq, Ollama, LM Studio, … No vendor SDK, no
/// temperature/max_tokens — defaults + prompt engineering, like tonebox.
/// Calls go straight from this Mac to the configured endpoint; nothing is
/// proxied.
struct AIClient {
    struct Message: Codable {
        enum Role: String, Codable { case system, user, assistant }
        let role: Role
        let content: String
    }

    enum AIError: LocalizedError {
        case notConfigured
        case httpStatus(Int, String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Set the AI endpoint and key in Settings → AI first."
            case let .httpStatus(code, detail):
                return AIClient.friendlyHTTPMessage(code: code, detail: detail)
            case .emptyResponse:
                return "The AI returned an empty response — try again or check the model name."
            }
        }
    }

    let endpoint: URL
    let model: String
    let apiKey: String   // empty is fine for local servers (Ollama, LM Studio)

    /// Built from config; nil until the user has configured an endpoint+model.
    static func fromConfig(_ config: Config) -> AIClient? {
        guard config.aiEnabled,
              let url = URL(string: config.aiEndpoint), url.scheme != nil,
              !config.aiModel.isEmpty else { return nil }
        return AIClient(endpoint: url, model: config.aiModel, apiKey: config.aiAPIKey)
    }

    // Generous per-token gap for cold local models; hard cap on the whole call.
    // (Same budgets as tonebox.)
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 600
        return URLSession(configuration: c)
    }()

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
    }

    func makeRequest(_ messages: [Message], stream: Bool) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(ChatRequest(model: model, messages: messages, stream: stream))
        return request
    }

    /// Stream token deltas (SSE). Yields each delta string as it arrives.
    func stream(_ messages: [Message]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(messages, stream: true)
                    let (bytes, response) = try await Self.session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line + "\n"
                            if body.count > 4096 { break }
                        }
                        throw AIError.httpStatus(http.statusCode, body)
                    }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let delta = Self.decodeDelta(payload) { continuation.yield(delta) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Drain the stream into a single string (for probes and short calls).
    func complete(_ messages: [Message]) async throws -> String {
        var out = ""
        for try await delta in stream(messages) { out += delta }
        guard !out.isEmpty else { throw AIError.emptyResponse }
        return out
    }

    /// Decode one SSE chunk: `choices[0].delta.content`.
    static func decodeDelta(_ payload: String) -> String? {
        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta?
            }
            let choices: [Choice]?
        }
        guard let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(Chunk.self, from: data)
        else { return nil }
        return chunk.choices?.first?.delta?.content
    }

    /// Map failures to actionable text (tonebox's friendlyMessage, condensed).
    static func friendlyMessage(for error: Error) -> String {
        if let e = error as? AIError { return e.errorDescription ?? "AI request failed." }
        if let e = error as? URLError {
            switch e.code {
            case .cannotConnectToHost, .cannotFindHost:
                return "Can't reach the AI server — check the endpoint URL (is the local server running?)."
            case .notConnectedToInternet: return "No internet connection."
            case .timedOut: return "The AI server timed out — try again or pick a faster model."
            case .cancelled: return "Cancelled."
            default: break
            }
        }
        return error.localizedDescription
    }

    private static func friendlyHTTPMessage(code: Int, detail: String) -> String {
        let hint = Self.serverDetail(from: detail).map { " (\($0))" } ?? ""
        switch code {
        case 401, 403: return "The AI server rejected the key — update it in Settings → AI\(hint)."
        case 404: return "Model or endpoint not found — check the model name and URL\(hint)."
        case 429: return "Rate limited by the AI server — wait a moment and try again\(hint)."
        case 500...599: return "The AI server had an internal error (\(code)) — try again\(hint)."
        default: return "AI request failed (HTTP \(code))\(hint)."
        }
    }

    /// Pull `error.message` / `detail` out of a JSON error body, if present.
    static func serverDetail(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { return String(msg.prefix(120)) }
        if let detail = obj["detail"] as? String { return String(detail.prefix(120)) }
        return nil
    }
}

extension AIClient {
    /// Fallback endpoint (tonebox pattern): retried once when the primary
    /// fails with a *retryable* error before producing any output. Mid-stream
    /// failover is deliberately avoided — it would splice two answers.
    static func fallbackFromConfig(_ config: Config) -> AIClient? {
        guard let url = URL(string: config.aiFallbackEndpoint), url.scheme != nil,
              !config.aiFallbackModel.isEmpty else { return nil }
        return AIClient(endpoint: url, model: config.aiFallbackModel, apiKey: config.aiFallbackAPIKey)
    }

    /// Retry on rate limits, server errors, and network trouble; never on
    /// config problems (bad key, wrong model/URL) — those fail the same way
    /// everywhere. Same predicate as tonebox's shouldFallback.
    static func isRetryable(_ error: Error) -> Bool {
        if let e = error as? AIError, case let .httpStatus(code, _) = e {
            return code == 429 || (500...599).contains(code)
        }
        if error is URLError { return (error as? URLError)?.code != .cancelled }
        return false
    }

    /// Stream from `primary`; if it fails retryably *before any token arrived*
    /// and a fallback is configured, restart the whole call there.
    static func streamWithFallback(primary: AIClient, fallback: AIClient?,
                                   messages: [Message]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var yieldedAny = false
                do {
                    for try await delta in primary.stream(messages) {
                        yieldedAny = true
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    guard !yieldedAny, let fallback, isRetryable(error) else {
                        continuation.finish(throwing: error); return
                    }
                    Log.trace("ai", "primary failed retryably — trying fallback endpoint")
                    do {
                        for try await delta in fallback.stream(messages) { continuation.yield(delta) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Changelog sentinel (tonebox's §§CHANGES§§ provenance trick)

    /// Appended to every cleanup system prompt: the model emits the rewrite,
    /// then a sentinel line, then a one-sentence changelog the UI shows
    /// separately.
    static let changesInstruction = """
        After the rewritten text, output a line containing exactly §§CHANGES§§, \
        and after it ONE short sentence naming what you changed (e.g. grammar, \
        structure, tone). Never claim to have added information.
        """

    static let changesSentinel = "§§CHANGES§§"

    /// Split a (possibly partial) response into the visible body and the
    /// changelog tail. Safe to call on every streamed accumulation.
    static func splitChanges(_ text: String) -> (body: String, changes: String?) {
        guard let range = text.range(of: changesSentinel) else { return (text, nil) }
        let body = String(text[..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = String(text[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (body, tail.isEmpty ? nil : tail)
    }
}

/// A named prompt preset for the compose area (tonebox's VoiceMode pattern):
/// user-editable, persisted as JSON, seeded with a bundled set.
struct AIPreset: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var prompt: String

    static let bundled: [AIPreset] = [
        .init(id: "cleanup", name: "Clean up", prompt: Config.defaultAICleanupPrompt),
        .init(id: "email", name: "Email reply",
              prompt: "Tighten this into a polite, professional email reply. Keep the writer's voice. Do not add a greeting or sign-off unless the text has one. Output only the email text."),
        .init(id: "chat", name: "Casual chat",
              prompt: "Rewrite this as a casual, concise chat message — conversational, no greeting or sign-off, keep the meaning and voice. Output only the message."),
        .init(id: "commit", name: "Commit message",
              prompt: "Rewrite this as a good git commit message: an imperative summary line under 70 characters, then (only if the text warrants it) a blank line and a short body explaining why. Do not invent details. Output only the commit message."),
        .init(id: "summarize", name: "Summarize",
              prompt: "Summarize this text in a few short sentences (or a short bullet list if it enumerates items). Keep only what matters; do not add information. Output only the summary."),
        .init(id: "translate", name: "Translate to English",
              prompt: "Translate this text into natural, fluent English, preserving meaning, tone, and formatting. If it is already English, just clean it up minimally. Output only the translation."),
    ]
}

/// Classify the app the user was in when they opened the picker and steer the
/// rewrite's tone accordingly — tonebox's auto-tone-by-destination pattern.
enum AIAutoTone {
    enum Destination { case email, chat, codeOrTerminal, notes }

    static func destination(forBundleID id: String?) -> Destination? {
        guard let id = id?.lowercased(), !id.isEmpty else { return nil }
        let email: Set<String> = ["com.apple.mail", "com.microsoft.outlook",
                                  "com.readdle.smartemail-mac", "com.superhuman.mail"]
        let chat: Set<String> = ["com.tinyspeck.slackmacgap", "com.hnc.discord",
                                 "ru.keepcoder.telegram", "com.apple.mobilesms",
                                 "net.whatsapp.whatsapp", "com.microsoft.teams2"]
        let code: Set<String> = ["com.apple.dt.xcode", "com.microsoft.vscode",
                                 "com.googlecode.iterm2", "com.apple.terminal",
                                 "dev.zed.zed", "com.jetbrains.intellij", "com.sublimetext.4"]
        let notes: Set<String> = ["com.apple.notes", "md.obsidian", "net.shinyfrog.bear",
                                  "com.agiletortoise.drafts-osx", "notion.id"]
        if email.contains(id) || id.contains("mail") { return .email }
        if chat.contains(id) || id.contains("slack") || id.contains("discord")
            || id.contains("telegram") || id.contains("messages") { return .chat }
        if code.contains(id) || id.contains("terminal") || id.contains("iterm")
            || id.contains("jetbrains") { return .codeOrTerminal }
        if notes.contains(id) || id.contains("notes") || id.contains("obsidian") { return .notes }
        return nil
    }

    /// Tone instruction appended to the system prompt (nil = no steer).
    static func instruction(forBundleID id: String?) -> String? {
        switch destination(forBundleID: id) {
        case .email:
            return "The result will be pasted into an EMAIL. Use a clear, professional tone in proper sentences and paragraphs. Do not add a greeting or sign-off unless the text has one."
        case .chat:
            return "The result will be pasted into a CHAT / messaging app. Keep it casual, concise, and conversational — no greeting or sign-off."
        case .codeOrTerminal:
            return "The result will be pasted into a CODE EDITOR or TERMINAL. Keep it literal and minimal — do not add prose, capitalization, or punctuation the text didn't have."
        case .notes:
            return "The result will be pasted into a NOTES or document app. Produce clean prose with light structure (short paragraphs; a bullet list only if the text clearly enumerates items)."
        case nil:
            return nil
        }
    }
}

/// Provider presets (endpoint + a sensible cheap default model), mirroring
/// tonebox's curated list. Picking one fills the endpoint/model fields; the
/// key always comes from the user.
struct AIProviderPreset: Identifiable {
    let id: String
    let name: String
    let endpoint: String
    let model: String

    static let all: [AIProviderPreset] = [
        .init(id: "anthropic", name: "Anthropic Claude",
              endpoint: "https://api.anthropic.com/v1/chat/completions",
              model: "claude-haiku-4-5-20251001"),
        .init(id: "openai", name: "OpenAI",
              endpoint: "https://api.openai.com/v1/chat/completions",
              model: "gpt-4o-mini"),
        .init(id: "openrouter", name: "OpenRouter",
              endpoint: "https://openrouter.ai/api/v1/chat/completions",
              model: "openrouter/auto"),
        .init(id: "groq", name: "Groq",
              endpoint: "https://api.groq.com/openai/v1/chat/completions",
              model: "llama-3.3-70b-versatile"),
        .init(id: "ollama", name: "Ollama (local)",
              endpoint: "http://localhost:11434/v1/chat/completions",
              model: "llama3.2:3b"),
        .init(id: "lmstudio", name: "LM Studio (local)",
              endpoint: "http://localhost:1234/v1/chat/completions",
              model: ""),
    ]
}

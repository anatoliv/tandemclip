import Foundation
import Network

/// One-shot localhost HTTP server for the OAuth redirect step. Listens on
/// `127.0.0.1:1455` (the only port OpenAI's Hydra allow-list accepts for the
/// Codex client), parses `?code=…&state=…` out of the browser's GET, returns
/// a small "you can close this window" page, and resolves the awaiting async
/// call.
///
/// **Design.** All mutable state is touched exclusively on the dedicated
/// `queue`, which is why the class is `@unchecked Sendable` — the contract is
/// enforced by every method dispatching onto `queue` before touching
/// `listener` / `continuation`.
///
/// **Lifetime.** One instance handles exactly one callback then tears down.
/// The caller can abort via `cancel()` (used when the sign-in sheet closes
/// before the browser redirects).
final class CodexCallbackServer: @unchecked Sendable {
    struct CallbackResult: Sendable, Equatable {
        let code: String
        let state: String
    }

    enum CallbackError: Error, LocalizedError {
        case portBusy(String)
        case missingQueryParams
        case authorizeError(String, String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case let .portBusy(detail):
                return "Couldn't open the local sign-in port (1455). \(detail)"
            case .missingQueryParams:
                return "Sign-in returned without a code or state parameter."
            case let .authorizeError(code, description):
                return "Sign-in was rejected: \(code) — \(description)"
            case .cancelled:
                return "Sign-in was cancelled."
            }
        }
    }

    private let queue = DispatchQueue(label: "com.tandemclip.codex-oauth-callback")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<CallbackResult, any Error>?

    /// Starts the listener and suspends until the browser redirects back, the
    /// user cancels, or the listener fails (port busy). Throws on failure;
    /// never returns nil.
    func awaitCallback() async throws -> CallbackResult {
        try await withCheckedThrowingContinuation { cc in
            queue.async { [weak self] in
                guard let self else {
                    cc.resume(throwing: CallbackError.cancelled)
                    return
                }
                self.continuation = cc
                do {
                    let port = NWEndpoint.Port(rawValue: CodexOAuth.callbackPort)!
                    let listener = try NWListener(using: .tcp, on: port)
                    self.listener = listener
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.handle(connection)
                    }
                    listener.stateUpdateHandler = { [weak self] state in
                        if case let .failed(error) = state {
                            self?.shutdown(.failure(CallbackError.portBusy(error.localizedDescription)))
                        }
                    }
                    listener.start(queue: self.queue)
                } catch {
                    self.continuation = nil
                    cc.resume(throwing: CallbackError.portBusy(error.localizedDescription))
                }
            }
        }
    }

    /// Aborts the listen. Idempotent — safe to call twice or after success.
    func cancel() {
        queue.async { [weak self] in
            self?.shutdown(.failure(CallbackError.cancelled))
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        // 64KB cap so a misbehaving client can't make us spin on receive().
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { return }
            guard let data, let request = String(data: data, encoding: .utf8) else {
                self.respond(on: connection, status: "400 Bad Request", body: "<h1>Bad request</h1>")
                return
            }
            self.processRequest(request, on: connection)
        }
    }

    private func processRequest(_ request: String, on connection: NWConnection) {
        // First line: "GET /auth/callback?code=X&state=Y HTTP/1.1"
        guard let firstLineRange = request.range(of: "\r\n") else {
            respond(on: connection, status: "400 Bad Request", body: "<h1>Bad request</h1>")
            return
        }
        let firstLine = request[..<firstLineRange.lowerBound]
        let parts = firstLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else {
            respond(on: connection, status: "400 Bad Request", body: "<h1>Bad request</h1>")
            return
        }
        let path = String(parts[1])
        guard let components = URLComponents(string: "http://localhost\(path)"),
              let items = components.queryItems
        else {
            respond(on: connection, status: "400 Bad Request", body: "<h1>Bad request</h1>")
            return
        }

        if let errCode = items.first(where: { $0.name == "error" })?.value {
            let desc = items.first(where: { $0.name == "error_description" })?.value ?? ""
            respond(on: connection, status: "200 OK", body: errorPage(code: errCode, description: desc))
            shutdown(.failure(CallbackError.authorizeError(errCode, desc)))
            return
        }

        guard
            let code = items.first(where: { $0.name == "code" })?.value,
            let state = items.first(where: { $0.name == "state" })?.value
        else {
            respond(on: connection, status: "400 Bad Request", body: "<h1>Missing parameters</h1>")
            shutdown(.failure(CallbackError.missingQueryParams))
            return
        }

        respond(on: connection, status: "200 OK", body: successPage())
        shutdown(.success(CallbackResult(code: code, state: state)))
    }

    private func respond(on connection: NWConnection, status: String, body: String) {
        let headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(body.utf8.count)",
            "Connection: close",
            "",
            body,
        ]
        let response = headers.joined(separator: "\r\n")
        connection.send(
            content: Data(response.utf8),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    /// Tears the listener down and resolves the suspended caller. Idempotent:
    /// a second call is a no-op so a successful callback followed by a
    /// redundant cancel doesn't crash.
    private func shutdown(_ result: Result<CallbackResult, any Error>) {
        listener?.cancel()
        listener = nil
        guard let cc = continuation else { return }
        continuation = nil
        switch result {
        case let .success(value):
            cc.resume(returning: value)
        case let .failure(error):
            Log.error("codex callback failed: \(error.localizedDescription)")
            cc.resume(throwing: error)
        }
    }

    private func successPage() -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Signed in to TandemClip</title>
        <style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#F8F6F2;color:#3A3A35;padding:40px;max-width:520px;margin:60px auto}h1{font-size:20px;margin:0 0 12px}p{color:#666;margin:0}</style>
        </head><body>
        <h1>Signed in to TandemClip</h1>
        <p>You can close this window and return to the app.</p>
        </body></html>
        """
    }

    private func errorPage(code: String, description: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Sign-in failed</title>
        <style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#F8F6F2;color:#3A3A35;padding:40px;max-width:520px;margin:60px auto}h1{font-size:20px;margin:0 0 12px}p{color:#666;margin:0 0 8px}code{background:#EAE7E0;padding:2px 6px;border-radius:4px}</style>
        </head><body>
        <h1>Sign-in failed</h1>
        <p><code>\(code)</code></p>
        <p>\(description)</p>
        <p>Close this window and try again from TandemClip.</p>
        </body></html>
        """
    }
}

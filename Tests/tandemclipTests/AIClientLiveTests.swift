import XCTest
import Darwin
@testable import tandemclip

/// A minimal localhost HTTP/1.1 server for exercising AIClient's REAL wire
/// path (URLSession.bytes) instead of a stubbed closure — closing the
/// "engine builds its own client, untested end to end" gap. Captures the
/// inbound request so tests can assert the actual bytes we send.
private final class MiniHTTPServer {
    private var listenFD: Int32 = -1
    private(set) var port: UInt16 = 0
    private let respond: (String) -> String
    private(set) var lastRequest = ""
    private let requestLock = NSLock()

    init(_ respond: @escaping (String) -> String) { self.respond = respond }

    func start() throws {
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
        Darwin.listen(listenFD, 4)
        var actual = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listenFD, $0, &len) }
        }
        port = UInt16(bigEndian: actual.sin_port)
        Thread.detachNewThread { [weak self] in self?.serve() }
    }

    private func serve() {
        while listenFD >= 0 {
            let client = accept(listenFD, nil, nil)
            if client < 0 { break }
            // Read the full request: headers, then the Content-Length body,
            // which the client sends in a separate TCP segment.
            var request = ""
            var buf = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = read(client, &buf, buf.count)
                if n <= 0 { break }
                request += String(bytes: buf[0..<n], encoding: .utf8) ?? ""
                if let headerEnd = request.range(of: "\r\n\r\n") {
                    let bodyLen = Self.contentLength(in: request) ?? 0
                    let body = request[headerEnd.upperBound...]
                    if body.utf8.count >= bodyLen { break }
                }
            }
            requestLock.lock(); lastRequest = request; requestLock.unlock()
            let response = respond(request)
            _ = response.withCString { write(client, $0, strlen($0)) }
            close(client)
        }
    }

    private static func contentLength(in request: String) -> Int? {
        for line in request.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            return Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    func request() -> String { requestLock.lock(); defer { requestLock.unlock() }; return lastRequest }
    func stop() { if listenFD >= 0 { close(listenFD); listenFD = -1 } }

    static func http(_ status: String, contentType: String, body: String) -> String {
        "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }
}

final class AIClientLiveTests: XCTestCase {
    private func client(_ server: MiniHTTPServer, key: String = "sk-test") -> AIClient {
        AIClient(endpoint: URL(string: "http://127.0.0.1:\(server.port)/v1/chat/completions")!,
                 model: "test-model", apiKey: key)
    }

    func testStreamsRealSSEResponse() async throws {
        let sse = ["data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}",
                   "data: {\"choices\":[{\"delta\":{\"content\":\", world\"}}]}",
                   "data: [DONE]", ""].joined(separator: "\n")
        let server = MiniHTTPServer { _ in MiniHTTPServer.http("200 OK", contentType: "text/event-stream", body: sse) }
        try server.start(); defer { server.stop() }

        let result = try await client(server).complete([
            .init(role: .system, content: "clean it"),
            .init(role: .user, content: "hi there"),
        ])
        XCTAssertEqual(result, "Hello, world")

        // The REAL request we put on the wire: method, auth, JSON body shape.
        let req = server.request()
        XCTAssertTrue(req.hasPrefix("POST /v1/chat/completions"), req.prefix(40).description)
        XCTAssertTrue(req.contains("Authorization: Bearer sk-test"))
        XCTAssertTrue(req.contains("\"model\":\"test-model\""))
        XCTAssertTrue(req.contains("\"stream\":true"))
        XCTAssertTrue(req.contains("hi there"))
    }

    func testMapsHTTPErrorWithServerDetail() async throws {
        let server = MiniHTTPServer { _ in
            MiniHTTPServer.http("429 Too Many Requests", contentType: "application/json",
                                body: "{\"error\":{\"message\":\"slow down please\"}}")
        }
        try server.start(); defer { server.stop() }

        do {
            _ = try await client(server).complete([.init(role: .user, content: "hi")])
            XCTFail("expected an error")
        } catch {
            let msg = AIClient.friendlyMessage(for: error)
            XCTAssertTrue(msg.contains("Rate limited"), msg)
            XCTAssertTrue(msg.contains("slow down please"), "should surface the server detail: \(msg)")
        }
    }

    func testStreamWithFallbackUsesSecondServerOnRetryableFailure() async throws {
        // Primary returns 503 (retryable) with no body; fallback streams fine.
        let primary = MiniHTTPServer { _ in MiniHTTPServer.http("503 Service Unavailable", contentType: "text/plain", body: "down") }
        let fallback = MiniHTTPServer { _ in
            MiniHTTPServer.http("200 OK", contentType: "text/event-stream",
                                body: "data: {\"choices\":[{\"delta\":{\"content\":\"from fallback\"}}]}\ndata: [DONE]\n")
        }
        try primary.start(); try fallback.start()
        defer { primary.stop(); fallback.stop() }

        var out = ""
        let stream = AIClient.streamWithFallback(
            primary: client(primary), fallback: client(fallback),
            messages: [.init(role: .user, content: "hi")])
        for try await delta in stream { out += delta }
        XCTAssertEqual(out, "from fallback")
    }

    func testNoAuthHeaderWhenKeyEmpty() async throws {
        let server = MiniHTTPServer { _ in
            MiniHTTPServer.http("200 OK", contentType: "text/event-stream",
                                body: "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\ndata: [DONE]\n")
        }
        try server.start(); defer { server.stop() }
        _ = try await client(server, key: "").complete([.init(role: .user, content: "hi")])
        XCTAssertFalse(server.request().contains("Authorization:"), "local servers get no bearer header")
    }
}

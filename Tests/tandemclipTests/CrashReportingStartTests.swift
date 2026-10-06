import Darwin
import Foundation
@_spi(Private) import Sentry
import XCTest
@testable import tandemclip

/// Whether the reporter came up
/// decides `.on` against `.unavailable`, the shipped Options carry the bounded
/// transport, and that transport gives up on a collector that never answers.
/// These drive the production decision (`CrashReporting.startReporter`) with the
/// SDK's real `Options` and DSN parser. Only the SDK's global start and its
/// `isEnabled` are stood in, so nothing installs a crash handler in the test
/// process. The one network test talks only to a listener on 127.0.0.1.
final class CrashReportingStartTests: XCTestCase {
    /// Fake: a well-formed Crashbox-shaped DSN that is never sent to.
    private let dsn = "https://public-key@crashbox.example.test/42"

    /// Thread-safe flag for the "SDK" a test simulates on the main queue.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        func get() -> Bool { lock.withLock { value } }
    }

    /// Runs the real gate around the real decision, as `startSDKOnce` does.
    private func attempt(_ gate: ReportingAttemptGate, dsn: String, starts: inout [Options],
                         setupRan: Bool, enabled: Bool) -> ReportingAttemptGate.Outcome {
        var started: [Options] = []
        let outcome = gate.runOnce {
            try CrashReporting.startReporter(dsn: dsn, start: { started.append($0) },
                                             waitForSetup: { setupRan }, isEnabled: { enabled })
        }
        starts += started
        return outcome
    }

    // MARK: The start decision

    func testAReporterThatComesUpIsOnAndGetsTheShippedOptions() throws {
        let gate = ReportingAttemptGate()
        var starts: [Options] = []
        XCTAssertEqual(attempt(gate, dsn: dsn, starts: &starts, setupRan: true, enabled: true), .started)
        XCTAssertEqual(CrashReporting.status(enabled: true, configured: true, outcome: gate.current()), .on)
        XCTAssertEqual(starts.count, 1)
        let options = try XCTUnwrap(starts.first)
        XCTAssertNotNil(options.parsedDsn, "the SDK's own parser accepts the DSN shape")
        XCTAssertEqual(options.parsedDsn?.url.host, "crashbox.example.test")
        XCTAssertEqual(options.environment, CrashReporting.environment)
        assertShippedWiring(options)
    }

    func testAReporterThatDoesNotEnableIsUnavailableAndDoesNotRetry() {
        let gate = ReportingAttemptGate()
        var starts: [Options] = []
        XCTAssertEqual(attempt(gate, dsn: dsn, starts: &starts, setupRan: true, enabled: false), .failed)
        XCTAssertEqual(CrashReporting.status(enabled: true, configured: true, outcome: gate.current()), .unavailable)
        XCTAssertTrue(CrashReporting.settingsDetail(.unavailable).contains("could not start"))
        XCTAssertEqual(attempt(gate, dsn: dsn, starts: &starts, setupRan: true, enabled: true), .failed,
                       "a failed start must not retry on its own")
        XCTAssertEqual(starts.count, 1)
        gate.resetAfterExplicitDisable()
        XCTAssertEqual(attempt(gate, dsn: dsn, starts: &starts, setupRan: true, enabled: true), .started,
                       "turning it off and on again is the retry Settings offers")
        XCTAssertEqual(starts.count, 2)
    }

    func testASetupThatNeverRunsIsUnavailable() {
        XCTAssertThrowsError(try CrashReporting.startReporter(dsn: dsn, start: { _ in },
                                                              waitForSetup: { false }, isEnabled: { true })) {
            XCTAssertEqual($0 as? CrashReporting.StartFailure, .setupTimedOut)
        }
        let gate = ReportingAttemptGate()
        var starts: [Options] = []
        XCTAssertEqual(attempt(gate, dsn: dsn, starts: &starts, setupRan: false, enabled: true), .failed)
        XCTAssertEqual(CrashReporting.status(enabled: true, configured: true, outcome: gate.current()), .unavailable)
    }

    func testADSNTheSDKRefusesIsUnavailableAndNeverStarted() {
        // No public key: the SDK's DSN parser refuses it. Passed directly, since
        // `dsn(from:)` already refuses this shape before the SDK sees it.
        let refused = "https://crashbox.example.test/42"
        var startCalls = 0
        XCTAssertThrowsError(try CrashReporting.startReporter(dsn: refused, start: { _ in startCalls += 1 },
                                                              waitForSetup: { true }, isEnabled: { true })) {
            XCTAssertEqual($0 as? CrashReporting.StartFailure, .configurationRejected)
        }
        XCTAssertEqual(startCalls, 0)
        let gate = ReportingAttemptGate()
        var starts: [Options] = []
        XCTAssertEqual(attempt(gate, dsn: refused, starts: &starts, setupRan: true, enabled: true), .failed)
        XCTAssertTrue(starts.isEmpty)
        XCTAssertEqual(CrashReporting.status(enabled: true, configured: true, outcome: gate.current()), .unavailable)
    }

    func testAStartInProgressReadsOnNotUnavailable() {
        let gate = ReportingAttemptGate()
        var seenDuringStart: ReportingAttemptGate.Outcome?
        var secondCaller: ReportingAttemptGate.Outcome?
        _ = gate.runOnce {
            seenDuringStart = gate.current()
            secondCaller = gate.runOnce { XCTFail("a concurrent caller must not start a second client") }
        }
        XCTAssertEqual(seenDuringStart, .starting)
        XCTAssertEqual(secondCaller, .starting)
        XCTAssertEqual(CrashReporting.status(enabled: true, configured: true, outcome: .starting), .on,
                       "Settings opened mid-start must not flash the unavailable text")
    }

    func testStatusFollowsConfigurationThenPreferenceThenOutcome() {
        XCTAssertEqual(CrashReporting.status(enabled: true, configured: false, outcome: .failed), .notConfigured)
        XCTAssertEqual(CrashReporting.status(enabled: false, configured: true, outcome: .failed), .off)
        XCTAssertEqual(CrashReporting.status(enabled: true, configured: true, outcome: .idle), .on)
        XCTAssertEqual(CrashReporting.status(enabled: true, configured: true, outcome: .started), .on)
        for status in [CrashReporting.Status.notConfigured, .off, .on, .unavailable] {
            let copy = CrashReporting.settingsDetail(status)
            XCTAssertFalse(copy.contains("\u{2014}") || copy.contains("\u{2013}"), "dash in Settings copy: \(copy)")
        }
    }

    /// The production wait, run as production runs it (off the main thread),
    /// against a stand-in that sets up the way the SDK does: `dispatch_async`
    /// on the main queue from the calling thread.
    func testTheMainQueueWaitSeesSetupQueuedBeforeIt() {
        let enabled = Flag()
        let done = expectation(description: "start finished")
        var result: Result<Void, Error>?
        let dsn = self.dsn
        DispatchQueue.global().async {
            result = Result {
                try CrashReporting.startReporter(dsn: dsn,
                                                 start: { _ in DispatchQueue.main.async { enabled.set() } },
                                                 waitForSetup: { CrashReporting.mainQueueCaughtUp(within: 5) },
                                                 isEnabled: { enabled.get() })
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertNoThrow(try XCTUnwrap(result).get())
    }

    func testTheMainQueueWaitGivesUpWhenTheMainThreadIsStuck() {
        let finished = DispatchSemaphore(value: 0)
        var caughtUp: Bool?
        DispatchQueue.global().async {
            caughtUp = CrashReporting.mainQueueCaughtUp(within: 0.2)
            finished.signal()
        }
        // Hold the main thread, as a hung launch would, until the wait gives up.
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(caughtUp, false)
    }

    // MARK: The Options as shipped

    func testConfigureWiresTheBoundedTransportIntoRealOptions() {
        let options = Options()
        CrashReporting.configure(options, dsn: dsn, environment: "production")
        assertShippedWiring(options)
    }

    private func assertShippedWiring(_ options: Options, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(options.maxCacheItems, UInt(CrashReporting.maximumCachedEnvelopes), file: file, line: line)
        XCTAssertEqual(options.shutdownTimeInterval, CrashReporting.shutdownTimeout, file: file, line: line)
        XCTAssertFalse(options.sendDefaultPii, file: file, line: line)
        XCTAssertEqual(options.maxBreadcrumbs, 0, file: file, line: line)
        guard let session = options.urlSession else {
            return XCTFail("configure() must hand the SDK its own bounded URLSession", file: file, line: line)
        }
        let settings = session.configuration
        XCTAssertEqual(settings.timeoutIntervalForResource, CrashReporting.resourceTimeout, file: file, line: line)
        XCTAssertEqual(settings.timeoutIntervalForResource, 5, file: file, line: line)
        XCTAssertFalse(settings.waitsForConnectivity, file: file, line: line)
        XCTAssertNil(settings.urlCache, file: file, line: line)
        XCTAssertEqual(settings.requestCachePolicy, .reloadIgnoringLocalCacheData, file: file, line: line)
    }

    // MARK: A collector that accepts and never answers

    /// The SDK's own envelope request (sentry-cocoa 8.58.4 sets 15 s on it,
    /// which replaces the session's request timeout) sent through the session
    /// `configure()` ships. Only the resource timeout can end it, so this
    /// measures the bound that actually applies.
    func testASendToACollectorThatNeverAnswersGivesUpWithinTheResourceBound() throws {
        let listener = try BlackHoleListener()
        defer { listener.stop() }

        let options = Options()
        CrashReporting.configure(options, dsn: dsn, environment: "test")
        let session = try XCTUnwrap(options.urlSession)
        let local = try SentryDsn(string: "http://public-key@127.0.0.1:\(listener.port)/42")
        let request = try SentryURLRequestFactory.envelopeRequest(with: local, data: Data(repeating: 0x41, count: 256))
        XCTAssertEqual(request.timeoutInterval, 15, "the SDK's per-request timeout this bound has to beat")

        let done = expectation(description: "send gave up")
        var failure: Error?
        var elapsed: TimeInterval = .infinity
        let began = Date()
        session.dataTask(with: request) { _, _, error in
            elapsed = Date().timeIntervalSince(began)
            failure = error
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: CrashReporting.resourceTimeout + 10)

        XCTAssertGreaterThanOrEqual(listener.acceptedCount, 1, "the listener must have accepted the connection")
        XCTAssertEqual((failure as? URLError)?.code, .timedOut)
        // Absolute, not relative to the setting: the intended bound is 5 s plus
        // one second of slack. The old 10 s setting measured about 10.9 s.
        XCTAssertLessThanOrEqual(elapsed, 6, "gave up after \(elapsed) s")
    }
}

/// A TCP listener on 127.0.0.1 that accepts every connection, never reads and
/// never answers: the shape of a collector that has stopped responding.
private final class BlackHoleListener: @unchecked Sendable {
    /// The accepted connections, held open until `stop()`.
    private final class Accepted: @unchecked Sendable {
        private let lock = NSLock()
        private var fds: [Int32] = []
        func add(_ fd: Int32) { lock.withLock { fds.append(fd) } }
        var count: Int { lock.withLock { fds.count } }
        func closeAll() { lock.withLock { fds.forEach { close($0) }; fds.removeAll() } }
    }

    let port: UInt16
    private let source: DispatchSourceRead
    private let accepted = Accepted()

    var acceptedCount: Int { accepted.count }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && listen(fd, 8) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { close(fd); throw POSIXError(.EADDRNOTAVAIL) }
        port = UInt16(bigEndian: address.sin_port)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let accepted = self.accepted
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "black-hole"))
        source.setEventHandler {
            let client = accept(fd, nil, nil)
            if client >= 0 { accepted.add(client) }
        }
        source.setCancelHandler {
            accepted.closeAll()
            close(fd)
        }
        source.resume()
    }

    func stop() { source.cancel() }
}

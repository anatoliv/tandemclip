import Darwin
import Foundation
import Sentry

/// Remote crash + error reporting to Crashbox through its deliberately small
/// Sentry-compatible ingest surface. **Opt-in and gated**: it starts
/// only when the user has turned it on (Settings, Diagnostics, default OFF)
/// AND a valid HTTPS Crashbox DSN is baked into the build (Info.plist
/// `CrashboxDSN`, injected at package time from a gitignored source, not
/// committed). No opt-in or no usable DSN means reporting-disabled. The SDK is
/// only a protocol client; there is no hosted-provider endpoint or fallback.
/// Privacy: no PII, IP, user ids, automatic breadcrumbs, or request capture,
/// plus a `beforeSend` scrubber.
enum CrashReporting {
    static let infoKey = "CrashboxDSN"
    static let nativeTestEnvironmentKey = "TANDEMCLIP_TEST_CRASHBOX_NATIVE"

    /// UserDefaults key for the opt-in toggle (app domain `com.tandemclip`).
    /// Absent or `false` keeps reporting off.
    static let enabledKey = "crashReportingEnabled"

    /// Bounded failure behavior. Crashbox availability must never determine
    /// whether TandemClip launches, syncs, responds, or exits promptly.
    static let maximumCachedEnvelopes = 10
    /// Has no effect on a send: sentry-cocoa 8.58.4 builds every request with
    /// `timeoutInterval: 15` (`SentryURLRequestFactory`), which replaces the
    /// session's request timeout. Kept only so the session is not left at the
    /// system default if a later SDK stops overriding it.
    static let requestTimeout: TimeInterval = 5
    /// The bound that actually applies to a send against a collector that
    /// accepts and never answers. Tested against a real listener.
    static let resourceTimeout: TimeInterval = 5
    static let shutdownTimeout: TimeInterval = 0.25
    /// The ceiling on waiting for the SDK's main-thread setup to run after
    /// `SentrySDK.start`. Normally it runs within milliseconds; only a main
    /// thread stuck this long reaches it. The wait runs on `queue`.
    static let setupWait: TimeInterval = 10
    /// How long after a toggle Settings reads the outcome again.
    static let initializationWait: TimeInterval = 1

    /// Start, close and the wiring test run here, never on the main thread:
    /// the start waits for the SDK's main-queue setup (`mainQueueCaughtUp`).
    private static let queue = DispatchQueue(label: "com.tandemclip.crash-reporting", qos: .utility)
    private static let attemptGate = ReportingAttemptGate()

    #if DEBUG
    static let environment = "debug"
    #else
    static let environment = "production"
    #endif

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Whether this build can report at all (one valid Crashbox DSN is baked in).
    static var isConfigured: Bool { dsn != nil }

    private static var dsn: String? {
        dsn(from: Bundle.main.infoDictionary)
    }

    /// The only collector a DSN may name. Crashbox issues every project's DSN
    /// on this origin; any other host, a port, or plain HTTP disables reporting.
    static let collectorHost = "ingest.crashbox.dev"

    /// Reject malformed input before handing it to the SDK. The origin must be
    /// exactly `https://ingest.crashbox.dev` (Crashbox decision D1): no other
    /// host, no explicit port, no hosted-provider fallback.
    static func dsn(from info: [String: Any]?) -> String? {
        guard let raw = info?[infoKey] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == collectorHost,
              components.port == nil,
              components.user?.isEmpty == false,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.hasPrefix("/"),
              !components.path.dropFirst().isEmpty,
              !components.path.dropFirst().contains("/"),
              components.url != nil else { return nil }
        return trimmed
    }

    static func transportConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    /// What Settings shows, derived from the same gates the SDK start uses.
    enum Status: Equatable {
        case notConfigured
        case off
        case on
        case unavailable
    }

    /// `.unavailable` means the reporter did not come up in this session (see
    /// `startReporter`). It says nothing about the collector: an unreachable or
    /// rejecting Crashbox still reads `.on`, because finding that out would take
    /// traffic TandemClip does not send. A start still in progress reads `.on`.
    static func status(enabled: Bool, configured: Bool, outcome: ReportingAttemptGate.Outcome) -> Status {
        guard configured else { return .notConfigured }
        guard enabled else { return .off }
        return outcome == .failed ? .unavailable : .on
    }

    /// The Settings footer for each status. Plain words, no dashes.
    static func settingsDetail(_ status: Status) -> String {
        switch status {
        case .notConfigured:
            return "not available in this build (no reporting endpoint is configured)."
        case .off, .on:
            return "off by default; when on, sends crash and error reports to the developer to help fix bugs. Reports never include your clipboard content, your IP, or any identifiers."
        case .unavailable:
            return "on, but the crash reporter could not start this time. TandemClip keeps working normally. Turn this off and on again to retry."
        }
    }

    static var currentStatus: Status {
        status(enabled: isEnabled, configured: isConfigured, outcome: attemptGate.current())
    }

    /// True inside an XCTest run. The SDK never starts there (Crashbox client
    /// rule 10): a test process must not install crash handlers or send.
    static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// Whether this process may start the SDK, as a pure decision.
    static func shouldStart(enabled: Bool, dsn: String?, isTesting: Bool) -> Bool {
        enabled && dsn != nil && !isTesting
    }

    /// Start at launch only if the user opted in, a usable DSN is baked in, and
    /// this is not a test run. No-op otherwise. Never waits for the SDK or the
    /// network: the start runs on `queue`. Returns whether a start was queued.
    @discardableResult
    static func start(enabled: Bool = isEnabled, dsn: String? = dsn, isTesting: Bool = isTesting) -> Bool {
        guard shouldStart(enabled: enabled, dsn: dsn, isTesting: isTesting), let dsn else { return false }
        queue.async { startSDKOnce(dsn: dsn) }
        return true
    }

    /// React to the user flipping the Settings toggle at runtime. Turning it off
    /// closes the SDK and allows one fresh attempt on the next enable.
    static func apply(enabled: Bool) {
        if enabled {
            guard shouldStart(enabled: true, dsn: dsn, isTesting: isTesting), let dsn else { return }
            queue.async { startSDKOnce(dsn: dsn) }
        } else {
            queue.async {
                // A start that timed out can still finish later on the main
                // thread, so close whatever is running, not only a recorded start.
                if attemptGate.current() == .started || SentrySDK.isEnabled { SentrySDK.close() }
                attemptGate.resetAfterExplicitDisable()
                Log.trace("app", "crash reporting disabled by user")
            }
        }
    }

    /// Why the reporter is unavailable in this session.
    enum StartFailure: Error, Equatable {
        /// The SDK's own DSN parser refused the configuration, so the SDK was not started.
        case configurationRejected
        /// The SDK's main-thread setup did not run within `setupWait`.
        case setupTimedOut
        /// The SDK's setup ran but left no client running.
        case didNotEnable
    }

    /// Starts the reporter and reports whether it actually came up.
    /// `SentrySDK.start` cannot throw and finishes asynchronously on the main
    /// thread, so success is judged by the result, not by the call returning.
    /// It fails when
    /// - the SDK parses the DSN itself and refuses it (checked before starting,
    ///   so a refused configuration never starts a client), or
    /// - the SDK's main-thread setup does not run within `setupWait`, or
    /// - it ran and no client is running (`SentrySDK.isEnabled` is false).
    /// It deliberately does not contact the collector. `start`, `waitForSetup`
    /// and `isEnabled` are injected so tests drive this exact decision without
    /// starting an SDK; production passes the real SDK and `mainQueueCaughtUp`.
    static func startReporter(dsn: String,
                              environment: String = CrashReporting.environment,
                              start: (Options) -> Void,
                              waitForSetup: () -> Bool,
                              isEnabled: () -> Bool) throws {
        let options = Options()
        configure(options, dsn: dsn, environment: environment)
        guard options.enabled, options.parsedDsn != nil else { throw StartFailure.configurationRejected }
        start(options)
        guard waitForSetup() else { throw StartFailure.setupTimedOut }
        guard isEnabled() else { throw StartFailure.didNotEnable }
    }

    /// `SentrySDK.start` called off the main thread queues its setup with
    /// `dispatch_async` on the main queue, which is FIFO. A marker queued after
    /// it runs only once that setup has, so reading `isEnabled` then is neither
    /// early nor a guess about timing. On the main thread the SDK sets up inline.
    static func mainQueueCaughtUp(within wait: TimeInterval) -> Bool {
        if Thread.isMainThread { return true }
        let marker = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { marker.signal() }
        return marker.wait(timeout: .now() + wait) == .success
    }

    private static func startSDKOnce(dsn: String) {
        let outcome = attemptGate.runOnce {
            do {
                try startReporter(dsn: dsn,
                                  start: { SentrySDK.start(options: $0) },
                                  waitForSetup: { mainQueueCaughtUp(within: setupWait) },
                                  isEnabled: { SentrySDK.isEnabled })
            } catch {
                Log.error("crash reporting unavailable (\(error)); TandemClip continues")
                throw error
            }
        }
        if outcome == .started { Log.trace("app", "Crashbox reporting started") }
    }

    /// Apply the event-only Crashbox transport profile without starting the SDK.
    /// Kept separate so the native-crash scope and protocol bounds are testable.
    static func configure(_ options: Options, dsn: String, environment: String) {
        options.dsn = dsn
        options.sendDefaultPii = false          // never IP / user ids / bodies
        options.releaseName = release
        options.environment = environment
        options.initialScope = { scope in
            // Native crashes are serialized from the crash scope before a
            // later launch can enrich the event. Options.environment alone
            // does not persist this attribution into that scope.
            scope.setEnvironment(environment)
            return scope
        }
        options.tracesSampleRate = 0.0          // crashes/errors only, no perf volume
        options.sendClientReports = false
        options.enableAutoSessionTracking = false
        options.enableAutoPerformanceTracing = false
        options.enableAppHangTracking = false
        options.enableWatchdogTerminationTracking = false
        options.enableMetricKit = false
        options.enableMetricKitRawPayload = false
        options.enableNetworkTracking = false
        options.enableNetworkBreadcrumbs = false
        options.enableCaptureFailedRequests = false
        options.enableAutoBreadcrumbTracking = false
        options.maxBreadcrumbs = 0
        options.maxCacheItems = UInt(maximumCachedEnvelopes)
        options.shutdownTimeInterval = shutdownTimeout

        // The SDK sends on its own low-priority queue. A private ephemeral
        // session adds finite network deadlines and no shared URL cache or
        // credential storage, so a dead or misbehaving Crashbox is bounded.
        options.urlSession = URLSession(configuration: transportConfiguration())

        // Belt-and-braces scrubbing: drop user/server/request, and redact
        // the home-directory path (which reveals the account name) from an
        // explicitly captured event before anything leaves the Mac.
        options.beforeSend = { event in
            event.user = nil
            event.serverName = nil
            event.request = nil
            if let formatted = event.message?.formatted {
                event.message = SentryMessage(formatted: redactHome(formatted))
            }
            event.breadcrumbs = event.breadcrumbs?.map { crumb in
                if let m = crumb.message { crumb.message = redactHome(m) }
                return crumb
            }
            return event
        }
    }

    /// What the native test-crash request (`TANDEMCLIP_TEST_CRASHBOX_NATIVE=1`)
    /// does. A deliberate crash proves something only if the reporter is
    /// running to catch it, so it needs the start to have come up (`.started`)
    /// and the SDK to say it is enabled; otherwise it refuses and says why.
    enum NativeTestCrash: Equatable {
        case notRequested
        case refused(String)
        case crash
    }

    static func nativeTestCrash(request: String?, reportingActive: Bool,
                                outcome: ReportingAttemptGate.Outcome, sdkEnabled: Bool) -> NativeTestCrash {
        guard request == "1" else { return .notRequested }
        guard reportingActive else { return .refused("crash reporting is off or not configured") }
        guard outcome == .started else { return .refused("the reporter did not start (\(outcome))") }
        guard sdkEnabled else { return .refused("the reporter is not running") }
        return .crash
    }

    /// Decides on `queue`, behind the launch start, so the start's outcome is
    /// known, then crashes a second later on the main thread or logs a refusal.
    /// `crash` and `decided` exist so a test can drive this without crashing.
    static func requestNativeTestCrash(request: String?,
                                       crash: @escaping () -> Void = { tandemclipCrashboxTestCrash() },
                                       decided: ((NativeTestCrash) -> Void)? = nil) {
        guard request != nil else { return }
        queue.async {
            let decision = nativeTestCrash(request: request,
                                           reportingActive: isConfigured && isEnabled,
                                           outcome: attemptGate.current(),
                                           sdkEnabled: SentrySDK.isEnabled)
            switch decision {
            case .notRequested:
                break
            case .refused(let reason):
                Log.error("\(nativeTestEnvironmentKey): \(reason); no test crash")
            case .crash:
                // Let the SDK finish installing its native handler first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { crash() }
            }
            decided?(decision)
        }
    }

    /// Replaces the user's home-directory path with `~` so account names and
    /// local paths don't ride along in a crash report.
    private static func redactHome(_ s: String) -> String {
        let home = NSHomeDirectory()
        return home.isEmpty ? s : s.replacingOccurrences(of: home, with: "~")
    }

    /// Send a test event (verification only; triggered by
    /// TANDEMCLIP_TEST_CRASHBOX in a controlled local proof).
    /// Queued behind the launch start, and sent only if that start came up.
    static func captureTest() {
        guard isConfigured, isEnabled else { return }
        queue.async {
            guard attemptGate.current() == .started, SentrySDK.isEnabled else {
                Log.error("TANDEMCLIP_TEST_CRASHBOX: the reporter did not start; nothing sent")
                return
            }
            SentrySDK.capture(message: "TandemClip Crashbox wiring test")
            SentrySDK.flush(timeout: shutdownTimeout)
        }
    }

    /// `com.tandemclip@<version>+<build>.<commit>` — Sentry-protocol release id,
    /// extended with the source revision baked in at package time so a crash
    /// report identifies the revision it came from and not merely the version
    /// string the release chose for itself. See `BuildIdentity`.
    private static var release: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "0"
        let b = info?["CFBundleVersion"] as? String ?? "0"
        return BuildIdentity.eventRelease(version: v, build: b, commit: BuildIdentity.sourceCommit)
    }
}

/// Deliberate native fault for the release verification playbook.
///
/// The exact environment/reporting gate in `AppController` keeps this
/// unreachable in normal use. A stable C symbol lets the release gate prove
/// that the dSYM maps this exact diagnostic frame back to source. The stored
/// nonzero address prevents the optimizer from replacing the write with a
/// compiler-generated Swift trap, which has a function name but no source
/// line and therefore cannot prove source-level symbolication.
@_cdecl("tandemclipCrashboxTestCrash")
@inline(never)
public func tandemclipCrashboxTestCrash() {
    let faultAddress = 1
    let address = UnsafeMutablePointer<UInt8>(bitPattern: faultAddress)!
    address.pointee = 0
    abort()
}

/// A one-attempt fuse around starting the SDK: a reporter that does not come up
/// (`CrashReporting.startReporter`) leaves reporting unavailable, never in a
/// retry loop. Only an explicit user disable permits another attempt.
final class ReportingAttemptGate: @unchecked Sendable {
    enum Outcome: Equatable { case idle, starting, started, failed }

    private let lock = NSLock()
    private var outcome: Outcome = .idle

    func runOnce(_ initialize: () throws -> Void) -> Outcome {
        lock.lock()
        guard outcome == .idle else {
            let existing = outcome
            lock.unlock()
            return existing
        }
        // Reserve the only attempt before running it, so a concurrent caller
        // sees starting rather than starting a second client.
        outcome = .starting
        lock.unlock()
        do {
            try initialize()
            lock.withLock { outcome = .started }
            return .started
        } catch {
            lock.withLock { outcome = .failed }
            return .failed
        }
    }

    func current() -> Outcome { lock.withLock { outcome } }

    func resetAfterExplicitDisable() { lock.withLock { outcome = .idle } }
}

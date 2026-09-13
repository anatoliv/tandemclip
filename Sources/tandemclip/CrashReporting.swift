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
    static let requestTimeout: TimeInterval = 5
    static let resourceTimeout: TimeInterval = 10
    static let shutdownTimeout: TimeInterval = 0.25

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

    /// Reject malformed input before handing it to the SDK. This intentionally
    /// accepts any HTTPS host: staging and private Crashbox installations are
    /// valid, while the build-time secret selects exactly one endpoint.
    static func dsn(from info: [String: Any]?) -> String? {
        guard let raw = info?[infoKey] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              host != "sentry.io",
              !host.hasSuffix(".sentry.io"),
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

    /// Start at launch only if the user opted in. No-op otherwise.
    static func start() {
        guard isEnabled else { return }
        startSDK()
    }

    /// React to the user flipping the Settings toggle at runtime.
    static func apply(enabled: Bool) {
        if enabled {
            startSDK()
        } else {
            SentrySDK.close()
            Log.trace("app", "crash reporting disabled by user")
        }
    }

    private static func startSDK() {
        guard let dsn else { return }   // no usable Crashbox DSN → off
        SentrySDK.start { options in
            configure(options, dsn: dsn, environment: environment)
        }
        Log.trace("app", "Crashbox reporting started")
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

    static func shouldCaptureNativeTest(request: String?, reportingActive: Bool) -> Bool {
        request == "1" && reportingActive
    }

    /// Deliberate native crash for the release verification playbook. The exact
    /// environment gate in AppController keeps this unreachable in normal use.
    @inline(never)
    static func captureNativeTest() -> Never {
        fatalError("TandemClip Crashbox native verification")
    }

    /// Replaces the user's home-directory path with `~` so account names and
    /// local paths don't ride along in a crash report.
    private static func redactHome(_ s: String) -> String {
        let home = NSHomeDirectory()
        return home.isEmpty ? s : s.replacingOccurrences(of: home, with: "~")
    }

    /// Send a test event (verification only; triggered by
    /// TANDEMCLIP_TEST_CRASHBOX in a controlled local proof).
    static func captureTest() {
        guard isConfigured, isEnabled else { return }
        SentrySDK.capture(message: "TandemClip Crashbox wiring test")
        SentrySDK.flush(timeout: shutdownTimeout)
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

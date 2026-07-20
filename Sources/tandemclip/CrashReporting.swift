import Foundation
import Sentry

/// Remote crash + error reporting via Sentry. **Opt-in and gated**: it starts
/// only when the user has turned it on (Settings, Diagnostics, default OFF)
/// AND a DSN is baked into the build (Info.plist `SentryDSN`, injected at
/// package time from a gitignored source, not committed). No opt-in or no DSN
/// means it stays off, so dev/self-built copies and un-consented users never
/// phone home. Privacy: no PII, IP, or user ids, plus a `beforeSend` scrubber.
enum CrashReporting {
    /// UserDefaults key for the opt-in toggle (app domain `com.tandemclip`).
    /// Absent or `false` keeps reporting off.
    static let enabledKey = "crashReportingEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Whether this build can report at all (a DSN is baked in).
    static var isConfigured: Bool { dsn != nil }

    private static var dsn: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        guard let dsn else { return }   // no DSN → off
        SentrySDK.start { options in
            options.dsn = dsn
            options.sendDefaultPii = false          // never IP / user ids / bodies
            options.releaseName = release
            #if DEBUG
            options.environment = "debug"
            #else
            options.environment = "release"
            #endif
            options.tracesSampleRate = 0.0          // crashes/errors only, no perf volume
            // Belt-and-braces scrubbing: drop user/server/request, and redact
            // the home-directory path (which reveals the account name) from
            // event and breadcrumb messages before anything leaves the Mac.
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
        Log.trace("app", "crash reporting started")
    }

    /// Replaces the user's home-directory path with `~` so account names and
    /// local paths don't ride along in a crash report.
    private static func redactHome(_ s: String) -> String {
        let home = NSHomeDirectory()
        return home.isEmpty ? s : s.replacingOccurrences(of: home, with: "~")
    }

    /// Send a test event (verification only; triggered by TANDEMCLIP_TEST_SENTRY).
    static func captureTest() {
        SentrySDK.capture(message: "TandemClip Sentry wiring test")
        SentrySDK.flush(timeout: 5)
    }

    /// `com.tandemclip@<version>+<build>` — conventional Sentry release id.
    private static var release: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "0"
        let b = info?["CFBundleVersion"] as? String ?? "0"
        return "com.tandemclip@\(v)+\(b)"
    }
}

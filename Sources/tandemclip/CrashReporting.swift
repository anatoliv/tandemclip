import Foundation
import Sentry

/// Remote crash + error reporting via Sentry. **Gated**: only starts when a DSN
/// is baked into the build (Info.plist `SentryDSN`). No DSN → stays off, so
/// dev/self-built copies never phone home. Privacy: no PII, IP, or user ids.
enum CrashReporting {
    private static var dsn: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func start() {
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
        }
        Log.trace("app", "crash reporting started")
    }

    /// `com.tandemclip@<version>+<build>` — conventional Sentry release id.
    private static var release: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "0"
        let b = info?["CFBundleVersion"] as? String ?? "0"
        return "com.tandemclip@\(v)+\(b)"
    }
}

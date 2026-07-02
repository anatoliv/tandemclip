import Foundation

/// Lightweight logging. Verbose output (discovery / handshake / sync tracing) is
/// off by default and enabled with `--verbose`/`-v` or `TANDEM_VERBOSE=1`.
/// Errors always print.
enum Log {
    /// Enabled by `--verbose`/`-v`, `TANDEM_VERBOSE=1`, or the in-app setting
    /// (AppController syncs the setting into this at launch and on change).
    static var verbose: Bool = {
        if CommandLine.arguments.contains("--verbose") || CommandLine.arguments.contains("-v") {
            return true
        }
        if let env = ProcessInfo.processInfo.environment["TANDEM_VERBOSE"],
           env == "1" || env.lowercased() == "true" {
            return true
        }
        return false
    }()

    /// Traced only in verbose mode. `category` groups related events, e.g.
    /// "discovery", "tls", "sync".
    static func trace(_ category: String, _ message: @autoclosure () -> String) {
        guard verbose else { return }
        NSLog("[tandem:%@] %@", category, message())
    }

    /// Always printed.
    static func error(_ message: String) {
        NSLog("[tandem:error] %@", message)
    }
}

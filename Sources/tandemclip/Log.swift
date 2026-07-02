import Foundation

/// Lightweight logging. Verbose output (discovery / handshake / sync tracing) is
/// off by default and enabled with `--verbose`/`-v` or `TANDEMCLIP_VERBOSE=1`.
/// Errors always print.
enum Log {
    /// Enabled by `--verbose`/`-v`, `TANDEMCLIP_VERBOSE=1`, or the in-app setting
    /// (AppController syncs the setting into this at launch and on change).
    static var verbose: Bool = {
        if CommandLine.arguments.contains("--verbose") || CommandLine.arguments.contains("-v") {
            return true
        }
        if let env = ProcessInfo.processInfo.environment["TANDEMCLIP_VERBOSE"],
           env == "1" || env.lowercased() == "true" {
            return true
        }
        return false
    }()

    /// Traced only in verbose mode. `category` groups related events, e.g.
    /// "discovery", "tls", "sync".
    static func trace(_ category: String, _ message: @autoclosure () -> String) {
        guard verbose else { return }
        NSLog("[tandemclip:%@] %@", category, message())
    }

    /// Always printed.
    static func error(_ message: String) {
        NSLog("[tandemclip:error] %@", message)
    }
}

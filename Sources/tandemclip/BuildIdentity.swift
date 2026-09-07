import Foundation

/// The exact source revision this binary was built from, baked into the bundle
/// at package time (Info.plist `TandemClipSourceCommit`, injected by
/// make-app.sh from `git rev-parse HEAD`) the same way the Crashbox DSN is.
///
/// Why it exists: a version and build number describe *what a release called
/// itself*, not *what it was built from*. A tag pointing at a commit is a claim
/// made alongside the artifact, not a property of it — anyone holding a shipped
/// .app has no way to check it, and nothing in the DMG that shipped as 0.25.0
/// records a revision at all. So a crash report, a user's copy, or a DMG pulled
/// off the download URL could not be mapped back to source except by trusting
/// the release notes. This closes that: the commit travels *inside* the bundle,
/// so any live artifact answers the question by itself.
///
/// The tracked Packaging/Info.plist carries an empty value; a dev build simply
/// has no identity and says so. make-app.sh refuses to produce a *distributable*
/// (Developer ID signed) build without a well-formed one.
enum BuildIdentity {
    /// Info.plist key holding the 40-character lowercase-hex source commit.
    static let infoKey = "TandemClipSourceCommit"

    /// The source commit this build came from, or nil for a build that carries
    /// none (dev builds) or carries a malformed one. Never returns a value that
    /// would not pass `isWellFormed` — a half-trusted identity is worse than
    /// none, because it invites being quoted as proof.
    static var sourceCommit: String? {
        commit(from: Bundle.main.infoDictionary)
    }

    /// Testable core of `sourceCommit`: pulls the key out of an info dictionary
    /// and applies the same validation.
    static func commit(from info: [String: Any]?) -> String? {
        guard let raw = info?[infoKey] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return isWellFormed(trimmed) ? trimmed : nil
    }

    /// A source commit is well formed only as a full 40-character lowercase hex
    /// SHA-1. Deliberately strict on all three counts:
    ///
    /// * **Full length.** An abbreviated SHA is ambiguous by construction — it
    ///   identifies a prefix, and prefixes collide as history grows. Identity
    ///   that can become wrong later is not identity.
    /// * **Lowercase.** `git rev-parse` emits lowercase, so an uppercase value
    ///   came from somewhere else (a human, a copy-paste, a different tool) and
    ///   is a signal the pipeline is not what it claims. Accepting both spellings
    ///   also means the same commit produces two different release names.
    /// * **Hex only.** Rules out placeholders, template leftovers, and the
    ///   `unknown` / `dev` / `HEAD` strings a build script emits when the real
    ///   lookup failed.
    ///
    /// ASCII explicitly: `Character.isNumber` is true for Arabic-Indic and other
    /// non-ASCII digits, so the obvious spelling of this check would accept a
    /// string `git` could never produce.
    static func isWellFormed(_ value: String) -> Bool {
        guard value.utf8.count == 40, value.count == 40 else { return false }
        return value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    /// Sentry-protocol event release id:
    /// `com.tandemclip@<version>+<build>.<commit>`.
    ///
    /// The commit rides in the semver build-metadata segment, after the build
    /// number, so the `name@version+build` wire shape Crashbox accepts is
    /// unchanged and releases stay comparable — it only gains the field that
    /// ties an event to a revision. A build with no identity
    /// falls back to the old `com.tandemclip@<version>+<build>` rather than
    /// inventing one, so an unidentified dev build is visibly unidentified.
    static func eventRelease(version: String, build: String, commit: String?) -> String {
        let base = "com.tandemclip@\(version)+\(build)"
        guard let commit, isWellFormed(commit) else { return base }
        return "\(base).\(commit)"
    }
}

import AppKit
import Foundation
import SwiftUI

/// Single source of truth for ChatGPT-OAuth sign-in state (ported from
/// tonebox). The Settings UI observes this; `AIClient`'s OAuth code path calls
/// `currentAccessToken()` before every request so a stale access token gets
/// refreshed transparently.
///
/// **Why a class.** Refresh has to be deduplicated — parallel calls at
/// minute-59 should share one refresh round trip, not race. The `@Published`
/// state also has to survive a sheet's lifecycle for SwiftUI.
///
/// **Token storage.** The full token blob lives in the login Keychain via
/// `KeychainStore` under a dedicated account name; only this manager reads it.
@MainActor
final class CodexAuthManager: ObservableObject {
    /// App-singleton. `AIClient` and the Settings view both reach for this; a
    /// second instance would mean two refresh-dedup caches and stale reads.
    static let shared = CodexAuthManager()

    /// Keychain account (service is `KeychainStore`'s app-wide `com.tandemclip`).
    private static let keychainAccount = "codexOAuthTokens"

    @Published private(set) var signedInEmail: String?
    @Published private(set) var signedInPlan: String?
    @Published private(set) var accountID: String?
    @Published private(set) var isSigningIn = false
    @Published private(set) var lastError: String?

    /// True iff a token blob is loaded. UI guards "Sign out" on this.
    var isSignedIn: Bool { tokens != nil }

    private var tokens: CodexOAuth.Tokens?
    private var refreshInFlight: Task<CodexOAuth.Tokens, any Error>?
    private var callbackServer: CodexCallbackServer?

    private init() {
        loadFromKeychain()
        // Start each launch on the real OAuth path; a prior session's outage
        // may have been transient, and the first failed call re-latches.
        CodexDegradation.isDegraded = false
    }

    // MARK: - Public flows

    /// Runs the full PKCE login: build URL → start localhost listener → open
    /// Safari → await callback → exchange code → persist. Throws if any step
    /// fails; UI shows the message.
    func signIn() async throws {
        guard !isSigningIn else { return }
        isSigningIn = true
        lastError = nil
        defer {
            isSigningIn = false
            callbackServer = nil
        }

        let pkce = CodexOAuth.PKCE.generate()
        let state = CodexOAuth.generateState()
        let server = CodexCallbackServer()
        callbackServer = server

        let listenTask = Task { try await server.awaitCallback() }

        NSWorkspace.shared.open(CodexOAuth.authorizeURL(pkce: pkce, state: state))

        let result: CodexCallbackServer.CallbackResult
        do {
            result = try await listenTask.value
        } catch {
            lastError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }

        guard result.state == state else {
            lastError = "Sign-in returned a mismatched state token — please try again."
            throw CodexOAuth.OAuthError.stateMismatch
        }

        let fresh: CodexOAuth.Tokens
        do {
            fresh = try await CodexOAuth.exchangeCode(result.code, verifier: pkce.verifier)
        } catch {
            lastError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }
        try persist(fresh)
    }

    /// Cancels an in-progress sign-in. Safe when nothing is in flight.
    func cancelSignIn() {
        callbackServer?.cancel()
    }

    /// Deletes the persisted token and clears in-memory state. Idempotent.
    func signOut() {
        KeychainStore.delete(Self.keychainAccount)
        tokens = nil
        signedInEmail = nil
        signedInPlan = nil
        accountID = nil
        refreshInFlight?.cancel()
        refreshInFlight = nil
        // Abandoning OAuth — drop the latch so it doesn't accuse a path the
        // user just left.
        CodexDegradation.isDegraded = false
    }

    /// Returns a usable access token (refreshing on the fly near expiry) plus
    /// the account id required by the backend-api routing. Returns nil when
    /// signed out — callers fall back to the API-key path then.
    func currentAccessToken() async throws -> (token: String, accountID: String?)? {
        guard let current = tokens else { return nil }
        if !current.needsRefresh {
            return (current.accessToken, accountID)
        }
        let fresh = try await refreshOnce(refreshToken: current.refreshToken)
        return (fresh.accessToken, accountID)
    }

    // MARK: - Refresh dedup

    /// Coalesces parallel refresh attempts. The first caller wins the network
    /// round trip; everyone else awaits the same task.
    private func refreshOnce(refreshToken: String) async throws -> CodexOAuth.Tokens {
        if let existing = refreshInFlight {
            return try await existing.value
        }
        let task = Task { () throws -> CodexOAuth.Tokens in
            let response = try await CodexOAuth.refresh(refreshToken: refreshToken)
            // Hydra may omit `refresh_token`/`id_token` on a refresh when the
            // existing ones are still valid; preserve what we had.
            let mergedRefresh = response.refreshToken.isEmpty ? refreshToken : response.refreshToken
            let mergedID = response.idToken.isEmpty ? (self.tokens?.idToken ?? "") : response.idToken
            let merged = CodexOAuth.Tokens(
                accessToken: response.accessToken,
                refreshToken: mergedRefresh,
                idToken: mergedID,
                accessTokenExpiresAt: response.accessTokenExpiresAt
            )
            try self.persist(merged)
            return merged
        }
        refreshInFlight = task
        defer { refreshInFlight = nil }
        return try await task.value
    }

    // MARK: - Persistence

    private func loadFromKeychain() {
        guard let data = KeychainStore.getData(Self.keychainAccount) else { return }
        do {
            let stored = try JSONDecoder().decode(CodexOAuth.Tokens.self, from: data)
            tokens = stored
            applyClaims(from: stored)
        } catch {
            Log.error("codex keychain load failed: \(error.localizedDescription)")
            tokens = nil
        }
    }

    private func persist(_ fresh: CodexOAuth.Tokens) throws {
        let data = try JSONEncoder().encode(fresh)
        KeychainStore.setData(Self.keychainAccount, data)
        tokens = fresh
        applyClaims(from: fresh)
        // A fresh token landed (sign-in OR successful refresh) — the OAuth
        // path works again, so retire any degraded latch.
        CodexDegradation.isDegraded = false
    }

    /// Decode the id_token JWT into display fields. Tolerates failure — a
    /// corrupt id_token still leaves the bearer usable; we just don't show
    /// the email/plan chip.
    private func applyClaims(from tokens: CodexOAuth.Tokens) {
        if let claims = try? CodexOAuth.parseIDToken(tokens.idToken) {
            signedInEmail = claims.email
            signedInPlan = claims.plan
            accountID = claims.accountID
        } else {
            signedInEmail = nil
            signedInPlan = nil
            accountID = nil
        }
    }
}

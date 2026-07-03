import CryptoKit
import Foundation

/// Pure functions implementing the OAuth-PKCE flow against
/// `auth.openai.com` exactly the way the first-party Codex CLI does — ported
/// verbatim from tonebox so tandemclip's "Sign in with ChatGPT" path speaks
/// the same protocol. No I/O state lives here; callers run the flow via
/// `CodexAuthManager`, this module just produces URLs, hashes, and payloads.
///
/// **Reference parity.** Every constant mirrors a literal in
/// `openai/codex/codex-rs/login` (client id, issuer, redirect URI, scopes,
/// S256, the two non-standard flow knobs). The redirect URI in particular is
/// allow-listed server-side, so drift is silently rejected by Hydra.
///
/// **The endpoint is undocumented.** OpenAI permits third-party use but does
/// not promise stability; if Codex CLI changes a constant, follow it here.
enum CodexOAuth {
    /// First-party Codex CLI client. OpenAI's Hydra accepts this id from any
    /// client because the PKCE verifier proves possession; the redirect URI
    /// is the second-factor allow-list check.
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    static let issuer = URL(string: "https://auth.openai.com")!
    static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!

    /// Hydra allow-listed port. Hard-coded to 1455 — a different port makes
    /// the authorize call reject with `invalid_redirect_uri`.
    static let callbackPort: UInt16 = 1455
    static let redirectURI = "http://localhost:1455/auth/callback"

    /// Identical to Codex CLI's request — `offline_access` yields a refresh
    /// token; `api.connectors.*` are required for the backend-api/codex
    /// route to accept the bearer.
    static let scopes =
        "openid profile email offline_access api.connectors.read api.connectors.invoke"

    /// Branded originator that backend-api logs against the request, so
    /// tandemclip traffic is attributable to tandemclip.
    static let originator = "tandemclip_macos"

    /// Hardcoded backend endpoint the ChatGPT OAuth path POSTs to. Mirrors
    /// `chatgpt.com/backend-api/codex` from Codex CLI; the trailing
    /// `/responses` is the Responses API surface. Not user-configurable —
    /// it's part of the auth contract.
    static let codexResponsesURL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!

    // MARK: - PKCE

    struct PKCE: Sendable, Equatable {
        let verifier: String
        let challenge: String

        /// 64 random bytes → URL-safe base64 (no padding). Challenge is
        /// SHA-256 of the verifier under the same encoding.
        static func generate() -> PKCE {
            var bytes = [UInt8](repeating: 0, count: 64)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
            let verifier = Data(bytes).base64URLEncodedString()
            let digest = SHA256.hash(data: Data(verifier.utf8))
            let challenge = Data(digest).base64URLEncodedString()
            return PKCE(verifier: verifier, challenge: challenge)
        }
    }

    /// CSRF guard. The authorize URL embeds this; the callback must echo it
    /// back unchanged or the response is forged.
    static func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).base64URLEncodedString()
    }

    // MARK: - Authorize URL

    /// Builds the URL the user opens in Safari to consent. Mirrors
    /// `build_authorize_url` in codex-rs/login/src/server.rs.
    static func authorizeURL(pkce: PKCE, state: String) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: originator),
        ]
        return components.url!
    }

    // MARK: - Token model

    /// What we persist to Keychain after a successful exchange/refresh.
    /// `accessTokenExpiresAt` is computed from `expires_in` at issuance; a
    /// small refresh slack (60 s) lives in `needsRefresh`, not here.
    struct Tokens: Codable, Sendable, Equatable {
        let accessToken: String
        let refreshToken: String
        let idToken: String
        let accessTokenExpiresAt: Date

        /// True when the access token is within 60 s of expiry (or already
        /// expired). Narrow slack keeps back-to-back calls to a single
        /// refresh hit.
        var needsRefresh: Bool {
            accessTokenExpiresAt.timeIntervalSinceNow < 60
        }
    }

    // MARK: - Token exchange + refresh

    enum OAuthError: Error, LocalizedError {
        case httpStatus(Int, String)
        case malformedResponse
        case stateMismatch

        var errorDescription: String? {
            switch self {
            case let .httpStatus(code, body):
                return "OAuth server returned \(code): \(body.prefix(200))"
            case .malformedResponse:
                return "OAuth server response was missing expected fields."
            case .stateMismatch:
                return "OAuth callback `state` didn't match — possible forged callback."
            }
        }
    }

    /// Trades an authorization code (received via the localhost callback) for
    /// an access/refresh/id token triple.
    static func exchangeCode(
        _ code: String,
        verifier: String,
        urlSession: URLSession = .shared
    ) async throws -> Tokens {
        let body = formEncode([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
        return try await postTokenRequest(body: body, urlSession: urlSession)
    }

    /// Refreshes an expired access token. `offline_access` was in the
    /// original scope grant, otherwise this returns 400.
    static func refresh(
        refreshToken: String,
        urlSession: URLSession = .shared
    ) async throws -> Tokens {
        let body = formEncode([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "scope": scopes,
        ])
        return try await postTokenRequest(body: body, urlSession: urlSession)
    }

    private static func postTokenRequest(
        body: String,
        urlSession: URLSession
    ) async throws -> Tokens {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.malformedResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.httpStatus(http.statusCode, bodyString)
        }

        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        let now = Date()
        return Tokens(
            accessToken: payload.access_token,
            // Hydra omits `refresh_token` on a refresh call when the existing
            // one is still good — reuse what we already had.
            refreshToken: payload.refresh_token ?? "",
            idToken: payload.id_token ?? "",
            accessTokenExpiresAt: now.addingTimeInterval(TimeInterval(payload.expires_in))
        )
    }

    // MARK: - id_token claim parsing

    struct IDTokenClaims: Sendable, Equatable {
        let email: String?
        /// Raw ChatGPT plan value: "free", "plus", "pro", … Pretty-printed in UI.
        let plan: String?
        /// Workspace id. Sent as `ChatGPT-Account-Id` on every backend-api call.
        let accountID: String?
        let userID: String?
        let issuedExpiry: Date?
    }

    /// Decodes the JWT payload (segment 2 of `header.payload.sig`) without
    /// signature verification — we trust the token because we just received
    /// it over TLS from auth.openai.com, and we use the claims for display +
    /// routing, not authorization.
    static func parseIDToken(_ jwt: String) throws -> IDTokenClaims {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { throw OAuthError.malformedResponse }
        guard let payloadData = Data(base64URLEncoded: String(parts[1])) else {
            throw OAuthError.malformedResponse
        }
        let json = try JSONDecoder().decode(IDClaims.self, from: payloadData)
        let auth = json.openaiAuth
        let profile = json.openaiProfile
        let email = json.email ?? profile?.email
        let expiry = json.exp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return IDTokenClaims(
            email: email,
            plan: auth?.chatgpt_plan_type,
            accountID: auth?.chatgpt_account_id,
            userID: auth?.chatgpt_user_id ?? auth?.user_id,
            issuedExpiry: expiry
        )
    }

    // MARK: - Wire types

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
        let expires_in: Int
    }

    private struct IDClaims: Decodable {
        let email: String?
        let exp: Int?
        let openaiAuth: AuthClaim?
        let openaiProfile: ProfileClaim?

        enum CodingKeys: String, CodingKey {
            case email
            case exp
            case openaiAuth = "https://api.openai.com/auth"
            case openaiProfile = "https://api.openai.com/profile"
        }
    }

    private struct AuthClaim: Decodable {
        let chatgpt_plan_type: String?
        let chatgpt_user_id: String?
        let user_id: String?
        let chatgpt_account_id: String?
    }

    private struct ProfileClaim: Decodable {
        let email: String?
    }

    // MARK: - Form encoding

    /// `application/x-www-form-urlencoded` with the RFC 3986 safe set —
    /// `URLComponents` leaves `+` alone and Hydra reads `+` as a space.
    private static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }
}

// MARK: - URL-safe base64 helpers

extension Data {
    /// RFC 4648 §5 — `+` → `-`, `/` → `_`, no padding. Required for PKCE
    /// verifiers and JWT segments.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Inverse of `base64URLEncodedString` — re-adds padding for Foundation's
    /// strict base64 decoder.
    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - s.count % 4) % 4
        s.append(String(repeating: "=", count: pad))
        guard let data = Data(base64Encoded: s) else { return nil }
        self = data
    }
}

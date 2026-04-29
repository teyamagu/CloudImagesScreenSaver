import CryptoKit
import Foundation
import Security

public enum DropboxOAuthError: LocalizedError, Sendable {
    case notConfigured
    case missingClientId
    case missingAuthorizationCode
    case missingPKCEVerifier
    case missingRefreshToken
    case httpFailure(status: Int, body: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Dropbox is not configured (missing app key or refresh token)."
        case .missingClientId:
            "Dropbox App Key (client_id) is missing."
        case .missingAuthorizationCode:
            "Authorization code is missing."
        case .missingPKCEVerifier:
            "PKCE verifier is missing; open Dropbox sign-in first."
        case .missingRefreshToken:
            "Refresh token is missing."
        case let .httpFailure(status, body):
            "Dropbox token HTTP \(status): \(body)"
        case .invalidResponse:
            "Invalid token response from Dropbox."
        }
    }
}

/// Short-lived access token and optional refresh token / expiry from Dropbox `/oauth2/token`.
public struct DropboxOAuthTokens: Sendable {
    public let accessToken: String
    /// Present on first authorization or when Dropbox rotates the refresh token; `nil` means keep the previous refresh token.
    public let refreshToken: String?
    public let expiresAt: Date?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

// MARK: - PKCE + OAuth HTTP

public enum DropboxOAuth {
    public static let tokenEndpoint = URL(string: "https://api.dropboxapi.com/oauth2/token")!

    /// RFC 7636: length 43–128, unreserved characters.
    public static func generateCodeVerifier() -> String {
        let charset = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var random = [UInt8](repeating: 0, count: 64)
        let ok = SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess
        if !ok {
            random = (0 ..< 64).map { _ in UInt8.random(in: 0 ... 255) }
        }
        return String(random.map { charset[Int($0) % charset.count] })
    }

    public static func codeChallengeS256(verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// `redirectURI` omitted or empty: Dropbox shows the authorization code for copy-paste (no local redirect server).
    public static func authorizeURL(clientId: String, codeChallenge: String, redirectURI: String?) -> URL {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "token_access_type", value: "offline"),
            URLQueryItem(name: "scope", value: "files.metadata.read files.content.read"),
        ]
        if let redirectURI, !redirectURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(URLQueryItem(name: "redirect_uri", value: redirectURI))
        }
        var comp = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")!
        comp.queryItems = items
        guard let url = comp.url else {
            preconditionFailure("invalid authorize URL components")
        }
        return url
    }

    public static func exchangeAuthorizationCode(
        clientId: String,
        code: String,
        codeVerifier: String,
        redirectURI: String?
    ) async throws -> DropboxOAuthTokens {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVerifier = codeVerifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else { throw DropboxOAuthError.missingAuthorizationCode }
        guard !trimmedVerifier.isEmpty else { throw DropboxOAuthError.missingPKCEVerifier }

        var pairs: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", trimmedCode),
            ("client_id", clientId),
            ("code_verifier", trimmedVerifier),
        ]
        if let redirectURI, !redirectURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pairs.append(("redirect_uri", redirectURI))
        }
        return try await postTokenRequest(formPairs: pairs)
    }

    public static func refreshAccessToken(clientId: String, refreshToken: String) async throws -> DropboxOAuthTokens {
        let rt = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rt.isEmpty else { throw DropboxOAuthError.missingRefreshToken }
        let cid = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cid.isEmpty else { throw DropboxOAuthError.missingClientId }
        return try await postTokenRequest(formPairs: [
            ("grant_type", "refresh_token"),
            ("refresh_token", rt),
            ("client_id", cid),
        ])
    }

    // MARK: - Private

    private struct TokenJSON: Decodable {
        let access_token: String
        let token_type: String?
        let expires_in: Int?
        let refresh_token: String?
    }

    private static func postTokenRequest(formPairs: [(String, String)]) async throws -> DropboxOAuthTokens {
        var comp = URLComponents()
        comp.queryItems = formPairs.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let body = comp.percentEncodedQuery?.data(using: .utf8) else {
            throw DropboxOAuthError.invalidResponse
        }

        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DropboxOAuthError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw DropboxOAuthError.httpFailure(status: http.statusCode, body: text)
        }

        let decoded: TokenJSON
        do {
            decoded = try JSONDecoder().decode(TokenJSON.self, from: data)
        } catch {
            throw DropboxOAuthError.invalidResponse
        }

        let expiresAt: Date? = if let sec = decoded.expires_in, sec > 0 {
            Date().addingTimeInterval(TimeInterval(sec))
        } else {
            nil
        }

        return DropboxOAuthTokens(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token,
            expiresAt: expiresAt
        )
    }
}

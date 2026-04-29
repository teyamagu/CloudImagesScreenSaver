import AppKit

struct OAuthSignInStart {
    let verifier: String
    let authorizeURL: URL
}

protocol DropboxOAuthService {
    func generateCodeVerifier() -> String
    func codeChallengeS256(verifier: String) -> String
    func authorizeURL(clientId: String, codeChallenge: String, redirectURI: String?) throws -> URL
    func exchangeAuthorizationCode(
        clientId: String,
        code: String,
        codeVerifier: String,
        redirectURI: String?
    ) async throws -> AppDropboxOAuthTokens
}

struct LiveDropboxOAuthService: DropboxOAuthService {
    func generateCodeVerifier() -> String {
        AppDropboxOAuth.generateCodeVerifier()
    }

    func codeChallengeS256(verifier: String) -> String {
        AppDropboxOAuth.codeChallengeS256(verifier: verifier)
    }

    func authorizeURL(clientId: String, codeChallenge: String, redirectURI: String?) throws -> URL {
        try AppDropboxOAuth.authorizeURL(clientId: clientId, codeChallenge: codeChallenge, redirectURI: redirectURI)
    }

    func exchangeAuthorizationCode(
        clientId: String,
        code: String,
        codeVerifier: String,
        redirectURI: String?
    ) async throws -> AppDropboxOAuthTokens {
        try await AppDropboxOAuth.exchangeAuthorizationCode(
            clientId: clientId,
            code: code,
            codeVerifier: codeVerifier,
            redirectURI: redirectURI
        )
    }
}

struct OAuthCoordinator {
    let service: DropboxOAuthService

    func startSignIn(appKey: String) throws -> OAuthSignInStart {
        let trimmed = appKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppDropboxOAuthError.missingClientId
        }
        let verifier = service.generateCodeVerifier()
        let challenge = service.codeChallengeS256(verifier: verifier)
        let url = try service.authorizeURL(clientId: trimmed, codeChallenge: challenge, redirectURI: nil)
        return OAuthSignInStart(verifier: verifier, authorizeURL: url)
    }

    func completeSignIn(appKey: String, code: String, verifier: String) async throws -> AppDropboxOAuthTokens {
        try await service.exchangeAuthorizationCode(
            clientId: appKey.trimmingCharacters(in: .whitespacesAndNewlines),
            code: code.trimmingCharacters(in: .whitespacesAndNewlines),
            codeVerifier: verifier.trimmingCharacters(in: .whitespacesAndNewlines),
            redirectURI: nil
        )
    }
}

struct ConfigureSheetAuthActionHandler {
    let oauthCoordinator: OAuthCoordinator

    func startSignIn(appKey: String) throws -> OAuthSignInStart {
        try oauthCoordinator.startSignIn(appKey: appKey)
    }

    func completeSignIn(appKey: String, code: String, verifier: String) async throws -> AppDropboxOAuthTokens {
        try await oauthCoordinator.completeSignIn(appKey: appKey, code: code, verifier: verifier)
    }
}

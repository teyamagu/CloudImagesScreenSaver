#if SWIFT_PACKAGE
    import DropboxAPI
#endif
import Foundation
import ScreenSaver

/// Reads and updates OAuth tokens in `ScreenSaverDefaults` for the screen saver bundle (Xcode target only; excluded from SwiftPM).
enum DropboxScreenSaverOAuth {
    private static let accessSkew: TimeInterval = 120

    /// Resolves a usable short-lived access token: uses the cached value if still valid, otherwise refreshes with the refresh token.
    static func resolveAccessToken(defaults d: ScreenSaverDefaults) async throws -> String {
        let appKey = (d.string(forKey: ScreenSaverSettings.Key.dropboxAppKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let refresh = (d.string(forKey: ScreenSaverSettings.Key.dropboxRefreshToken) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !refresh.isEmpty {
            guard !appKey.isEmpty else { throw DropboxOAuthError.missingClientId }

            let cached = (d.string(forKey: ScreenSaverSettings.Key.dropboxAccessTokenCache) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let expiresTs = d.double(forKey: ScreenSaverSettings.Key.dropboxAccessTokenExpiresAt)
            let expiresAt = expiresTs > 0 ? Date(timeIntervalSince1970: expiresTs) : Date.distantPast

            if !cached.isEmpty, expiresAt > Date().addingTimeInterval(accessSkew) {
                return cached
            }

            let tokens = try await DropboxOAuth.refreshAccessToken(clientId: appKey, refreshToken: refresh)
            saveSession(tokens: tokens, clientId: appKey, defaults: d)
            return tokens.accessToken
        }

        throw DropboxOAuthError.notConfigured
    }

    /// Persists tokens after authorization-code exchange or refresh (refresh token omitted in JSON keeps the previous value).
    static func saveSession(tokens: DropboxOAuthTokens, clientId: String, defaults d: ScreenSaverDefaults) {
        let cid = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cid.isEmpty {
            d.set(cid, forKey: ScreenSaverSettings.Key.dropboxAppKey)
        }
        d.set(tokens.accessToken, forKey: ScreenSaverSettings.Key.dropboxAccessTokenCache)
        if let newRefresh = tokens.refreshToken, !newRefresh.isEmpty {
            d.set(newRefresh, forKey: ScreenSaverSettings.Key.dropboxRefreshToken)
        }
        if let exp = tokens.expiresAt {
            d.set(exp.timeIntervalSince1970, forKey: ScreenSaverSettings.Key.dropboxAccessTokenExpiresAt)
        }
        d.synchronize()
    }

    static func hasConfiguredAuth(defaults d: ScreenSaverDefaults) -> Bool {
        let appKey = (d.string(forKey: ScreenSaverSettings.Key.dropboxAppKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let refresh = (d.string(forKey: ScreenSaverSettings.Key.dropboxRefreshToken) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !appKey.isEmpty && !refresh.isEmpty
    }
}

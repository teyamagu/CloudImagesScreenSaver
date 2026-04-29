@testable import CloudImagesScreenSaverModule
import DropboxAPI
import Foundation
import XCTest

final class MaintainabilityRefactorTests: XCTestCase {
    private struct InMemorySettingsStore: ScreenSaverSettingsStore {
        var values: [String: Any] = [:]

        func string(forKey key: String) -> String? {
            values[key] as? String
        }

        func integer(forKey key: String) -> Int {
            values[key] as? Int ?? 0
        }

        func double(forKey key: String) -> Double {
            values[key] as? Double ?? 0
        }

        mutating func set(_ value: Any?, forKey key: String) {
            values[key] = value
        }

        func synchronize() {}
    }

    private struct StubOAuthService: DropboxOAuthService {
        var authorizeURLResult: Result<URL, Error> = .success(URL(string: "https://example.com")!)
        var exchangeResult: Result<DropboxOAuthTokens, Error> = .success(
            DropboxOAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: nil)
        )

        func generateCodeVerifier() -> String {
            "verifier"
        }

        func codeChallengeS256(verifier _: String) -> String {
            "challenge"
        }

        func authorizeURL(clientId _: String, codeChallenge _: String, redirectURI _: String?) throws -> URL {
            try authorizeURLResult.get()
        }

        func exchangeAuthorizationCode(
            clientId _: String,
            code _: String,
            codeVerifier _: String,
            redirectURI _: String?
        ) async throws -> DropboxOAuthTokens {
            try exchangeResult.get()
        }
    }

    func testOAuthCoordinatorStartSignInRequiresAppKey() throws {
        let coordinator = OAuthCoordinator(service: StubOAuthService())
        XCTAssertThrowsError(try coordinator.startSignIn(appKey: "   "))
    }

    func testStatusPresenterUsesOutcomeContract() {
        XCTAssertEqual(
            StatusPresenter.presentation(for: .status(.init(kind: .connecting, message: "Connecting to Dropbox…"))).state,
            .connecting
        )
        XCTAssertEqual(
            StatusPresenter.presentation(for: .status(.init(kind: .progress, message: "1 of 2 file — downloading…"))).state,
            .progress
        )
        XCTAssertEqual(StatusPresenter.presentation(for: .failed(NSError(domain: NSURLErrorDomain, code: -1))).state, .error)
    }

    func testSettingsFormModelSavesNormalizedValues() {
        var store = InMemorySettingsStore()
        var model = SettingsFormModel(
            appKeyInput: "  app-key  ",
            folderPathInput: "  /Photos  ",
            intervalInput: "999"
        )
        model.save(to: &store)

        XCTAssertEqual(store.string(forKey: ScreenSaverSettings.Key.dropboxAppKey), "app-key")
        XCTAssertEqual(store.string(forKey: ScreenSaverSettings.Key.dropboxFolderPath), "/Photos")
        XCTAssertEqual(store.integer(forKey: ScreenSaverSettings.Key.slideIntervalSeconds), 120)
    }
}

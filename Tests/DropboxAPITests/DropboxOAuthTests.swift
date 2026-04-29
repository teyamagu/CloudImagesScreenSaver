@testable import DropboxAPI
import XCTest

final class DropboxOAuthTests: XCTestCase {
    func testPKCEVerifierUsesAllowedCharsetAndLength() {
        let v = DropboxOAuth.generateCodeVerifier()
        XCTAssertGreaterThanOrEqual(v.count, 43)
        XCTAssertLessThanOrEqual(v.count, 128)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        XCTAssertNil(v.rangeOfCharacter(from: allowed.inverted))
    }

    func testCodeChallengeS256IsBase64URLWithoutPadding() {
        let v = DropboxOAuth.generateCodeVerifier()
        let c = DropboxOAuth.codeChallengeS256(verifier: v)
        XCTAssertFalse(c.contains("+"), c)
        XCTAssertFalse(c.contains("/"), c)
        XCTAssertFalse(c.contains("="), c)
        XCTAssertGreaterThan(c.count, 10)
    }
}

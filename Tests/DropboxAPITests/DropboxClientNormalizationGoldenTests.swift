@testable import DropboxAPI
import Foundation
import XCTest

/// Locks in current `normalizeFolderPath` / `isRetriableURLError` behavior.
final class DropboxClientNormalizationGoldenTests: XCTestCase {
    func testNormalizeFolderPathTrimsAndSlashRules() {
        XCTAssertEqual(DropboxClient.normalizeFolderPath(""), "")
        XCTAssertEqual(DropboxClient.normalizeFolderPath("   "), "")
        XCTAssertEqual(DropboxClient.normalizeFolderPath("/"), "")
        XCTAssertEqual(DropboxClient.normalizeFolderPath("  /  "), "")
        XCTAssertEqual(DropboxClient.normalizeFolderPath("foo"), "/foo")
        XCTAssertEqual(DropboxClient.normalizeFolderPath("/foo"), "/foo")
        XCTAssertEqual(DropboxClient.normalizeFolderPath("  /foo/  "), "/foo")
        XCTAssertEqual(DropboxClient.normalizeFolderPath("/foo/"), "/foo")
        // Only one trailing slash segment is stripped (current behavior).
        XCTAssertEqual(DropboxClient.normalizeFolderPath("/foo//"), "/foo/")
    }

    func testIsRetriableURLErrorPositiveCases() {
        let codes: [URLError.Code] = [
            .networkConnectionLost,
            .timedOut,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .notConnectedToInternet,
        ]
        for code in codes {
            let e = URLError(code)
            XCTAssertTrue(DropboxClient.isRetriableURLError(e), "\(code)")
        }
    }

    func testIsRetriableURLErrorNegativeCases() {
        XCTAssertFalse(DropboxClient.isRetriableURLError(NSError(domain: "custom", code: 1)))
        XCTAssertFalse(DropboxClient.isRetriableURLError(URLError(.badServerResponse)))
        XCTAssertFalse(DropboxClient.isRetriableURLError(URLError(.cancelled)))
    }
}

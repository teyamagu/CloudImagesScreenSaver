@testable import DropboxAPI
import Foundation
import XCTest

/// Locks in current `DropboxClientError` `LocalizedError` strings.
final class DropboxClientErrorGoldenTests: XCTestCase {
    func testInvalidHTTPResponseDescription() {
        let e = DropboxClientError.invalidHTTPResponse
        XCTAssertEqual(
            e.errorDescription,
            "Invalid HTTP response from Dropbox."
        )
    }

    func testApiRequestFailedDescription() {
        let e = DropboxClientError.apiRequestFailed(statusCode: 400, responseBody: "bad")
        XCTAssertEqual(
            e.errorDescription,
            "Dropbox API error (400): bad"
        )
    }

    func testMissingDropboxApiResultHeaderDescription() {
        let e = DropboxClientError.missingDropboxApiResultHeader
        XCTAssertEqual(
            e.errorDescription,
            "Missing Dropbox-Api-Result header on download response."
        )
    }
}

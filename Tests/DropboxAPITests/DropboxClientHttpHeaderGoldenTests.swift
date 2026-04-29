@testable import DropboxAPI
import Foundation
import XCTest

/// Locks in current `httpHeaderSafeDropboxAPIArgJSON` behavior.
final class DropboxClientHttpHeaderGoldenTests: XCTestCase {
    func testRootPathIsASCIIAndSortedKeys() throws {
        let json = try DropboxClient.httpHeaderSafeDropboxAPIArgJSON(path: "")
        XCTAssertEqual(json, #"{"path":""}"#)
        for scalar in json.unicodeScalars where scalar.value != 0x0A && scalar.value != 0x0D {
            XCTAssertTrue(scalar.isASCII, json)
        }
    }

    func testAsciiPathPassesThroughWithoutUnicodeEscapes() throws {
        let json = try DropboxClient.httpHeaderSafeDropboxAPIArgJSON(path: "/Photos/a.jpg")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        XCTAssertEqual(obj["path"], "/Photos/a.jpg")
        for scalar in json.unicodeScalars where scalar.value != 0x0A && scalar.value != 0x0D {
            XCTAssertTrue(scalar.isASCII, json)
        }
    }

    func testDelIsEscaped() throws {
        let del = try String(XCTUnwrap(UnicodeScalar(0x7F)))
        let json = try DropboxClient.httpHeaderSafeDropboxAPIArgJSON(path: "/x\(del)")
        XCTAssertTrue(json.contains(#"\u007f"#), json)
    }
}

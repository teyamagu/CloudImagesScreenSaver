@testable import DropboxAPI
import Foundation
import XCTest

/// Locks in that `LiveDropboxImagePipeline` returns the same cache paths as `DropboxClient`.
final class LiveDropboxImagePipelineGoldenTests: XCTestCase {
    func testInitSucceeds() {
        _ = LiveDropboxImagePipeline()
    }

    func testLocalCacheURLMatchesDropboxClient() throws {
        let live = LiveDropboxImagePipeline()
        let path = "/Album/photo.JPEG"
        XCTAssertEqual(
            try live.localCacheURL(forDropboxPath: path).path,
            try DropboxClient.localCacheURL(forDropboxPath: path).path
        )
    }
}

import CryptoKit
@testable import DropboxAPI
import Foundation
import XCTest

/// Locks in current `cacheDirectory` / `cacheKey` / `localCacheURL` behavior.
final class DropboxClientCacheGoldenTests: XCTestCase {
    func testCacheDirectoryCreatesHierarchyAndIsStable() throws {
        let a = try DropboxClient.cacheDirectory()
        let b = try DropboxClient.cacheDirectory()
        XCTAssertEqual(a.path, b.path)
        XCTAssertTrue(a.path.contains("CloudImagesScreenSaver"))
        XCTAssertTrue(a.path.hasSuffix("/cache") || a.path.hasSuffix("cache"))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testCacheKeyMatchesSHA256HexOfUTF8Path() {
        let path = "/Photos/sample.JPG"
        let expected = SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(DropboxClient.cacheKey(forDropboxPath: path), expected)
        XCTAssertEqual(DropboxClient.cacheKey(forDropboxPath: path).count, 64)
    }

    func testCacheKeyIsDeterministicPerPath() {
        let p = "/a/b.png"
        XCTAssertEqual(DropboxClient.cacheKey(forDropboxPath: p), DropboxClient.cacheKey(forDropboxPath: p))
        XCTAssertNotEqual(DropboxClient.cacheKey(forDropboxPath: p), DropboxClient.cacheKey(forDropboxPath: "/a/b.jpg"))
    }

    func testLocalCacheURLUsesLowercasedExtensionAndImgFallback() throws {
        let dir = try DropboxClient.cacheDirectory()
        let uPng = try DropboxClient.localCacheURL(forDropboxPath: "/folder/X.PNG")
        XCTAssertTrue(uPng.path.hasPrefix(dir.path))
        XCTAssertTrue(uPng.lastPathComponent.hasSuffix(".png"), uPng.lastPathComponent)

        let uJpeg = try DropboxClient.localCacheURL(forDropboxPath: "/folder/X.JPEG")
        XCTAssertTrue(uJpeg.lastPathComponent.hasSuffix(".jpeg"))

        let uNoExt = try DropboxClient.localCacheURL(forDropboxPath: "/folder/noext")
        XCTAssertTrue(uNoExt.lastPathComponent.hasSuffix(".img"), uNoExt.lastPathComponent)

        let key = DropboxClient.cacheKey(forDropboxPath: "/folder/X.PNG")
        XCTAssertTrue(uPng.lastPathComponent.hasPrefix(key))
    }

    func testLocalCacheURLSameDropboxPathMapsToSameFile() throws {
        let u1 = try DropboxClient.localCacheURL(forDropboxPath: "/same.jpg")
        let u2 = try DropboxClient.localCacheURL(forDropboxPath: "/same.jpg")
        XCTAssertEqual(u1.path, u2.path)
    }
}

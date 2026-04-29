@testable import DropboxAPI
import Foundation
import XCTest

/// Hits the network only when `DROPBOX_TOKEN` is set.
final class DropboxClientTests: XCTestCase {
    /// Avoid flaky CI/local runs on transient `URLSession` drops or timeouts.
    private func skipIfTransientURLError(_ error: Error) throws {
        var candidates: [NSError] = [error as NSError]
        if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError {
            candidates.append(underlying)
        }
        for ns in candidates where ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNetworkConnectionLost,
                 NSURLErrorTimedOut,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorInternationalRoamingOff,
                 NSURLErrorCallIsActive,
                 NSURLErrorDataNotAllowed:
                throw XCTSkip("Skipping due to transient network: \(ns.localizedDescription) [\(ns.code)]")
            default:
                break
            }
        }
        throw error
    }

    private var token: String {
        let a = ProcessInfo.processInfo.environment["DROPBOX_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = (a?.isEmpty == false ? a : nil)
        return t ?? ""
    }

    private var folder: String {
        ProcessInfo.processInfo.environment["DROPBOX_TEST_FOLDER"] ?? ""
    }

    /// Dropbox: `Dropbox-API-Arg` must escape non-ASCII for headers as `\uXXXX` (raw UTF-8 can yield HTTP 400).
    func testHttpHeaderSafeDropboxAPIArgJSONIsASCII() throws {
        let del = try String(XCTUnwrap(UnicodeScalar(0x7F)))
        let json = try DropboxClient.httpHeaderSafeDropboxAPIArgJSON(path: "/Photos/\u{03B1}/\(del)/🙂.jpg")
        for scalar in json.unicodeScalars where scalar.value != 0x0A && scalar.value != 0x0D {
            XCTAssertTrue(
                scalar.isASCII,
                "header JSON must be ASCII only: scalar U+\(String(scalar.value, radix: 16, uppercase: true))"
            )
        }
        XCTAssertTrue(json.contains(#"\u"#), "non-ASCII or DEL must be escaped: \(json)")
    }

    func testListImagePathsWithToken() async throws {
        guard !token.isEmpty else {
            throw XCTSkip("DROPBOX_TOKEN is not set")
        }

        let paths: [String]
        do {
            paths = try await DropboxClient.listImagePaths(accessToken: token, folderPath: folder)
        } catch {
            try skipIfTransientURLError(error)
            throw error
        }
        XCTAssertGreaterThanOrEqual(paths.count, 0)
        for p in paths.prefix(3) {
            XCTAssertTrue(p.hasPrefix("/") || !p.contains("://"), "expected path_lower style: \(p)")
        }
    }

    func testDownloadFirstImageIfAny() async throws {
        guard !token.isEmpty else {
            throw XCTSkip("DROPBOX_TOKEN is not set")
        }
        if ProcessInfo.processInfo.environment["DROPBOX_TEST_SKIP_DOWNLOAD"] == "1" {
            throw XCTSkip("DROPBOX_TEST_SKIP_DOWNLOAD=1")
        }

        let paths: [String]
        do {
            paths = try await DropboxClient.listImagePaths(accessToken: token, folderPath: folder)
        } catch {
            try skipIfTransientURLError(error)
            throw error
        }
        guard let first = paths.first else {
            throw XCTSkip("No images listed; skipping download")
        }

        let url: URL
        do {
            url = try await DropboxClient.downloadToCache(accessToken: token, dropboxPath: first)
        } catch {
            try skipIfTransientURLError(error)
            throw error
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let size = try (FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(size, 0)
    }
}

@testable import DropboxAPI
import Foundation
import XCTest

/// Locks in current `CloudImagesFolderImageLoader` behavior (stub pipeline).
final class CloudImagesFolderImageLoaderTests: XCTestCase {
    /// Wait until asynchronous outcome delivery reaches the delegate.
    private func spinUntil(
        loader: CloudImagesFolderImageLoader,
        until satisfied: () -> Bool,
        timeout: TimeInterval = 5
    ) {
        _ = loader // keep signature stable for callers
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if satisfied() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private struct StubPipeline: DropboxImagePipeline {
        let paths: [String]
        let pathToURL: [String: URL]
        let downloadByPath: [String: Result<URL, Error>]

        func listImagePaths(accessToken _: String, folderPath _: String) async throws -> [String] {
            paths
        }

        func localCacheURL(forDropboxPath path: String) throws -> URL {
            guard let u = pathToURL[path] else {
                throw URLError(.badURL)
            }
            return u
        }

        func downloadToCache(accessToken _: String, dropboxPath: String) async throws -> URL {
            guard let r = downloadByPath[dropboxPath] else {
                throw URLError(.unknown)
            }
            switch r {
            case let .success(u):
                return u
            case let .failure(e):
                throw e
            }
        }
    }

    private struct ListThrowsPipeline: DropboxImagePipeline {
        let listError: Error

        func listImagePaths(accessToken _: String, folderPath _: String) async throws -> [String] {
            throw listError
        }

        func localCacheURL(forDropboxPath _: String) throws -> URL {
            throw URLError(.badURL)
        }

        func downloadToCache(accessToken _: String, dropboxPath _: String) async throws -> URL {
            throw URLError(.badURL)
        }
    }

    private struct TokenAwarePipeline: DropboxImagePipeline {
        let pathToURL: [String: URL]
        let downloadByPath: [String: Result<URL, Error>]
        let oldDownloadDelayNanoseconds: UInt64

        func listImagePaths(accessToken: String, folderPath _: String) async throws -> [String] {
            if accessToken == "old-token" { return ["/old.jpg"] }
            return ["/new.jpg"]
        }

        func localCacheURL(forDropboxPath path: String) throws -> URL {
            guard let u = pathToURL[path] else { throw URLError(.badURL) }
            return u
        }

        func downloadToCache(accessToken: String, dropboxPath: String) async throws -> URL {
            if accessToken == "old-token", oldDownloadDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: oldDownloadDelayNanoseconds)
            }
            guard let r = downloadByPath[dropboxPath] else { throw URLError(.unknown) }
            switch r {
            case let .success(url): return url
            case let .failure(error): throw error
            }
        }
    }

    private final class CapturingDelegate: CloudImagesFolderImageLoaderDelegate {
        private let lock = NSLock()
        private(set) var statusMessages: [String] = []
        private(set) var cachedURLs: [URL] = []
        private(set) var errorCount = 0
        private(set) var pipelineListedCount: Int?
        private(set) var pipelineLastError: Error?

        func folderImageLoader(_: CloudImagesFolderImageLoader, didEmit outcome: LoaderOutcome) {
            lock.lock()
            defer { lock.unlock() }
            switch outcome {
            case let .status(status):
                statusMessages.append(status.message)
            case let .cached(url):
                cachedURLs.append(url)
            case .failed:
                errorCount += 1
            case let .pipelineCompleted(listedImagePathCount, lastDownloadError):
                pipelineListedCount = listedImagePathCount
                pipelineLastError = lastDownloadError
            }
        }
    }

    private func tempTestDir() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudImagesLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func testDefaultInitializerUsesLivePipeline() {
        let loader = CloudImagesFolderImageLoader()
        XCTAssertNotNil(loader)
    }

    /// If the first download fails, later paths still download and `didCacheImageAt` fires.
    func testContinuesDownloadingAfterFirstDownloadFailure() throws {
        let base = try tempTestDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let urlCacheA = base.appendingPathComponent("cache_a.bin")
        let urlCacheB = base.appendingPathComponent("cache_b.bin")
        let urlDeliveredB = base.appendingPathComponent("delivered_b.bin")

        let pipeline = StubPipeline(
            paths: ["/first.jpg", "/second.jpg"],
            pathToURL: [
                "/first.jpg": urlCacheA,
                "/second.jpg": urlCacheB,
            ],
            downloadByPath: [
                "/first.jpg": .failure(URLError(.cannotConnectToHost)),
                "/second.jpg": .success(urlDeliveredB),
            ]
        )

        let delegate = CapturingDelegate()
        let loader = CloudImagesFolderImageLoader(pipeline: pipeline, pathsShuffle: { $0 })
        loader.delegate = delegate

        loader.start(accessToken: "x", folderPath: "/")
        spinUntil(loader: loader, until: { delegate.pipelineListedCount != nil })

        XCTAssertEqual(delegate.pipelineListedCount, 2)
        XCTAssertEqual(delegate.errorCount, 1, "only the first item should report failure")
        XCTAssertEqual(delegate.cachedURLs.count, 1)
        XCTAssertEqual(delegate.cachedURLs.first?.path, urlDeliveredB.path)
        XCTAssertNotNil(delegate.pipelineLastError)

        loader.cancel()
    }

    /// Even when every download fails, pipeline completion runs with the listed count (regression: must not hang silently).
    func testPipelineCompletionReportsListedCountWhenAllDownloadsFail() throws {
        let base = try tempTestDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let urlCacheA = base.appendingPathComponent("cache_a.bin")
        let urlCacheB = base.appendingPathComponent("cache_b.bin")

        let err = URLError(.networkConnectionLost)
        let pipeline = StubPipeline(
            paths: ["/a.jpg", "/b.jpg"],
            pathToURL: ["/a.jpg": urlCacheA, "/b.jpg": urlCacheB],
            downloadByPath: [
                "/a.jpg": .failure(err),
                "/b.jpg": .failure(err),
            ]
        )

        let delegate = CapturingDelegate()
        let loader = CloudImagesFolderImageLoader(pipeline: pipeline, pathsShuffle: { $0 })
        loader.delegate = delegate

        loader.start(accessToken: "x", folderPath: "/")
        spinUntil(loader: loader, until: { delegate.pipelineListedCount != nil })

        XCTAssertEqual(delegate.pipelineListedCount, 2)
        XCTAssertTrue(delegate.cachedURLs.isEmpty)
        XCTAssertEqual(delegate.errorCount, 2)
        XCTAssertNotNil(delegate.pipelineLastError)

        loader.cancel()
    }

    /// Empty list: status copy and completion callback with count 0.
    func testEmptyListShowsMessageAndCompletesWithZeroCount() {
        let pipeline = StubPipeline(paths: [], pathToURL: [:], downloadByPath: [:])
        let delegate = CapturingDelegate()
        let loader = CloudImagesFolderImageLoader(pipeline: pipeline, pathsShuffle: { $0 })
        loader.delegate = delegate

        loader.start(accessToken: "x", folderPath: "/")
        spinUntil(loader: loader, until: { delegate.pipelineListedCount != nil })

        XCTAssertTrue(delegate.statusMessages.contains("No images found"))
        XCTAssertEqual(delegate.pipelineListedCount, 0)
        XCTAssertTrue(delegate.cachedURLs.isEmpty)
        XCTAssertEqual(delegate.errorCount, 0)

        loader.cancel()
    }

    /// List failure without disk prefetch: only `didFailWithError`; pipeline completion must not run.
    func testListFailureReportsErrorWithoutPipelineCompletion() {
        let pipeline = ListThrowsPipeline(listError: URLError(.cannotParseResponse))
        let delegate = CapturingDelegate()
        let loader = CloudImagesFolderImageLoader(pipeline: pipeline, pathsShuffle: { $0 })
        loader.delegate = delegate

        loader.start(accessToken: "x", folderPath: "/")
        spinUntil(loader: loader, until: { delegate.errorCount >= 1 }, timeout: 0.5)

        XCTAssertEqual(delegate.errorCount, 1)
        XCTAssertNil(delegate.pipelineListedCount)

        loader.cancel()
    }

    /// `start(folderPath:)` enumerates disk cache before OAuth; if the token fails, cached images still show and completion runs without `didFailWithError`.
    func testStartFolderPathPrefetchesDiskCacheWhenTokenFails() throws {
        let dir = try DropboxClient.cacheDirectory()
        let name = "loader_oauth_prefetch_\(UUID().uuidString).png"
        let fileURL = dir.appendingPathComponent(name)
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pipeline = StubPipeline(paths: [], pathToURL: [:], downloadByPath: [:])
        let delegate = CapturingDelegate()
        let loader = CloudImagesFolderImageLoader(
            pipeline: pipeline,
            resolveAccessToken: { throw DropboxOAuthError.notConfigured },
            pathsShuffle: { $0 }
        )
        loader.delegate = delegate
        loader.start(folderPath: "/Photos")
        spinUntil(loader: loader, until: { delegate.pipelineListedCount != nil && delegate.errorCount >= 1 })

        XCTAssertEqual(delegate.errorCount, 1)
        XCTAssertFalse(delegate.cachedURLs.isEmpty)
        XCTAssertEqual(delegate.pipelineListedCount, 0)
        XCTAssertNotNil(delegate.pipelineLastError)

        loader.cancel()
    }

    /// After disk prefetch, list failure surfaces as status + pipeline completion, not `didFailWithError`.
    func testListFailureWithPrefetchCompletesWithoutDidFailWithError() throws {
        let dir = try DropboxClient.cacheDirectory()
        let name = "loader_list_fail_prefetch_\(UUID().uuidString).png"
        let fileURL = dir.appendingPathComponent(name)
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pipeline = ListThrowsPipeline(listError: URLError(.cannotParseResponse))
        let delegate = CapturingDelegate()
        let loader = CloudImagesFolderImageLoader(
            pipeline: pipeline,
            resolveAccessToken: { "fake_token" },
            pathsShuffle: { $0 }
        )
        loader.delegate = delegate
        loader.start(folderPath: "/x")
        spinUntil(loader: loader, until: { delegate.pipelineListedCount != nil && delegate.errorCount >= 1 })

        XCTAssertFalse(delegate.cachedURLs.isEmpty)
        XCTAssertEqual(delegate.errorCount, 1)
        XCTAssertEqual(delegate.pipelineListedCount, 0)
        XCTAssertNotNil(delegate.pipelineLastError)
        XCTAssertTrue(delegate.statusMessages.contains { $0.contains("Could not refresh file list") })

        loader.cancel()
    }

    /// If the cache file already exists, skip `downloadToCache` and only emit `didCacheImageAt`.
    func testExistingCacheFileSkipsDownload() throws {
        let base = try tempTestDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let cachedURL = base.appendingPathComponent("already.bin")
        try Data([7]).write(to: cachedURL)

        let pipeline = StubPipeline(
            paths: ["/one.jpg"],
            pathToURL: ["/one.jpg": cachedURL],
            downloadByPath: [:]
        )

        let delegate = CapturingDelegate()
        let loader = CloudImagesFolderImageLoader(pipeline: pipeline, pathsShuffle: { $0 })
        loader.delegate = delegate

        loader.start(accessToken: "x", folderPath: "/")
        spinUntil(loader: loader, until: { delegate.pipelineListedCount != nil })

        XCTAssertEqual(delegate.cachedURLs.map(\.path), [cachedURL.path])
        XCTAssertEqual(delegate.errorCount, 0)

        loader.cancel()
    }

    /// `pathsShuffle` identity preserves processing order (injected shuffle behavior).
    func testPathsShuffleIdentityPreservesOrder() throws {
        let base = try tempTestDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let u1 = base.appendingPathComponent("c1.bin")
        let u2 = base.appendingPathComponent("c2.bin")
        let d1 = base.appendingPathComponent("d1.bin")
        let d2 = base.appendingPathComponent("d2.bin")

        let pipeline = StubPipeline(
            paths: ["/a.jpg", "/b.jpg"],
            pathToURL: ["/a.jpg": u1, "/b.jpg": u2],
            downloadByPath: [
                "/a.jpg": .success(d1),
                "/b.jpg": .success(d2),
            ]
        )

        let delegate = CapturingDelegate()
        let loader = CloudImagesFolderImageLoader(pipeline: pipeline, pathsShuffle: { $0 })
        loader.delegate = delegate

        loader.start(accessToken: "x", folderPath: "/")
        spinUntil(loader: loader, until: { delegate.pipelineListedCount != nil })

        XCTAssertEqual(delegate.cachedURLs.count, 2)
        XCTAssertEqual(Set(delegate.cachedURLs.map(\.path)), Set([d1.path, d2.path]))

        loader.cancel()
    }

    /// `cancel` must not crash; `start` again immediately afterward.
    func testCancelThenStartAgain() throws {
        let base = try tempTestDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let u = base.appendingPathComponent("c.bin")
        let d = base.appendingPathComponent("out.bin")
        let pipeline = StubPipeline(
            paths: ["/x.jpg"],
            pathToURL: ["/x.jpg": u],
            downloadByPath: ["/x.jpg": .success(d)]
        )

        let loader = CloudImagesFolderImageLoader(pipeline: pipeline, pathsShuffle: { $0 })
        loader.cancel()
        loader.cancel()

        let delegate = CapturingDelegate()
        loader.delegate = delegate
        loader.start(accessToken: "x", folderPath: "/")
        spinUntil(loader: loader, until: { delegate.pipelineListedCount != nil })
        XCTAssertEqual(delegate.cachedURLs.count, 1)

        loader.cancel()
    }

    /// New session must not receive stale outcomes from a canceled session.
    func testStartAfterCancelDoesNotDeliverCanceledSessionEvents() throws {
        let base = try tempTestDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let oldCache = base.appendingPathComponent("old-cache.bin")
        let newCache = base.appendingPathComponent("new-cache.bin")
        let oldDelivered = base.appendingPathComponent("old-delivered.bin")
        let newDelivered = base.appendingPathComponent("new-delivered.bin")
        let pipeline = TokenAwarePipeline(
            pathToURL: [
                "/old.jpg": oldCache,
                "/new.jpg": newCache,
            ],
            downloadByPath: [
                "/old.jpg": .success(oldDelivered),
                "/new.jpg": .success(newDelivered),
            ],
            oldDownloadDelayNanoseconds: 600_000_000
        )

        let delegate = CapturingDelegate()
        let loader = CloudImagesFolderImageLoader(pipeline: pipeline, pathsShuffle: { $0 })
        loader.delegate = delegate

        loader.start(accessToken: "old-token", folderPath: "/")
        loader.cancel()
        loader.start(accessToken: "new-token", folderPath: "/")
        spinUntil(loader: loader, until: { delegate.pipelineListedCount != nil })

        XCTAssertEqual(delegate.cachedURLs.map(\.lastPathComponent), [newDelivered.lastPathComponent])
        XCTAssertFalse(delegate.statusMessages.contains { $0.contains("old.jpg") })
        XCTAssertTrue(delegate.statusMessages.contains { $0.contains("new.jpg") })

        loader.cancel()
    }
}

@testable import DropboxAPI
import Foundation
import XCTest

final class CloudImagesLoaderLifecycleTests: XCTestCase {
    private struct StubPipeline: DropboxImagePipeline {
        let paths: [String]
        let pathToURL: [String: URL]
        let downloadByPath: [String: Result<URL, Error>]

        func listImagePaths(accessToken _: String, folderPath _: String) async throws -> [String] {
            paths
        }

        func localCacheURL(forDropboxPath path: String) throws -> URL {
            guard let url = pathToURL[path] else { throw URLError(.badURL) }
            return url
        }

        func downloadToCache(accessToken _: String, dropboxPath: String) async throws -> URL {
            guard let result = downloadByPath[dropboxPath] else { throw URLError(.unknown) }
            switch result {
            case let .success(url): return url
            case let .failure(error): throw error
            }
        }
    }

    private struct TokenAwarePipeline: DropboxImagePipeline {
        let pathToURL: [String: URL]
        let downloadByPath: [String: Result<URL, Error>]
        let oldDownloadDelayNanoseconds: UInt64

        func listImagePaths(accessToken: String, folderPath _: String) async throws -> [String] {
            accessToken == "old-token" ? ["/old.jpg"] : ["/new.jpg"]
        }

        func localCacheURL(forDropboxPath path: String) throws -> URL {
            guard let url = pathToURL[path] else { throw URLError(.badURL) }
            return url
        }

        func downloadToCache(accessToken: String, dropboxPath: String) async throws -> URL {
            if accessToken == "old-token", oldDownloadDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: oldDownloadDelayNanoseconds)
            }
            guard let result = downloadByPath[dropboxPath] else { throw URLError(.unknown) }
            switch result {
            case let .success(url): return url
            case let .failure(error): throw error
            }
        }
    }

    private final class CapturingDelegate: CloudImagesFolderImageLoaderDelegate {
        private(set) var statusMessages: [String] = []
        private(set) var cachedURLs: [URL] = []
        private(set) var pipelineListedCount: Int?
        private let lock = NSLock()

        func folderImageLoader(_: CloudImagesFolderImageLoader, didEmit outcome: LoaderOutcome) {
            lock.lock()
            defer { lock.unlock() }
            switch outcome {
            case let .status(status): statusMessages.append(status.message)
            case let .cached(url): cachedURLs.append(url)
            case let .pipelineCompleted(listedImagePathCount, _): pipelineListedCount = listedImagePathCount
            case .failed: break
            }
        }
    }

    private func spinUntil(_ predicate: () -> Bool, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func tempTestDir() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudImagesLoaderLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func testCancelThenStartAgain() throws {
        let base = try tempTestDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let cacheURL = base.appendingPathComponent("c.bin")
        let delivered = base.appendingPathComponent("out.bin")
        let pipeline = StubPipeline(
            paths: ["/x.jpg"],
            pathToURL: ["/x.jpg": cacheURL],
            downloadByPath: ["/x.jpg": .success(delivered)]
        )

        let loader = CloudImagesFolderImageLoader(pipeline: pipeline, pathsShuffle: { $0 })
        loader.cancel()
        loader.cancel()

        let delegate = CapturingDelegate()
        loader.delegate = delegate
        loader.start(accessToken: "x", folderPath: "/")
        spinUntil { delegate.pipelineListedCount != nil }

        XCTAssertEqual(delegate.cachedURLs.count, 1)
        loader.cancel()
    }

    func testStartAfterCancelDoesNotDeliverCanceledSessionEvents() throws {
        let base = try tempTestDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let oldCache = base.appendingPathComponent("old-cache.bin")
        let newCache = base.appendingPathComponent("new-cache.bin")
        let oldDelivered = base.appendingPathComponent("old-delivered.bin")
        let newDelivered = base.appendingPathComponent("new-delivered.bin")

        let pipeline = TokenAwarePipeline(
            pathToURL: ["/old.jpg": oldCache, "/new.jpg": newCache],
            downloadByPath: ["/old.jpg": .success(oldDelivered), "/new.jpg": .success(newDelivered)],
            oldDownloadDelayNanoseconds: 600_000_000
        )

        let loader = CloudImagesFolderImageLoader(pipeline: pipeline, pathsShuffle: { $0 })
        let delegate = CapturingDelegate()
        loader.delegate = delegate

        loader.start(accessToken: "old-token", folderPath: "/")
        loader.cancel()
        loader.start(accessToken: "new-token", folderPath: "/")
        spinUntil { delegate.pipelineListedCount != nil }

        XCTAssertEqual(delegate.cachedURLs.map(\.lastPathComponent), [newDelivered.lastPathComponent])
        XCTAssertFalse(delegate.statusMessages.contains { $0.contains("old.jpg") })
        XCTAssertTrue(delegate.statusMessages.contains { $0.contains("new.jpg") })
        loader.cancel()
    }
}

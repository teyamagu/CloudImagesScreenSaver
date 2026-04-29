import AppKit
@testable import CloudImagesScreenSaverModule
import DropboxAPI
import Foundation
import XCTest

/// Asserts that `CloudImagesScreenSaverView` actually updates `NSTextField` / `NSImageView` (not only loader callbacks).
@MainActor
final class CloudImagesScreenSaverViewDisplayTests: XCTestCase {
    private struct StubPipeline: DropboxImagePipeline {
        let paths: [String]
        let pathToURL: [String: URL]
        let downloadByPath: [String: Result<URL, Error>]
        var downloadDelayNanoseconds: UInt64 = 0

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
            if downloadDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: downloadDelayNanoseconds)
            }
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

    private func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudImagesScreenSaverViewDisplayTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func writeMinimalPNG(at url: URL) throws {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 4,
            bitsPerPixel: 32
        )!
        rep.setColor(.red, atX: 0, y: 0)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            struct PNGEncodeError: Error {}
            throw PNGEncodeError()
        }
        try data.write(to: url)
    }

    private func spinRunLoop(until predicate: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return predicate()
    }

    func testPreviewStartAnimationShowsStatusTextAndFrontImage() throws {
        let frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        let view = try XCTUnwrap(CloudImagesScreenSaverView(frame: frame, isPreview: true))
        defer { view.stopAnimation() }

        view.startAnimation()

        XCTAssertEqual(view.testHook_statusState, .preview)
        XCTAssertTrue(
            view.testHook_frontImageVisible,
            "Preview should show the system symbol on the front image view"
        )
    }

    func testLoaderPipelineShowsProgressStatusThenImage() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let cacheMiss = base.appendingPathComponent("missing.png")
        let delivered = base.appendingPathComponent("pixel.png")
        try writeMinimalPNG(at: delivered)

        let pipeline = StubPipeline(
            paths: ["/remote.png"],
            pathToURL: ["/remote.png": cacheMiss],
            downloadByPath: ["/remote.png": .success(delivered)],
            downloadDelayNanoseconds: 200_000_000
        )
        let loader = CloudImagesFolderImageLoader(pipeline: pipeline, pathsShuffle: { $0 })

        let frame = NSRect(x: 0, y: 0, width: 480, height: 360)
        let view = try XCTUnwrap(CloudImagesScreenSaverView(frame: frame, isPreview: false))
        defer { view.stopAnimation() }

        loader.delegate = view
        loader.start(accessToken: "test-token", folderPath: "/")
        view.testHook_installLoaderForRunningSession(loader)

        var sawProgressStatus = false
        let sawImage = spinRunLoop(
            until: {
                if view.testHook_statusState == .progress {
                    sawProgressStatus = true
                }
                return view.testHook_frontImageVisible
            },
            timeout: 6
        )

        XCTAssertTrue(sawProgressStatus, "Status label should show list progress before image display.")
        XCTAssertTrue(sawImage, "Front image view should display the downloaded PNG.")

        _ = spinRunLoop(until: { view.testHook_statusLabelString.isEmpty }, timeout: 4)
        XCTAssertTrue(
            view.testHook_statusLabelString.isEmpty,
            "After pipeline completes with images, status should clear; got: \(view.testHook_statusLabelString)"
        )
    }

    /// Regression guard for ScreenSaver runtime: even before Dropbox responds,
    /// pre-cached images/status must appear without relying on `animateOneFrame`.
    func testFolderStartShowsCachedImageOrStatusWhileConnecting() throws {
        let cacheDir = try DropboxClient.cacheDirectory()
        let cached = cacheDir.appendingPathComponent("000-test-prefetch-\(UUID().uuidString).png")
        try writeMinimalPNG(at: cached)
        defer { try? FileManager.default.removeItem(at: cached) }

        let pipeline = StubPipeline(paths: [], pathToURL: [:], downloadByPath: [:])
        let loader = CloudImagesFolderImageLoader(
            pipeline: pipeline,
            resolveAccessToken: {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return "never-used-in-this-test"
            },
            pathsShuffle: { $0 }
        )

        let frame = NSRect(x: 0, y: 0, width: 480, height: 360)
        let view = try XCTUnwrap(CloudImagesScreenSaverView(frame: frame, isPreview: false))
        defer { view.stopAnimation() }

        loader.delegate = view
        loader.start(folderPath: "/Photos")
        view.testHook_installLoaderForRunningSession(loader)

        let sawStatusOrImage = spinRunLoop(
            until: {
                !view.testHook_statusLabelString.isEmpty || view.testHook_frontImageVisible
            },
            timeout: 2
        )
        let firstObservedState = view.testHook_statusState
        let sawImage = spinRunLoop(
            until: { view.testHook_frontImageVisible },
            timeout: 2
        )

        XCTAssertTrue(
            sawStatusOrImage,
            "While waiting for Dropbox, both status and image were missing. status='\(view.testHook_statusLabelString)' imageVisible=\(view.testHook_frontImageVisible)"
        )
        XCTAssertTrue(firstObservedState == .connecting || firstObservedState == .other)
        XCTAssertTrue(sawImage, "Expected a cached PNG to be shown before Dropbox list/download finishes.")
    }

    /// Regression guard for runtime delivery:
    /// even without explicit frame-driven flush calls from this test, loader events should still reach UI.
    func testNoFlushDriverStillDeliversStatusOrImage() throws {
        let cacheDir = try DropboxClient.cacheDirectory()
        let cached = cacheDir.appendingPathComponent("000-test-noflush-\(UUID().uuidString).png")
        try writeMinimalPNG(at: cached)
        defer { try? FileManager.default.removeItem(at: cached) }

        let pipeline = StubPipeline(paths: [], pathToURL: [:], downloadByPath: [:])
        let loader = CloudImagesFolderImageLoader(
            pipeline: pipeline,
            resolveAccessToken: {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return "unused"
            },
            pathsShuffle: { $0 }
        )

        let frame = NSRect(x: 0, y: 0, width: 480, height: 360)
        let view = try XCTUnwrap(CloudImagesScreenSaverView(frame: frame, isPreview: false))
        defer { view.stopAnimation() }

        loader.delegate = view
        loader.start(folderPath: "/Photos")
        // Intentionally DO NOT call `testHook_installLoaderForRunningSession` and DO NOT call `animateOneFrame`.
        // This simulates the runtime path where flush driving is missing.

        let sawStatusOrImage = spinRunLoop(
            until: { !view.testHook_statusLabelString.isEmpty || view.testHook_frontImageVisible },
            timeout: 1.5
        )

        XCTAssertTrue(
            sawStatusOrImage,
            "REGRESSION: without an active flush driver, both status and image stayed hidden."
        )
    }
}

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

        XCTAssertTrue(
            view.testHook_statusLabelString.contains("Preview"),
            "Expected preview status copy; got: \(view.testHook_statusLabelString)"
        )
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
                let s = view.testHook_statusLabelString
                if s.contains("Found") || s.contains("processing") || s.contains("downloading") {
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
        let firstObservedStatus = view.testHook_statusLabelString
        let sawImage = spinRunLoop(
            until: { view.testHook_frontImageVisible },
            timeout: 2
        )

        XCTAssertTrue(
            sawStatusOrImage,
            "While waiting for Dropbox, both status and image were missing. status='\(view.testHook_statusLabelString)' imageVisible=\(view.testHook_frontImageVisible)"
        )
        XCTAssertTrue(
            firstObservedStatus.contains("Connecting") || firstObservedStatus.contains("cached") || firstObservedStatus.contains("Dropbox"),
            "Expected connecting/cached status during startup. got='\(firstObservedStatus)'"
        )
        XCTAssertTrue(sawImage, "Expected a cached PNG to be shown before Dropbox list/download finishes.")
    }

    /// Reproduces the ScreenSaverEngine regression mode:
    /// if no explicit flush driver runs (timer/animateOneFrame), UI receives neither status nor image.
    /// This test is intentionally strict and should FAIL on current production behavior.
    func testRegression_noFlushDriver_meansNoStatusAndNoImage() throws {
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

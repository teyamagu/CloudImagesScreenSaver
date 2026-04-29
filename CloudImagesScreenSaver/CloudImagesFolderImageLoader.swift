import Foundation
import OSLog

public protocol CloudImagesFolderImageLoaderDelegate: AnyObject {
    func folderImageLoader(_ loader: CloudImagesFolderImageLoader, statusDidChange message: String)
    func folderImageLoader(_ loader: CloudImagesFolderImageLoader, didCacheImageAt url: URL)
    func folderImageLoader(_ loader: CloudImagesFolderImageLoader, didFailWithError error: Error)
    /// `listedImagePathCount` is the count from `listImagePaths`. If `readyURLs` is still empty after cache hits
    /// or download failures, use `lastDownloadError` for messaging.
    func folderImageLoaderDidCompletePipeline(
        _ loader: CloudImagesFolderImageLoader,
        listedImagePathCount: Int,
        lastDownloadError: Error?
    )
}

/// In `legacyScreenSaver`, the main run loop often does not advance Swift's `MainActor` enough.
/// Delegating via `await MainActor.run { … }` can block waiting on `MainActor.run`, leaving the process "not responding".
/// The background `Task` therefore only enqueues work; `ScreenSaverView.animateOneFrame` calls
/// `flushPendingEventsToDelegate()` to deliver delegate callbacks on the same thread the engine uses.
enum CloudImagesFolderLoaderUIEvent {
    case status(String)
    case cached(URL)
    case failed(NSError)
    case pipelineCompleted(listedImagePathCount: Int, lastDownloadError: NSError?)
}

/// Lists image paths via the Dropbox API and downloads them into the cache.
public final class CloudImagesFolderImageLoader {
    private static let log = Logger(subsystem: "com.cloudimagesscreensaver.app", category: "FolderImageLoader")
    public weak var delegate: CloudImagesFolderImageLoaderDelegate?

    private var task: Task<Void, Never>?
    private let pipeline: DropboxImagePipeline
    private let resolveAccessToken: @Sendable () async throws -> String
    private let pathsShuffle: @Sendable ([String]) -> [String]

    private let eventLock = NSLock()
    private var pendingEvents: [CloudImagesFolderLoaderUIEvent] = []
    private let autoFlushLock = NSLock()
    private var autoFlushScheduled = false

    public init(
        pipeline: DropboxImagePipeline = LiveDropboxImagePipeline(),
        resolveAccessToken: @escaping @Sendable () async throws -> String = {
            throw DropboxOAuthError.notConfigured
        },
        pathsShuffle: @escaping @Sendable ([String]) -> [String] = { $0.shuffled() }
    ) {
        self.pipeline = pipeline
        self.resolveAccessToken = resolveAccessToken
        self.pathsShuffle = pathsShuffle
    }

    /// Called from the screen saver's `animateOneFrame` (and from tests). Drains queued UI events to the delegate.
    public func flushPendingEventsToDelegate() {
        let batch: [CloudImagesFolderLoaderUIEvent] = {
            eventLock.lock()
            let copy = pendingEvents
            pendingEvents.removeAll(keepingCapacity: true)
            eventLock.unlock()
            return copy
        }()
        guard let delegate else { return }
        for event in batch {
            switch event {
            case let .status(message):
                delegate.folderImageLoader(self, statusDidChange: message)
            case let .cached(url):
                delegate.folderImageLoader(self, didCacheImageAt: url)
            case let .failed(nsError):
                delegate.folderImageLoader(self, didFailWithError: nsError)
            case let .pipelineCompleted(listedImagePathCount, lastDownloadError):
                delegate.folderImageLoaderDidCompletePipeline(
                    self,
                    listedImagePathCount: listedImagePathCount,
                    lastDownloadError: lastDownloadError
                )
            }
        }
    }

    private func enqueue(_ event: CloudImagesFolderLoaderUIEvent) {
        eventLock.lock()
        pendingEvents.append(event)
        let pendingCount = pendingEvents.count
        eventLock.unlock()
        scheduleAutoFlushIfNeeded()
    }

    /// Fallback delivery path for runtimes where `animateOneFrame`/timer callbacks are sparse.
    /// Keeps the queue-based model but asks the main run loop to drain soon.
    private func scheduleAutoFlushIfNeeded() {
        autoFlushLock.lock()
        if autoFlushScheduled {
            autoFlushLock.unlock()
            return
        }
        autoFlushScheduled = true
        autoFlushLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            autoFlushLock.lock()
            autoFlushScheduled = false
            autoFlushLock.unlock()
            flushPendingEventsToDelegate()
        }
    }

    /// Uses `resolveAccessToken` from the initializer (OAuth or other injection).
    /// Disk cache under `DropboxClient.cacheDirectory()` is enumerated on the caller thread **before** the
    /// background `Task` runs. The host should drain the queue with `flushPendingEventsToDelegate()` on a
    /// cadence that does not rely solely on `animateOneFrame` (e.g. a short `Timer` on `RunLoop.main`).
    public func start(folderPath: String) {
        cancel()

        let quickURLs: [URL] = (try? DropboxClient.enumeratedCachedImageFileURLs()) ?? []
        let pathStrings = quickURLs.map(\.path)
        let shuffledPaths = pathsShuffle(pathStrings)
        let byPath = Dictionary(uniqueKeysWithValues: zip(pathStrings, quickURLs))
        let orderedQuick = shuffledPaths.compactMap { byPath[$0] }
        let hadPrefetchedCache = !orderedQuick.isEmpty

        if hadPrefetchedCache {
            enqueue(
                .status("Showing cached images while connecting to Dropbox…")
            )
            for url in orderedQuick {
                enqueue(.cached(url))
            }
        }

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let accessToken = try await resolveAccessToken()
                await runListAndDownloads(
                    accessToken: accessToken,
                    folderPath: folderPath,
                    hadPrefetchedCache: hadPrefetchedCache
                )
            } catch {
                if Task.isCancelled { return }
                if hadPrefetchedCache {
                    enqueue(
                        .status("Could not connect to Dropbox: \(error.localizedDescription)")
                    )
                    enqueue(
                        .pipelineCompleted(
                            listedImagePathCount: 0,
                            lastDownloadError: error as NSError
                        )
                    )
                } else {
                    enqueue(.failed(error as NSError))
                }
            }
        }
    }

    /// XCTest: fixed bearer token without going through `resolveAccessToken`. Does not prefetch from disk cache.
    public func start(accessToken: String, folderPath: String) {
        cancel()
        task = Task { [weak self] in
            guard let self else { return }
            await runListAndDownloads(
                accessToken: accessToken,
                folderPath: folderPath,
                hadPrefetchedCache: false
            )
        }
    }

    private func runListAndDownloads(accessToken: String, folderPath: String, hadPrefetchedCache: Bool) async {
        do {
            let paths = try await pipeline.listImagePaths(accessToken: accessToken, folderPath: folderPath)
            if Task.isCancelled { return }
            enqueue(
                .status(paths.isEmpty ? "No images found" : "Found \(paths.count) item(s). Fetching in order…")
            )
            var lastDownloadError: NSError?
            let orderedPaths = pathsShuffle(paths)
            let total = orderedPaths.count
            for (index, path) in orderedPaths.enumerated() {
                if Task.isCancelled { return }
                let n = index + 1
                let fileName = (path as NSString).lastPathComponent
                let namePart = fileName.isEmpty ? path : fileName
                let progressPrefix = "\(n) of \(total)"
                enqueue(.status("\(progressPrefix) \(namePart) — processing…"))
                do {
                    let url = try pipeline.localCacheURL(forDropboxPath: path)
                    if FileManager.default.fileExists(atPath: url.path) {
                        enqueue(
                            .status("\(progressPrefix) \(namePart) — loading from cache")
                        )
                        enqueue(.cached(url))
                        continue
                    }
                    enqueue(
                        .status("\(progressPrefix) \(namePart) — downloading…")
                    )
                    let saved = try await pipeline.downloadToCache(accessToken: accessToken, dropboxPath: path)
                    if Task.isCancelled { return }
                    enqueue(.cached(saved))
                } catch {
                    if Task.isCancelled { return }
                    lastDownloadError = error as NSError
                    enqueue(.failed(error as NSError))
                }
            }
            let pipelineLastError = lastDownloadError
            if !Task.isCancelled {
                enqueue(
                    .pipelineCompleted(
                        listedImagePathCount: paths.count,
                        lastDownloadError: pipelineLastError
                    )
                )
            }
        } catch {
            if Task.isCancelled { return }
            if hadPrefetchedCache {
                enqueue(
                    .status("Could not refresh file list: \(error.localizedDescription)")
                )
                enqueue(
                    .pipelineCompleted(
                        listedImagePathCount: 0,
                        lastDownloadError: error as NSError
                    )
                )
            } else {
                enqueue(.failed(error as NSError))
            }
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        eventLock.lock()
        pendingEvents.removeAll(keepingCapacity: false)
        eventLock.unlock()
    }
}

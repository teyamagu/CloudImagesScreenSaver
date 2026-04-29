import Foundation

public protocol CloudImagesFolderImageLoaderDelegate: AnyObject {
    func folderImageLoader(_ loader: CloudImagesFolderImageLoader, didEmit outcome: LoaderOutcome)
}

public enum LoaderStatusKind: Sendable {
    case connecting
    case progress
    case info
}

public struct LoaderStatus: Sendable {
    public let kind: LoaderStatusKind
    public let message: String

    public init(kind: LoaderStatusKind, message: String) {
        self.kind = kind
        self.message = message
    }
}

public enum LoaderOutcome: Sendable {
    case status(LoaderStatus)
    case cached(URL)
    case failed(NSError)
    case pipelineCompleted(listedImagePathCount: Int, lastDownloadError: NSError?)
}

enum CloudImagesFolderLoaderUIEvent {
    case status(LoaderStatus)
    case cached(URL)
    case failed(NSError)
    case pipelineCompleted(listedImagePathCount: Int, lastDownloadError: NSError?)
}

private struct QueuedLoaderEvent {
    let sessionID: Int
    let event: CloudImagesFolderLoaderUIEvent
}

private struct PathProcessingContext {
    let index: Int
    let total: Int
    let sessionID: Int
}

// swiftlint:disable type_body_length
/// Lists image paths via the Dropbox API and downloads them into the cache.
public final class CloudImagesFolderImageLoader {
    /// Maximum cached images to enqueue immediately for responsiveness.
    /// Smaller values reduce startup latency (directory enumeration + NSImage decoding).
    private let quickCachePrefetchLimit = 3
    public weak var delegate: CloudImagesFolderImageLoaderDelegate?

    private var task: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?
    private let pipeline: DropboxImagePipeline
    private let resolveAccessToken: @Sendable () async throws -> String
    private let pathsShuffle: @Sendable ([String]) -> [String]
    private let deliveryState = DeliveryState()
    private let sessionLock = NSLock()
    private var currentSessionID = 0
    private var deliveryPumpID = 0
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

    private func nextSessionID() -> Int {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        currentSessionID += 1
        return currentSessionID
    }

    private func activeSessionID() -> Int {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return currentSessionID
    }

    private func isCurrentSession(_ sessionID: Int) -> Bool {
        activeSessionID() == sessionID
    }

    private func enqueue(_ event: CloudImagesFolderLoaderUIEvent, sessionID: Int) {
        guard isCurrentSession(sessionID) else { return }
        let shouldStart = deliveryState.enqueueAndMarkPumpIfNeeded(
            QueuedLoaderEvent(sessionID: sessionID, event: event)
        )
        if shouldStart {
            scheduleDeliveryPump()
        }
    }

    private func scheduleDeliveryPump() {
        let pumpID: Int = {
            sessionLock.lock()
            defer { sessionLock.unlock() }
            if deliveryTask != nil { return -1 }
            deliveryPumpID += 1
            let id = deliveryPumpID
            deliveryTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    let batch = deliveryState.takeBatch()
                    if batch.isEmpty {
                        let shouldContinue = deliveryState.keepPumpingIfPending()
                        if !shouldContinue { break }
                        continue
                    }
                    await MainActor.run {
                        for queued in batch {
                            if Task.isCancelled { break }
                            if !self.isCurrentSession(queued.sessionID) { continue }
                            self.deliver(event: queued.event)
                        }
                    }
                    let shouldContinue = deliveryState.keepPumpingIfPending()
                    if !shouldContinue { break }
                }
                finishDeliveryPumpIfCurrent(id)
            }
            return id
        }()
        if pumpID == -1 { return }
    }

    private func finishDeliveryPumpIfCurrent(_ pumpID: Int) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard deliveryPumpID == pumpID else { return }
        deliveryTask = nil
    }

    private func clearDeliveryStateSynchronously() {
        deliveryState.clear()
    }

    private func cancelDeliveryPump() {
        let activeTask: Task<Void, Never>? = {
            sessionLock.lock()
            defer { sessionLock.unlock() }
            deliveryPumpID += 1
            let task = deliveryTask
            deliveryTask = nil
            return task
        }()
        activeTask?.cancel()
    }

    private func deliver(event: CloudImagesFolderLoaderUIEvent) {
        guard let delegate else { return }
        let outcome: LoaderOutcome = switch event {
        case let .status(message): .status(message)
        case let .cached(url): .cached(url)
        case let .failed(error): .failed(error)
        case let .pipelineCompleted(count, error): .pipelineCompleted(listedImagePathCount: count, lastDownloadError: error)
        }
        delegate.folderImageLoader(self, didEmit: outcome)
    }

    /// Uses `resolveAccessToken` from the initializer (OAuth or other injection).
    /// Disk cache under `DropboxClient.cacheDirectory()` is enumerated on the caller thread before the background task runs.
    public func start(folderPath: String) {
        cancel()
        let sessionID = nextSessionID()

        let quickURLs: [URL] = (try? DropboxClient.enumeratedCachedImageFileURLs(limit: quickCachePrefetchLimit)) ?? []
        let pathStrings = quickURLs.map(\.path)
        let shuffledPaths = pathsShuffle(pathStrings)
        let byPath = Dictionary(uniqueKeysWithValues: zip(pathStrings, quickURLs))
        let orderedQuick = shuffledPaths.compactMap { byPath[$0] }
        let hadPrefetchedCache = !orderedQuick.isEmpty

        if hadPrefetchedCache {
            enqueue(
                .status(.init(kind: .connecting, message: "Showing cached images while connecting to Dropbox…")),
                sessionID: sessionID
            )
            for url in orderedQuick {
                enqueue(.cached(url), sessionID: sessionID)
            }
        }

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let accessToken = try await resolveAccessToken()
                await runListAndDownloads(
                    accessToken: accessToken,
                    folderPath: folderPath,
                    hadPrefetchedCache: hadPrefetchedCache,
                    sessionID: sessionID
                )
            } catch {
                if Task.isCancelled || !isCurrentSession(sessionID) { return }
                emitPrefetchAwareFailure(
                    hadPrefetchedCache: hadPrefetchedCache,
                    contextMessage: "Could not connect to Dropbox",
                    listedImagePathCount: 0,
                    error: error,
                    sessionID: sessionID
                )
            }
        }
    }

    /// XCTest: fixed bearer token without going through `resolveAccessToken`. Does not prefetch from disk cache.
    public func start(accessToken: String, folderPath: String) {
        cancel()
        let sessionID = nextSessionID()
        task = Task { [weak self] in
            guard let self else { return }
            await runListAndDownloads(
                accessToken: accessToken,
                folderPath: folderPath,
                hadPrefetchedCache: false,
                sessionID: sessionID
            )
        }
    }

    private func runListAndDownloads(
        accessToken: String,
        folderPath: String,
        hadPrefetchedCache: Bool,
        sessionID: Int
    ) async {
        do {
            let paths = try await pipeline.listImagePaths(accessToken: accessToken, folderPath: folderPath)
            if Task.isCancelled || !isCurrentSession(sessionID) { return }
            emitListStartStatus(pathsCount: paths.count, sessionID: sessionID)
            var lastDownloadError: NSError?
            let orderedPaths = pathsShuffle(paths)
            let total = orderedPaths.count
            for (index, path) in orderedPaths.enumerated() {
                if Task.isCancelled || !isCurrentSession(sessionID) { return }
                lastDownloadError = await processOnePath(
                    accessToken: accessToken,
                    path: path,
                    context: .init(index: index, total: total, sessionID: sessionID),
                    previousError: lastDownloadError
                )
            }
            let pipelineLastError = lastDownloadError
            if !Task.isCancelled, isCurrentSession(sessionID) {
                enqueue(
                    .pipelineCompleted(
                        listedImagePathCount: paths.count,
                        lastDownloadError: pipelineLastError
                    ),
                    sessionID: sessionID
                )
            }
        } catch {
            if Task.isCancelled || !isCurrentSession(sessionID) { return }
            emitPrefetchAwareFailure(
                hadPrefetchedCache: hadPrefetchedCache,
                contextMessage: "Could not refresh file list",
                listedImagePathCount: 0,
                error: error,
                sessionID: sessionID
            )
        }
    }

    private func emitPrefetchAwareFailure(
        hadPrefetchedCache: Bool,
        contextMessage: String,
        listedImagePathCount: Int,
        error: Error,
        sessionID: Int
    ) {
        let nsError = error as NSError
        if hadPrefetchedCache {
            enqueue(.status(.init(kind: .info, message: "\(contextMessage): \(error.localizedDescription)")), sessionID: sessionID)
            enqueue(.failed(nsError), sessionID: sessionID)
            enqueue(.pipelineCompleted(listedImagePathCount: listedImagePathCount, lastDownloadError: nsError), sessionID: sessionID)
            return
        }
        enqueue(.failed(nsError), sessionID: sessionID)
    }

    private func emitListStartStatus(pathsCount: Int, sessionID: Int) {
        enqueue(
            .status(.init(
                kind: pathsCount == 0 ? .info : .progress,
                message: pathsCount == 0 ? "No images found" : "Found \(pathsCount) item(s). Fetching in order…"
            )),
            sessionID: sessionID
        )
    }

    private func processOnePath(
        accessToken: String,
        path: String,
        context: PathProcessingContext,
        previousError: NSError?
    ) async -> NSError? {
        let n = context.index + 1
        let fileName = (path as NSString).lastPathComponent
        let namePart = fileName.isEmpty ? path : fileName
        let progressPrefix = "\(n) of \(context.total)"
        enqueue(.status(.init(kind: .progress, message: "\(progressPrefix) \(namePart) — processing…")), sessionID: context.sessionID)
        do {
            let url = try pipeline.localCacheURL(forDropboxPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                enqueue(.status(.init(kind: .progress, message: "\(progressPrefix) \(namePart) — loading from cache")), sessionID: context.sessionID)
                enqueue(.cached(url), sessionID: context.sessionID)
                return previousError
            }
            enqueue(.status(.init(kind: .progress, message: "\(progressPrefix) \(namePart) — downloading…")), sessionID: context.sessionID)
            let saved = try await pipeline.downloadToCache(accessToken: accessToken, dropboxPath: path)
            if Task.isCancelled || !isCurrentSession(context.sessionID) { return previousError }
            enqueue(.cached(saved), sessionID: context.sessionID)
            return previousError
        } catch {
            if Task.isCancelled || !isCurrentSession(context.sessionID) { return previousError }
            let ns = error as NSError
            enqueue(.failed(ns), sessionID: context.sessionID)
            return ns
        }
    }
}

// swiftlint:enable type_body_length

public extension CloudImagesFolderImageLoader {
    func cancel() {
        _ = nextSessionID()
        task?.cancel()
        task = nil
        cancelDeliveryPump()
        clearDeliveryStateSynchronously()
    }
}

private final class DeliveryState {
    private let lock = NSLock()
    private var pendingEvents: [QueuedLoaderEvent] = []
    private var pumping = false

    func enqueueAndMarkPumpIfNeeded(_ event: QueuedLoaderEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pendingEvents.append(event)
        if pumping { return false }
        pumping = true
        return true
    }

    func takeBatch() -> [QueuedLoaderEvent] {
        lock.lock()
        defer { lock.unlock() }
        let batch = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        return batch
    }

    func keepPumpingIfPending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if pendingEvents.isEmpty {
            pumping = false
            return false
        }
        return true
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        pendingEvents.removeAll(keepingCapacity: false)
        pumping = false
    }
}

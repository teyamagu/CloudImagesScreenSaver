import CryptoKit
import Foundation

// MARK: - Errors

public enum DropboxClientError: LocalizedError {
    case invalidHTTPResponse
    case apiRequestFailed(statusCode: Int, responseBody: String)
    case missingDropboxApiResultHeader

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            "Invalid HTTP response from Dropbox."
        case let .apiRequestFailed(statusCode, body):
            "Dropbox API error (\(statusCode)): \(body)"
        case .missingDropboxApiResultHeader:
            "Missing Dropbox-Api-Result header on download response."
        }
    }
}

// MARK: - Client

// swiftlint:disable type_body_length
/// Minimal Dropbox HTTP client (`files/list_folder` / `files/download`).
public enum DropboxClient {
    private static let listURL = URL(string: "https://api.dropboxapi.com/2/files/list_folder")!
    private static let listContinueURL = URL(string: "https://api.dropboxapi.com/2/files/list_folder/continue")!
    private static let downloadURL = URL(string: "https://content.dropboxapi.com/2/files/download")!
    private enum RetryPolicy {
        static let maxAttempts = 4
        static let baseDelayMs = 250
        static let stepDelayMs = 350
    }

    /// Avoid the shared session (mixes traffic). Use explicit timeouts and connectivity behavior for Dropbox only.
    private static let urlSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 180
        c.timeoutIntervalForResource = 600
        c.waitsForConnectivity = true
        c.httpMaximumConnectionsPerHost = 8
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    /// Lowercase extensions to list and display (compared with `pathExtension`).
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png"]

    /// Extensions considered "displayable" for **existing disk cache files**.
    /// `localCacheURL(forDropboxPath:)` uses `img` as a fallback when Dropbox entries have no extension.
    private static let cachedImageFileExtensions: Set<String> = ["jpg", "jpeg", "png", "img"]

    /// Returns up to `limit` cached image file URLs from `cacheDirectory()`.
    /// Intentionally avoids sorting for startup speed.
    public static func enumeratedCachedImageFileURLs(limit: Int) throws -> [URL] {
        guard limit > 0 else { return [] }
        let dir = try cacheDirectory()
        let fm = FileManager.default
        // Use an enumerator so we can stop early when we have enough files.
        // `contentsOfDirectory` loads all entries at once, which can be slow with many cached files.
        let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        )

        var result: [URL] = []
        result.reserveCapacity(limit)

        while let next = enumerator?.nextObject() as? URL {
            let ext = next.pathExtension.lowercased()
            guard cachedImageFileExtensions.contains(ext) else { continue }
            do {
                let values = try next.resourceValues(forKeys: [URLResourceKey.isDirectoryKey])
                if values.isDirectory == true { continue }
            } catch {
                continue
            }
            result.append(next)
            if result.count >= limit { break }
        }

        return result
    }

    struct ListEntry: Decodable {
        let tag: String
        let name: String
        let pathLower: String

        enum CodingKeys: String, CodingKey {
            case tag = ".tag"
            case name
            case pathLower = "path_lower"
        }
    }

    private struct ListFolderResponse: Decodable {
        let entries: [ListEntry]
        let hasMore: Bool
        let cursor: String?

        enum CodingKeys: String, CodingKey {
            case entries
            case hasMore = "has_more"
            case cursor
        }
    }

    private struct ListFolderContinueBody: Encodable {
        let cursor: String
    }

    private struct ListFolderBody: Encodable {
        let path: String
        let recursive: Bool
        let includeMediaInfo: Bool

        enum CodingKeys: String, CodingKey {
            case path
            case recursive
            case includeMediaInfo = "include_media_info"
        }
    }

    private struct FileMetadata: Decodable {
        let rev: String?
    }

    /// Cache root, resolved from `FileManager.default.urls(for: .applicationSupportDirectory, ...)`.
    ///
    /// - **Typical macOS app / SwiftPM run**: `~/Library/Application Support/CloudImagesScreenSaver/cache`
    /// - **Legacy `.saver` (`ScreenSaverEngine.legacyScreenSaver`)**: may resolve under the app container, e.g.
    ///   `~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Application Support/CloudImagesScreenSaver/cache`
    public static func cacheDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("CloudImagesScreenSaver", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Regular files under `cacheDirectory()` whose extension is one of `imageExtensions` (e.g. `.jpg`, `.png`).
    /// Sorted by path for stable ordering. Used to show cached images before Dropbox responds.
    public static func enumeratedCachedImageFileURLs() throws -> [URL] {
        let dir = try cacheDirectory()
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: dir.path)
        return names.compactMap { name -> URL? in
            let ext = (name as NSString).pathExtension.lowercased()
            guard cachedImageFileExtensions.contains(ext) else { return nil }
            let url = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
            return url
        }.sorted { $0.path < $1.path }
    }

    public static func cacheKey(forDropboxPath path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func localCacheURL(forDropboxPath path: String) throws -> URL {
        let ext = (path as NSString).pathExtension.lowercased()
        let safeExt = ext.isEmpty ? "img" : ext
        let key = cacheKey(forDropboxPath: path)
        return try cacheDirectory().appendingPathComponent("\(key).\(safeExt)")
    }

    /// `path` is an absolute Dropbox path (e.g. `/Photos/vacation`). Root is the empty string.
    public static func listImagePaths(accessToken: String, folderPath: String) async throws -> [String] {
        let normalized = normalizeFolderPath(folderPath)
        var all: [String] = []
        var cursor: String?

        repeat {
            let (entries, nextCursor, hasMore): ([ListEntry], String?, Bool)
            if let c = cursor {
                (entries, nextCursor, hasMore) = try await listFolderContinue(accessToken: accessToken, cursor: c)
            } else {
                (entries, nextCursor, hasMore) = try await listFolderFirst(
                    accessToken: accessToken,
                    path: normalized
                )
            }
            for e in entries where e.tag == "file" {
                let ext = (e.name as NSString).pathExtension.lowercased()
                if imageExtensions.contains(ext) {
                    all.append(e.pathLower)
                }
            }
            cursor = hasMore ? nextCursor : nil
        } while cursor != nil

        return all
    }

    /// Used by tests and `listImagePaths`.
    static func normalizeFolderPath(_ raw: String) -> String {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty || p == "/" { return "" }
        if !p.hasPrefix("/") { p = "/" + p }
        if p.count > 1, p.hasSuffix("/") {
            p = String(p.dropLast())
        }
        return p
    }

    private static func listFolderFirst(
        accessToken: String,
        path: String
    ) async throws -> ([ListEntry], String?, Bool) {
        let body = ListFolderBody(path: path, recursive: true, includeMediaInfo: false)
        var req = URLRequest(url: listURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await urlSession.data(for: req)
        try throwIfNeeded(data: data, response: resp)
        let decoded = try JSONDecoder().decode(ListFolderResponse.self, from: data)
        return (decoded.entries, decoded.cursor, decoded.hasMore)
    }

    private static func listFolderContinue(
        accessToken: String,
        cursor: String
    ) async throws -> ([ListEntry], String?, Bool) {
        let body = ListFolderContinueBody(cursor: cursor)
        var req = URLRequest(url: listContinueURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await urlSession.data(for: req)
        try throwIfNeeded(data: data, response: resp)
        let decoded = try JSONDecoder().decode(ListFolderResponse.self, from: data)
        return (decoded.entries, decoded.cursor, decoded.hasMore)
    }

    /// For Dropbox `Dropbox-API-Arg`: escape DEL (0x7F) and non-ASCII as `\uXXXX` for header-safe JSON.
    /// https://www.dropbox.com/developers/reference/json-encoding
    static func httpHeaderSafeDropboxAPIArgJSON(path: String) throws -> String {
        let payload: [String: String] = ["path": path]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw DropboxClientError.invalidHTTPResponse
        }
        var out = ""
        out.reserveCapacity(json.utf8.count * 2)
        for scalar in json.unicodeScalars {
            let v = scalar.value
            if v == 0x7F {
                out += "\\u007f"
            } else if scalar.isASCII {
                out.unicodeScalars.append(scalar)
            } else if v > 0xFFFF {
                let b = v - 0x10000
                let hi = UInt32(0xD800 | (b >> 10))
                let lo = UInt32(0xDC00 | (b & 0x3FF))
                out += String(format: "\\u%04x\\u%04x", hi, lo)
            } else {
                out += String(format: "\\u%04x", v)
            }
        }
        return out
    }

    /// Download a file into the cache path. Overwrites if the file already exists.
    public static func downloadToCache(accessToken: String, dropboxPath: String) async throws -> URL {
        let dest = try localCacheURL(forDropboxPath: dropboxPath)
        let argString = try httpHeaderSafeDropboxAPIArgJSON(path: dropboxPath)

        var lastError: Error?
        for attempt in 0 ..< RetryPolicy.maxAttempts {
            do {
                return try await downloadToCacheSingleAttempt(
                    accessToken: accessToken,
                    argString: argString,
                    dest: dest
                )
            } catch {
                lastError = error
                let maxRetryIndex = RetryPolicy.maxAttempts - 1
                if attempt < maxRetryIndex, isRetriableURLError(error) {
                    let delayMs = UInt64(RetryPolicy.baseDelayMs + attempt * RetryPolicy.stepDelayMs)
                    try await Task.sleep(nanoseconds: delayMs * 1_000_000)
                    continue
                }
                throw error
            }
        }
        throw lastError ?? DropboxClientError.invalidHTTPResponse
    }

    /// Used by tests and `downloadToCache` retry logic.
    static func isRetriableURLError(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorNetworkConnectionLost,
             NSURLErrorTimedOut,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorNotConnectedToInternet:
            return true
        default:
            return false
        }
    }

    /// Stream to disk with `URLSession.download`; can be more resilient than `data(for:)` on flaky links.
    private static func downloadToCacheSingleAttempt(
        accessToken: String,
        argString: String,
        dest: URL
    ) async throws -> URL {
        var req = URLRequest(url: downloadURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(argString, forHTTPHeaderField: "Dropbox-API-Arg")
        req.httpBody = nil

        let (tempURL, resp) = try await urlSession.download(for: req)
        var movedToDestination = false
        defer {
            if !movedToDestination {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        guard let http = resp as? HTTPURLResponse else {
            throw DropboxClientError.invalidHTTPResponse
        }
        if !(200 ... 299).contains(http.statusCode) {
            let errBody = (try? Data(contentsOf: tempURL)) ?? Data()
            try throwIfNeeded(data: errBody, response: resp)
            throw DropboxClientError.invalidHTTPResponse
        }

        guard let resultHeader = http.value(forHTTPHeaderField: "Dropbox-Api-Result") ??
            http.value(forHTTPHeaderField: "dropbox-api-result")
        else {
            throw DropboxClientError.missingDropboxApiResultHeader
        }

        let metaData = Data(resultHeader.utf8)
        _ = try JSONDecoder().decode(FileMetadata.self, from: metaData)

        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tempURL, to: dest)
        movedToDestination = true
        return dest
    }

    private static func throwIfNeeded(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw DropboxClientError.invalidHTTPResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DropboxClientError.apiRequestFailed(statusCode: http.statusCode, responseBody: body)
        }
    }
}

// swiftlint:enable type_body_length

// MARK: - Pipeline (dependency injection for tests)

/// Abstraction for Dropbox work invoked from `CloudImagesFolderImageLoader`.
public protocol DropboxImagePipeline: Sendable {
    func listImagePaths(accessToken: String, folderPath: String) async throws -> [String]
    func localCacheURL(forDropboxPath path: String) throws -> URL
    func downloadToCache(accessToken: String, dropboxPath: String) async throws -> URL
}

/// Production `DropboxClient` pipeline implementation.
public struct LiveDropboxImagePipeline: DropboxImagePipeline {
    public init() {}

    public func listImagePaths(accessToken: String, folderPath: String) async throws -> [String] {
        try await DropboxClient.listImagePaths(accessToken: accessToken, folderPath: folderPath)
    }

    public func localCacheURL(forDropboxPath path: String) throws -> URL {
        try DropboxClient.localCacheURL(forDropboxPath: path)
    }

    public func downloadToCache(accessToken: String, dropboxPath: String) async throws -> URL {
        try await DropboxClient.downloadToCache(accessToken: accessToken, dropboxPath: dropboxPath)
    }
}

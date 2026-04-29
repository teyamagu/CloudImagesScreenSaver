import DropboxAPI
import Foundation

/// Pass the token via the `DROPBOX_TOKEN` environment variable.
enum DropboxTestEnv {
    static var accessToken: String? {
        let a = ProcessInfo.processInfo.environment["DROPBOX_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (a?.isEmpty == false ? a : nil)
    }

    /// Dropbox folder (e.g. `/Photos`). Empty means list from root.
    static var folderPath: String {
        ProcessInfo.processInfo.environment["DROPBOX_TEST_FOLDER"] ?? ""
    }

    /// When `1`, skip the single-file download smoke test.
    static var skipDownload: Bool {
        ProcessInfo.processInfo.environment["DROPBOX_TEST_SKIP_DOWNLOAD"] == "1"
    }
}

@main
enum DropboxAPITestMain {
    static func main() async {
        guard let token = DropboxTestEnv.accessToken else {
            fputs("Set DROPBOX_TOKEN in the environment to an access token.\n", stderr)
            exit(1)
        }

        let folder = DropboxTestEnv.folderPath
        fputs("Folder: \(folder.isEmpty ? "(root \"\")" : folder)\n", stderr)

        do {
            fputs("list_folder …\n", stderr)
            let paths = try await DropboxClient.listImagePaths(accessToken: token, folderPath: folder)
            print("list_folder OK: \(paths.count) image path(s)")
            for p in paths.prefix(10) {
                print("  \(p)")
            }
            if paths.count > 10 {
                print("  … \(paths.count - 10) more")
            }

            if DropboxTestEnv.skipDownload {
                print("Skipping download because DROPBOX_TEST_SKIP_DOWNLOAD=1")
                return
            }
            guard let first = paths.first else {
                print("Skipping download: zero images")
                return
            }
            fputs("download test: \(first)\n", stderr)
            let url = try await DropboxClient.downloadToCache(accessToken: token, dropboxPath: first)
            let size = try (FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
            print("download OK: \(url.path) (\(size) bytes)")
        } catch {
            fputs("Failed: \(error.localizedDescription)\n", stderr)
            if let e = error as NSError? {
                fputs("domain=\(e.domain) code=\(e.code)\n", stderr)
            }
            exit(1)
        }
    }
}

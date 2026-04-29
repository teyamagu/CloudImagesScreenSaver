import Foundation
import ScreenSaver
#if SWIFT_PACKAGE
    import DropboxAPI
#endif

/// Keys and defaults for `ScreenSaverDefaults`, shared by the options sheet and the view.
enum ScreenSaverSettings {
    enum Key {
        static let dropboxAppKey = "DropboxAppKey"
        static let dropboxRefreshToken = "DropboxRefreshToken"
        static let dropboxAccessTokenCache = "DropboxAccessTokenCache"
        static let dropboxAccessTokenExpiresAt = "DropboxAccessTokenExpiresAt"
        static let dropboxFolderPath = "DropboxFolderPath"
        static let slideIntervalSeconds = "SlideIntervalSeconds"
    }

    /// Initial folder field value in the Options sheet.
    static let defaultFolderPathForUI = "/Photos"
    static let slideIntervalBounds = 2 ... 120
    static let defaultSlideInterval = 8

    enum Policy {
        static let crossfadeDuration: TimeInterval = 1.0
    }

    static func screenSaverDefaults() -> ScreenSaverDefaults {
        let moduleName = Bundle(for: CloudImagesScreenSaverView.self).bundleIdentifier
            ?? Bundle.main.bundleIdentifier
            ?? "com.cloudimagesscreensaver.app"
        if let d = ScreenSaverDefaults(forModuleWithName: moduleName) {
            return d
        }
        if let fallback = ScreenSaverDefaults(forModuleWithName: Bundle.main.bundleIdentifier ?? "com.cloudimagesscreensaver.app") {
            return fallback
        }
        return ScreenSaverDefaults()
    }

    static func clampedSlideIntervalSeconds(_ value: Int) -> Int {
        min(max(value, slideIntervalBounds.lowerBound), slideIntervalBounds.upperBound)
    }

    static func clampedSlideIntervalSeconds(from string: String) -> Int {
        let parsed = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) ?? defaultSlideInterval
        return clampedSlideIntervalSeconds(parsed)
    }
}

protocol ScreenSaverSettingsStore {
    func string(forKey key: String) -> String?
    func integer(forKey key: String) -> Int
    func double(forKey key: String) -> Double
    mutating func set(_ value: Any?, forKey key: String)
    func synchronize()
}

struct ScreenSaverDefaultsStore: ScreenSaverSettingsStore {
    private let defaults: ScreenSaverDefaults

    init(defaults: ScreenSaverDefaults = ScreenSaverSettings.screenSaverDefaults()) {
        self.defaults = defaults
    }

    func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    func integer(forKey key: String) -> Int {
        defaults.integer(forKey: key)
    }

    func double(forKey key: String) -> Double {
        defaults.double(forKey: key)
    }

    mutating func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func synchronize() {
        defaults.synchronize()
    }
}

// MARK: - Dropbox API facade aliases

#if SWIFT_PACKAGE
    typealias AppDropboxOAuth = DropboxAPI.DropboxOAuth
    typealias AppDropboxOAuthError = DropboxAPI.DropboxOAuthError
    typealias AppDropboxOAuthTokens = DropboxAPI.DropboxOAuthTokens
    typealias AppCloudImagesFolderImageLoader = DropboxAPI.CloudImagesFolderImageLoader
    typealias AppCloudImagesFolderImageLoaderDelegate = DropboxAPI.CloudImagesFolderImageLoaderDelegate
    typealias AppLoaderOutcome = DropboxAPI.LoaderOutcome
#else
    typealias AppDropboxOAuth = DropboxOAuth
    typealias AppDropboxOAuthError = DropboxOAuthError
    typealias AppDropboxOAuthTokens = DropboxOAuthTokens
    typealias AppCloudImagesFolderImageLoader = CloudImagesFolderImageLoader
    typealias AppCloudImagesFolderImageLoaderDelegate = CloudImagesFolderImageLoaderDelegate
    typealias AppLoaderOutcome = LoaderOutcome
#endif

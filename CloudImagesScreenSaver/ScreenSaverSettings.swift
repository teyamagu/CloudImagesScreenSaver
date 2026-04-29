import Foundation
import ScreenSaver

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

    static func screenSaverDefaults() -> ScreenSaverDefaults {
        let moduleName = Bundle(for: CloudImagesScreenSaverView.self).bundleIdentifier
            ?? Bundle.main.bundleIdentifier
            ?? "com.cloudimagesscreensaver.app"
        if let d = ScreenSaverDefaults(forModuleWithName: moduleName) {
            return d
        }
        return ScreenSaverDefaults(forModuleWithName: Bundle.main.bundleIdentifier ?? "com.cloudimagesscreensaver.app")!
    }

    static func clampedSlideIntervalSeconds(_ value: Int) -> Int {
        min(max(value, slideIntervalBounds.lowerBound), slideIntervalBounds.upperBound)
    }

    static func clampedSlideIntervalSeconds(from string: String) -> Int {
        let parsed = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) ?? defaultSlideInterval
        return clampedSlideIntervalSeconds(parsed)
    }
}

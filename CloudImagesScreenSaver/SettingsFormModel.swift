import Foundation

struct SettingsFormModel {
    let appKeyInput: String
    let folderPathInput: String
    let intervalInput: String

    var appKey: String {
        appKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var folderPath: String {
        folderPathInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var intervalSeconds: Int {
        ScreenSaverSettings.clampedSlideIntervalSeconds(from: intervalInput)
    }

    mutating func save(to store: inout some ScreenSaverSettingsStore) {
        // Empty app key keeps the existing stored key to avoid accidentally breaking
        // an already authenticated setup when a user edits only folder/interval.
        if !appKey.isEmpty {
            store.set(appKey, forKey: ScreenSaverSettings.Key.dropboxAppKey)
        }
        store.set(folderPath, forKey: ScreenSaverSettings.Key.dropboxFolderPath)
        store.set(intervalSeconds, forKey: ScreenSaverSettings.Key.slideIntervalSeconds)
        store.synchronize()
    }
}

import AppKit
import ScreenSaver

/// Configuration sheet window for the screen saver "Options" button.
/// - `configureSheet` may be read multiple times within one System Settings session. Replacing the `NSWindow` every time
///   can break the host's assumptions so the Options sheet no longer appears on later clicks.
/// - Holding on to an old configuration `NSWindow` after the parent panel is dismissed with Done can also prevent the
///   sheet from appearing next time (seen around macOS 26).
/// - The main System Settings window may remain the same `NSWindow` after Done, so host pointer equality alone cannot
///   detect a new session. Invalidate when `ScreenSaverView` leaves its window so the next Options flow rebuilds.
final class ConfigureSheetController: NSObject, NSWindowDelegate {
    static let shared = ConfigureSheetController()

    private(set) var window: NSWindow?

    /// `CloudImagesScreenSaverView.window` (host for the settings UI). Weak ref nil means the previous panel is gone.
    private weak var lastPresentationHostWindow: NSWindow?

    private let appKeyField = NSTextField(string: "")
    private let authCodeField = NSTextField(string: "")
    private let pathField = NSTextField(string: ScreenSaverSettings.defaultFolderPathForUI)
    private let intervalField = NSTextField(string: "\(ScreenSaverSettings.defaultSlideInterval)")

    private var openDropboxButton: NSButton?
    private var completeSignInButton: NSButton?
    private var pkceCodeVerifier: String?
    private var signInTask: Task<Void, Never>?
    private let authActionHandler = ConfigureSheetAuthActionHandler(
        oauthCoordinator: OAuthCoordinator(service: LiveDropboxOAuthService())
    )

    override private init() {
        super.init()
        prepareConfigureSheetForDisplay(hostWindow: nil)
    }

    private func defaults() -> ScreenSaverDefaults {
        ScreenSaverSettings.screenSaverDefaults()
    }

    /// Call after the preview view is removed from the settings panel window. Rebuild next time even if the host `NSWindow` is unchanged.
    func invalidateConfigureSheetPresentationContext() {
        lastPresentationHostWindow = nil
    }

    /// Called each time System Settings is about to show Options.
    /// - Parameter hostWindow: `ScreenSaverView.window`. Reuse the sheet window while the same instance is attached; rebuild after the panel is torn down.
    func prepareConfigureSheetForDisplay(hostWindow: NSWindow?) {
        if canReuseExistingConfigureWindow(hostWindow: hostWindow) {
            loadDefaults()
            if let host = hostWindow {
                lastPresentationHostWindow = host
            }
            return
        }

        tearDownCurrentWindowIfNeeded()
        buildWindow()
        loadDefaults()
        if let host = hostWindow {
            lastPresentationHostWindow = host
        }
    }

    /// Reuse the configuration window only when the sheet is already dismissed and we are still on the same settings panel.
    private func canReuseExistingConfigureWindow(hostWindow: NSWindow?) -> Bool {
        guard let w = window,
              w.sheetParent == nil,
              w.contentView != nil else { return false }

        if let host = hostWindow {
            guard let last = lastPresentationHostWindow else { return false }
            return last === host
        }
        // `ScreenSaverView.window` can still be nil when `configureSheet` is read; reuse if we had a host recently.
        return lastPresentationHostWindow != nil
    }

    private func tearDownCurrentWindowIfNeeded() {
        guard let w = window else { return }
        w.delegate = nil
        if let parent = w.sheetParent {
            parent.endSheet(w, returnCode: .abort)
        }
        appKeyField.removeFromSuperview()
        authCodeField.removeFromSuperview()
        pathField.removeFromSuperview()
        intervalField.removeFromSuperview()
        openDropboxButton?.removeFromSuperview()
        completeSignInButton?.removeFromSuperview()
        openDropboxButton = nil
        completeSignInButton = nil
        pkceCodeVerifier = nil
        signInTask?.cancel()
        signInTask = nil
        w.orderOut(nil)
        w.contentView = nil
        window = nil
        lastPresentationHostWindow = nil
    }

    private func buildWindow() {
        let built = ConfigureSheetViewFactory.makeWindow(
            .init(
                appKeyField: appKeyField,
                authCodeField: authCodeField,
                pathField: pathField,
                intervalField: intervalField,
                target: self,
                openAction: #selector(openDropboxSignIn),
                completeAction: #selector(completeOAuthSignIn),
                saveAction: #selector(saveAndClose),
                closeAction: #selector(closeOnly)
            )
        )
        openDropboxButton = built.openButton
        completeSignInButton = built.completeButton
        built.window.delegate = self
        window = built.window
    }

    private func loadDefaults() {
        let store = ScreenSaverDefaultsStore(defaults: defaults())
        appKeyField.stringValue = store.string(forKey: ScreenSaverSettings.Key.dropboxAppKey) ?? ""
        authCodeField.stringValue = ""
        pathField.stringValue = store.string(forKey: ScreenSaverSettings.Key.dropboxFolderPath)
            ?? ScreenSaverSettings.defaultFolderPathForUI
        let interval = store.integer(forKey: ScreenSaverSettings.Key.slideIntervalSeconds)
        intervalField.stringValue = interval > 0 ? "\(interval)" : "\(ScreenSaverSettings.defaultSlideInterval)"
        pkceCodeVerifier = nil
    }

    @objc private func openDropboxSignIn() {
        let appKey = appKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let started = try authActionHandler.startSignIn(appKey: appKey)
            pkceCodeVerifier = started.verifier
            NSWorkspace.shared.open(started.authorizeURL)
        } catch {
            presentAlert(title: "App key required", message: "Enter your Dropbox app key first.")
        }
    }

    @objc private func completeOAuthSignIn() {
        let appKey = appKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appKey.isEmpty else {
            presentAlert(title: "App key required", message: "Enter your Dropbox app key.")
            return
        }
        guard let verifier = pkceCodeVerifier, !verifier.isEmpty else {
            presentAlert(title: "Open Dropbox first", message: "Click “Open Dropbox…” to start sign-in, then paste the code.")
            return
        }
        let code = authCodeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            presentAlert(title: "Code required", message: "Paste the authorization code from Dropbox.")
            return
        }

        signInTask?.cancel()
        signInTask = Task { [weak self] in
            guard let self else { return }
            do {
                let tokens = try await authActionHandler.completeSignIn(
                    appKey: appKey,
                    code: code,
                    verifier: verifier
                )
                if Task.isCancelled { return }
                let refreshTrimmed = (tokens.refreshToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !refreshTrimmed.isEmpty else {
                    await MainActor.run {
                        if Task.isCancelled { return }
                        self.presentAlert(
                            title: "No refresh token",
                            message: "Dropbox did not return a refresh token. Ensure the app requests offline access and try signing in again.",
                            style: .warning
                        )
                    }
                    return
                }
                await MainActor.run {
                    if Task.isCancelled { return }
                    DropboxScreenSaverOAuth.saveSession(tokens: tokens, clientId: appKey, defaults: self.defaults())
                    self.pkceCodeVerifier = nil
                    self.authCodeField.stringValue = ""
                    self.presentAlert(title: "Signed in", message: "OAuth tokens saved. Click OK to keep folder and interval changes.")
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    if Task.isCancelled { return }
                    self.presentAlert(title: "Sign-in failed", message: error.localizedDescription, style: .warning)
                }
            }
        }
    }

    private func presentAlert(title: String, message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        if let w = window {
            alert.beginSheetModal(for: w, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    @objc private func saveAndClose() {
        var store = ScreenSaverDefaultsStore(defaults: defaults())
        var model = SettingsFormModel(
            appKeyInput: appKeyField.stringValue,
            folderPathInput: pathField.stringValue,
            intervalInput: intervalField.stringValue
        )
        model.save(to: &store)
        dismissConfigureSheet(returnCode: .OK)
    }

    @objc private func closeOnly() {
        signInTask?.cancel()
        signInTask = nil
        loadDefaults()
        dismissConfigureSheet(returnCode: .cancel)
    }

    /// System Settings shows this window as a sheet; `close()` alone is not enough—call `endSheet`.
    private func dismissConfigureSheet(returnCode: NSApplication.ModalResponse) {
        guard let win = window else { return }
        if let parent = win.sheetParent {
            parent.endSheet(win, returnCode: returnCode)
        }
        win.orderOut(nil)
        if NSApp.modalWindow === win {
            NSApp.stopModal()
        }
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        closeOnly()
        return false
    }
}

import AppKit
#if SWIFT_PACKAGE
    import DropboxAPI
#endif
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
        w.orderOut(nil)
        w.contentView = nil
        window = nil
        lastPresentationHostWindow = nil
    }

    private func buildWindow() {
        // Bottom: buttons → help → OAuth row → fields (stack upward; origin bottom-left).
        let contentW: CGFloat = 480
        let pad: CGFloat = 16
        let footerPad: CGFloat = 16
        let buttonH: CGFloat = 32
        let buttonGap: CGFloat = 12
        let helpGapAboveButtons: CGFloat = 8
        let formHelpGap: CGFloat = 8
        let okW: CGFloat = 84
        let cancelW: CGFloat = 96
        let fieldRowHeight: CGFloat = 22
        let rowSpacing: CGFloat = 12
        let rowAdvance = fieldRowHeight + rowSpacing
        let oauthBlock: CGFloat = 36

        let helpWidth = contentW - pad * 2
        let helpText =
            "Create a Dropbox app (App Console) with scopes files.metadata.read and files.content.read. "
                + "Enter your App key, click “Open Dropbox…”, approve access, copy the authorization code from Dropbox, "
                + "paste it here, then “Complete sign-in”. Folder path is on Dropbox (e.g. /Photos). "
                + "Only .jpg, .jpeg, and .png files are shown."

        let help = NSTextField(wrappingLabelWithString: helpText)
        help.font = NSFont.systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.preferredMaxLayoutWidth = helpWidth
        let helpMeasured = ceil(
            (helpText as NSString).boundingRect(
                with: NSSize(width: helpWidth, height: 10000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: help.font!]
            ).height
        )
        let helpH = max(helpMeasured + 5, 1)

        let buttonRowY = footerPad
        let helpBottomY = footerPad + buttonH + helpGapAboveButtons
        let helpTopY = helpBottomY + helpH

        // Four form rows + OAuth row between fields and help.
        let firstLabelY = helpTopY + formHelpGap + oauthBlock + 3 * rowAdvance + 2
        let contentH = firstLabelY + 20 + pad

        let root = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: contentH))
        help.frame = NSRect(x: pad, y: helpBottomY, width: helpWidth, height: helpH)

        var y = firstLabelY

        func addLabel(_ text: String, field: NSTextField, height: CGFloat = fieldRowHeight) {
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: pad, y: y, width: 120, height: 18)
            label.alignment = .right
            root.addSubview(label)

            field.frame = NSRect(x: pad + 128, y: y - 2, width: root.frame.width - pad * 2 - 128, height: height)
            field.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(field)
            y -= rowAdvance
        }

        appKeyField.placeholderString = "Dropbox app key (client_id)"
        authCodeField.placeholderString = "Paste authorization code after browser"
        pathField.placeholderString = "/Pictures/screensaver"
        intervalField.placeholderString = "sec"

        addLabel("App key:", field: appKeyField)
        addLabel("Auth code:", field: authCodeField)
        addLabel("Folder path:", field: pathField)
        addLabel("Interval (sec):", field: intervalField)

        let oauthY = helpTopY + formHelpGap + (oauthBlock - 28) / 2
        let open = NSButton(title: "Open Dropbox…", target: self, action: #selector(openDropboxSignIn))
        open.bezelStyle = .rounded
        open.frame = NSRect(x: pad + 128, y: oauthY, width: 150, height: 28)

        let complete = NSButton(title: "Complete sign-in", target: self, action: #selector(completeOAuthSignIn))
        complete.bezelStyle = .rounded
        complete.frame = NSRect(x: pad + 128 + 160, y: oauthY, width: 160, height: 28)

        openDropboxButton = open
        completeSignInButton = complete
        root.addSubview(open)
        root.addSubview(complete)

        root.addSubview(help)

        let win = NSWindow(
            contentRect: root.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.contentView = root
        win.title = "Cloud Images Screen Saver"
        win.isReleasedWhenClosed = false
        win.delegate = self

        let ok = NSButton(title: "OK", target: self, action: #selector(saveAndClose))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        ok.frame = NSRect(x: contentW - pad - okW, y: buttonRowY, width: okW, height: buttonH)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeOnly))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: ok.frame.minX - buttonGap - cancelW, y: buttonRowY, width: cancelW, height: buttonH)

        root.addSubview(cancel)
        root.addSubview(ok)

        window = win
    }

    private func loadDefaults() {
        let d = defaults()
        appKeyField.stringValue = d.string(forKey: ScreenSaverSettings.Key.dropboxAppKey) ?? ""
        authCodeField.stringValue = ""
        pathField.stringValue = d.string(forKey: ScreenSaverSettings.Key.dropboxFolderPath)
            ?? ScreenSaverSettings.defaultFolderPathForUI
        let interval = d.integer(forKey: ScreenSaverSettings.Key.slideIntervalSeconds)
        intervalField.stringValue = interval > 0 ? "\(interval)" : "\(ScreenSaverSettings.defaultSlideInterval)"
        pkceCodeVerifier = nil
    }

    @objc private func openDropboxSignIn() {
        let appKey = appKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appKey.isEmpty else {
            presentAlert(title: "App key required", message: "Enter your Dropbox app key first.")
            return
        }
        let verifier = DropboxOAuth.generateCodeVerifier()
        pkceCodeVerifier = verifier
        let challenge = DropboxOAuth.codeChallengeS256(verifier: verifier)
        let url = DropboxOAuth.authorizeURL(clientId: appKey, codeChallenge: challenge, redirectURI: nil)
        NSWorkspace.shared.open(url)
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

        Task {
            do {
                let tokens = try await DropboxOAuth.exchangeAuthorizationCode(
                    clientId: appKey,
                    code: code,
                    codeVerifier: verifier,
                    redirectURI: nil
                )
                let refreshTrimmed = (tokens.refreshToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !refreshTrimmed.isEmpty else {
                    await MainActor.run {
                        self.presentAlert(
                            title: "No refresh token",
                            message: "Dropbox did not return a refresh token. Ensure the app requests offline access and try signing in again.",
                            style: .warning
                        )
                    }
                    return
                }
                await MainActor.run {
                    DropboxScreenSaverOAuth.saveSession(tokens: tokens, clientId: appKey, defaults: self.defaults())
                    self.pkceCodeVerifier = nil
                    self.authCodeField.stringValue = ""
                    self.presentAlert(title: "Signed in", message: "OAuth tokens saved. Click OK to keep folder and interval changes.")
                }
            } catch {
                await MainActor.run {
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
        let d = defaults()
        let appKey = appKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !appKey.isEmpty {
            d.set(appKey, forKey: ScreenSaverSettings.Key.dropboxAppKey)
        }
        d.set(pathField.stringValue, forKey: ScreenSaverSettings.Key.dropboxFolderPath)
        let sec = ScreenSaverSettings.clampedSlideIntervalSeconds(from: intervalField.stringValue)
        d.set(sec, forKey: ScreenSaverSettings.Key.slideIntervalSeconds)
        d.synchronize()
        dismissConfigureSheet(returnCode: .OK)
    }

    @objc private func closeOnly() {
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

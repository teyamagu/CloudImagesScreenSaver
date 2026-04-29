import AppKit

enum ConfigureSheetViewFactory {
    struct BuiltWindow {
        let window: NSWindow
        let openButton: NSButton
        let completeButton: NSButton
    }

    static func makeWindow(
        appKeyField: NSTextField,
        authCodeField: NSTextField,
        pathField: NSTextField,
        intervalField: NSTextField,
        target: AnyObject,
        openAction: Selector,
        completeAction: Selector,
        saveAction: Selector,
        closeAction: Selector
    ) -> BuiltWindow {
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
        let helpFont = help.font ?? NSFont.systemFont(ofSize: 11)
        let helpMeasured = ceil((helpText as NSString).boundingRect(
            with: NSSize(width: helpWidth, height: 10000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: helpFont]
        ).height)
        let helpH = max(helpMeasured + 5, 1)

        let buttonRowY = footerPad
        let helpBottomY = footerPad + buttonH + helpGapAboveButtons
        let helpTopY = helpBottomY + helpH
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
        let open = NSButton(title: "Open Dropbox…", target: target, action: openAction)
        open.bezelStyle = .rounded
        open.frame = NSRect(x: pad + 128, y: oauthY, width: 150, height: 28)
        let complete = NSButton(title: "Complete sign-in", target: target, action: completeAction)
        complete.bezelStyle = .rounded
        complete.frame = NSRect(x: pad + 128 + 160, y: oauthY, width: 160, height: 28)
        root.addSubview(open)
        root.addSubview(complete)
        root.addSubview(help)

        let win = NSWindow(contentRect: root.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.contentView = root
        win.title = "Cloud Images Screen Saver"
        win.isReleasedWhenClosed = false

        let ok = NSButton(title: "OK", target: target, action: saveAction)
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        ok.frame = NSRect(x: contentW - pad - okW, y: buttonRowY, width: okW, height: buttonH)
        let cancel = NSButton(title: "Cancel", target: target, action: closeAction)
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: ok.frame.minX - buttonGap - cancelW, y: buttonRowY, width: cancelW, height: buttonH)
        root.addSubview(cancel)
        root.addSubview(ok)

        return BuiltWindow(window: win, openButton: open, completeButton: complete)
    }
}

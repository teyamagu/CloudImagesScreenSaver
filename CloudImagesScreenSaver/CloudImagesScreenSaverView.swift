import AppKit
#if SWIFT_PACKAGE
    import DropboxAPI
#endif
import OSLog
import QuartzCore
import ScreenSaver

@objc(CloudImagesScreenSaverView)
final class CloudImagesScreenSaverView: ScreenSaverView {
    private static let log = Logger(subsystem: "com.cloudimagesscreensaver.app", category: "ScreenSaverView")
    private enum Layout {
        static let statusHorizontalInset: CGFloat = 28
        static let statusBottomInset: CGFloat = 40
        static let statusMinHeight: CGFloat = 52
        static let statusMaxHeight: CGFloat = 120
    }

    private let crossfadeDuration: TimeInterval = 1.0

    private let frontImageView = NSImageView()
    private let backImageView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")

    /// Advanced via `animateOneFrame` (`Timer` may not fire when the screen saver run loop does not run as expected).
    private var slideshowSlideInterval: TimeInterval = 0
    private var lastSlideshowTickTime: CFTimeInterval = 0

    private var imageLoader: CloudImagesFolderImageLoader?
    /// Drains `CloudImagesFolderImageLoader` events on the main run loop; `animateOneFrame` alone can be too sparse in ScreenSaverEngine.
    private var loaderFlushTimer: Timer?

    /// Read only from the timer / delegate path (main thread in a normal app).
    private var readyURLs: [URL] = []

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        for v in [backImageView, frontImageView] {
            v.imageScaling = .scaleProportionallyUpOrDown
            v.imageAlignment = .alignCenter
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.black.cgColor
            v.layer?.opacity = 0
        }

        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: isPreview ? 10 : 18)
        statusLabel.alignment = .center
        statusLabel.isEditable = false
        statusLabel.isBordered = false
        statusLabel.drawsBackground = false
        statusLabel.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        statusLabel.maximumNumberOfLines = 0
        statusLabel.cell?.wraps = true
        statusLabel.wantsLayer = true
        statusLabel.layer?.cornerRadius = 10
        statusLabel.layer?.masksToBounds = true

        addSubview(backImageView)
        addSubview(frontImageView)
        addSubview(statusLabel)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        ConfigureSheetController.shared.invalidateConfigureSheetPresentationContext()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            ConfigureSheetController.shared.invalidateConfigureSheetPresentationContext()
        }
    }

    override var hasConfigureSheet: Bool {
        true
    }

    override var configureSheet: NSWindow? {
        ConfigureSheetController.shared.prepareConfigureSheetForDisplay(hostWindow: window)
        return ConfigureSheetController.shared.window
    }

    override func startAnimation() {
        super.startAnimation()
        let previewFlag = isPreview
        layoutImageViews()

        if previewFlag {
            setStatusText("Preview — set Dropbox OAuth (or folder) in Options")
            frontImageView.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)
            frontImageView.contentTintColor = .white
            frontImageView.layer?.opacity = 1
            return
        }

        let d = ScreenSaverSettings.screenSaverDefaults()
        let folder = d.string(forKey: ScreenSaverSettings.Key.dropboxFolderPath) ?? ""
        let rawInterval = d.integer(forKey: ScreenSaverSettings.Key.slideIntervalSeconds)
        let interval = rawInterval > 0 ? rawInterval : ScreenSaverSettings.defaultSlideInterval
        let seconds = ScreenSaverSettings.clampedSlideIntervalSeconds(interval)

        guard DropboxScreenSaverOAuth.hasConfiguredAuth(defaults: d),
              !folder.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            setStatusText("System Settings → Screen Saver → Options: sign in to Dropbox and set folder")
            return
        }

        slideshowSlideInterval = TimeInterval(seconds)
        lastSlideshowTickTime = CACurrentMediaTime()

        setStatusText("Connecting to Dropbox…")
        let loader = CloudImagesFolderImageLoader(
            resolveAccessToken: {
                try await DropboxScreenSaverOAuth.resolveAccessToken(defaults: ScreenSaverSettings.screenSaverDefaults())
            }
        )
        loader.delegate = self
        loader.start(folderPath: folder)
        imageLoader = loader
        // Deliver any synchronous prefetch events (cached images/status) immediately.
        // This avoids waiting for the first `Timer` tick or an engine-driven `animateOneFrame`.
        imageLoader?.flushPendingEventsToDelegate()
        scheduleLoaderFlushTimer()
    }

    override func stopAnimation() {
        super.stopAnimation()
        invalidateLoaderFlushTimer()
        slideshowSlideInterval = 0
        imageLoader?.flushPendingEventsToDelegate()
        imageLoader?.cancel()
        imageLoader = nil
    }

    override func animateOneFrame() {
        imageLoader?.flushPendingEventsToDelegate()
        tickSlideshowIfNeeded()
    }

    override func draw(_ rect: NSRect) {
        if layer == nil {
            NSColor.black.setFill()
            rect.fill()
        }
    }

    override func layout() {
        super.layout()
        layoutImageViews()
    }

    private func invalidateLoaderFlushTimer() {
        if Thread.isMainThread {
            loaderFlushTimer?.invalidate()
            loaderFlushTimer = nil
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.loaderFlushTimer?.invalidate()
                self?.loaderFlushTimer = nil
            }
        }
    }

    /// Schedules periodic `flushPendingEventsToDelegate` on `RunLoop.main` in `.common` so updates appear even when `animateOneFrame` is delayed.
    private func scheduleLoaderFlushTimer() {
        let schedule: () -> Void = { [weak self] in
            guard let self else { return }
            loaderFlushTimer?.invalidate()
            loaderFlushTimer = nil
            guard imageLoader != nil else { return }
            imageLoader?.flushPendingEventsToDelegate()
            let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
                self?.imageLoader?.flushPendingEventsToDelegate()
            }
            RunLoop.main.add(timer, forMode: .common)
            loaderFlushTimer = timer
        }

        if Thread.isMainThread {
            schedule()
        } else {
            DispatchQueue.main.async(execute: schedule)
        }
    }

    private func layoutImageViews() {
        let b = bounds
        backImageView.frame = b
        frontImageView.frame = b

        let w = max(0, b.width - Layout.statusHorizontalInset * 2)
        let h = statusLabelHeight(forWidth: w)
        statusLabel.frame = NSRect(
            x: Layout.statusHorizontalInset,
            y: Layout.statusBottomInset,
            width: w,
            height: h
        )
        bringStatusLabelToFront()
    }

    /// After crossfade `addSubview(..., .above, ...)`, move the status label back on top.
    private func bringStatusLabelToFront() {
        guard statusLabel.superview === self else { return }
        statusLabel.removeFromSuperview()
        addSubview(statusLabel)
    }

    private func statusLabelHeight(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return Layout.statusMinHeight }
        let s = statusLabel.stringValue as NSString
        if s.length == 0 {
            return Layout.statusMinHeight
        }
        let attr: [NSAttributedString.Key: Any] = [.font: statusLabel.font!]
        let rect = s.boundingRect(
            with: NSSize(width: width - 16, height: 10000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attr
        )
        let textH = ceil(rect.height) + 20
        return min(Layout.statusMaxHeight, max(Layout.statusMinHeight, textH))
    }

    private func tickSlideshowIfNeeded() {
        guard !isPreview else { return }
        guard slideshowSlideInterval > 0 else { return }
        guard !readyURLs.isEmpty else { return }
        let now = CACurrentMediaTime()
        guard now - lastSlideshowTickTime >= slideshowSlideInterval else { return }
        lastSlideshowTickTime = now
        advanceSlide()
    }

    private func advanceSlide() {
        let urls = readyURLs
        guard !urls.isEmpty else { return }

        let next = urls.randomElement()!
        guard let img = NSImage(contentsOf: next) else { return }

        CATransaction.begin()
        CATransaction.setAnimationDuration(crossfadeDuration)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = crossfadeDuration

        if frontImageView.layer?.opacity == 1 {
            backImageView.image = img
            backImageView.layer?.opacity = 0
            addSubview(backImageView, positioned: .above, relativeTo: frontImageView)
            backImageView.layer?.add(fade, forKey: "fadeIn")
            backImageView.layer?.opacity = 1

            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = 1
            fadeOut.toValue = 0
            fadeOut.duration = crossfadeDuration
            frontImageView.layer?.add(fadeOut, forKey: "fadeOut")
            frontImageView.layer?.opacity = 0
        } else {
            frontImageView.image = img
            frontImageView.layer?.opacity = 0
            addSubview(frontImageView, positioned: .above, relativeTo: backImageView)
            frontImageView.layer?.add(fade, forKey: "fadeIn")
            frontImageView.layer?.opacity = 1

            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = 1
            fadeOut.toValue = 0
            fadeOut.duration = crossfadeDuration
            backImageView.layer?.add(fadeOut, forKey: "fadeOut")
            backImageView.layer?.opacity = 0
        }
        CATransaction.commit()

        setStatusText("")
    }

    private func appendReady(_ url: URL) {
        if !readyURLs.contains(where: { $0.path == url.path }) {
            readyURLs.append(url)
        }
    }

    private func showImmediate(url: URL) {
        guard let img = NSImage(contentsOf: url) else { return }
        frontImageView.image = img
        frontImageView.layer?.opacity = 1
        backImageView.layer?.opacity = 0
        bringStatusLabelToFront()
    }

    private func setStatusText(_ text: String) {
        statusLabel.stringValue = text
        if statusLabel.stringValue != "" {
            statusLabel.drawsBackground = true
        } else {
            statusLabel.drawsBackground = false
        }
        layoutImageViews()
        bringStatusLabelToFront()
    }
}

// MARK: - CloudImagesFolderImageLoaderDelegate

extension CloudImagesScreenSaverView: CloudImagesFolderImageLoaderDelegate {
    func folderImageLoader(_: CloudImagesFolderImageLoader, statusDidChange message: String) {
        setStatusText(message)
    }

    func folderImageLoader(_: CloudImagesFolderImageLoader, didCacheImageAt url: URL) {
        appendReady(url)
        if frontImageView.image == nil {
            showImmediate(url: url)
        }
    }

    func folderImageLoader(_: CloudImagesFolderImageLoader, didFailWithError error: Error) {
        setStatusText("Error: \(error.localizedDescription)")
    }

    func folderImageLoaderDidCompletePipeline(
        _: CloudImagesFolderImageLoader,
        listedImagePathCount: Int,
        lastDownloadError: Error?
    ) {
        defer { invalidateLoaderFlushTimer() }
        if !readyURLs.isEmpty {
            setStatusText("")
            return
        }
        if listedImagePathCount == 0 {
            return
        }
        if let e = lastDownloadError {
            setStatusText("Error: \(e.localizedDescription)")
            return
        }
        setStatusText("No displayable images")
    }
}

// MARK: - Unit test hooks (`CloudImagesScreenSaverModuleTests`)

extension CloudImagesScreenSaverView {
    /// Current status line text (used by SwiftPM UI tests).
    var testHook_statusLabelString: String {
        statusLabel.stringValue
    }

    /// True when the front image view has an image and is visibly opaque.
    var testHook_frontImageVisible: Bool {
        guard frontImageView.image != nil else { return false }
        return (frontImageView.layer?.opacity ?? 0) > 0.01
    }

    /// Call after `loader.delegate = self` and `loader.start(...)` so the view’s flush timer drains loader events.
    func testHook_installLoaderForRunningSession(_ loader: CloudImagesFolderImageLoader) {
        imageLoader = loader
        scheduleLoaderFlushTimer()
    }
}

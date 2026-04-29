import AppKit
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

    private let crossfadeDuration: TimeInterval = ScreenSaverSettings.Policy.crossfadeDuration

    private let frontImageView = NSImageView()
    private let backImageView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")

    /// Advanced via `animateOneFrame` (`Timer` may not fire when the screen saver run loop does not run as expected).
    private var slideshowSlideInterval: TimeInterval = 0
    private var lastSlideshowTickTime: CFTimeInterval = 0

    private var imageLoader: AppCloudImagesFolderImageLoader?
    /// Read only from the timer / delegate path (main thread in a normal app).
    private var readyURLs: [URL] = []
    private(set) var statusState: ScreenSaverStatusState = .idle

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
            setStatus(text: "Preview — set Dropbox OAuth (or folder) in Options", state: .preview)
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
            setStatus(text: "System Settings → Screen Saver → Options: sign in to Dropbox and set folder", state: .other)
            return
        }

        slideshowSlideInterval = TimeInterval(seconds)
        lastSlideshowTickTime = CACurrentMediaTime()

        setStatus(text: "Connecting to Dropbox…", state: .connecting)
        let loader = AppCloudImagesFolderImageLoader(
            resolveAccessToken: {
                try await DropboxScreenSaverOAuth.resolveAccessToken(defaults: ScreenSaverSettings.screenSaverDefaults())
            }
        )
        loader.delegate = self
        loader.start(folderPath: folder)
        imageLoader = loader
    }

    override func stopAnimation() {
        super.stopAnimation()
        slideshowSlideInterval = 0
        imageLoader?.cancel()
        imageLoader = nil
    }

    override func animateOneFrame() {
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
        guard let font = statusLabel.font else { return Layout.statusMinHeight }
        let s = statusLabel.stringValue as NSString
        if s.length == 0 {
            return Layout.statusMinHeight
        }
        let attr: [NSAttributedString.Key: Any] = [.font: font]
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
        guard let next = urls.randomElement() else { return }
        guard let img = NSImage(contentsOf: next) else { return }

        CATransaction.begin()
        CATransaction.setAnimationDuration(crossfadeDuration)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = crossfadeDuration

        if frontImageView.layer?.opacity == 1 {
            applyCrossfade(showing: backImageView, hiding: frontImageView, image: img, fadeIn: fade)
        } else {
            applyCrossfade(showing: frontImageView, hiding: backImageView, image: img, fadeIn: fade)
        }
        CATransaction.commit()

        setStatus(text: "", state: .idle)
    }

    private func applyCrossfade(
        showing showView: NSImageView,
        hiding hideView: NSImageView,
        image: NSImage,
        fadeIn: CABasicAnimation
    ) {
        showView.image = image
        showView.layer?.opacity = 0
        addSubview(showView, positioned: .above, relativeTo: hideView)
        showView.layer?.add(fadeIn, forKey: "fadeIn")
        showView.layer?.opacity = 1

        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1
        fadeOut.toValue = 0
        fadeOut.duration = crossfadeDuration
        hideView.layer?.add(fadeOut, forKey: "fadeOut")
        hideView.layer?.opacity = 0
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

    private func setStatus(text: String, state: ScreenSaverStatusState) {
        statusLabel.stringValue = text
        statusState = state
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

extension CloudImagesScreenSaverView: AppCloudImagesFolderImageLoaderDelegate {
    func folderImageLoader(_: AppCloudImagesFolderImageLoader, didEmit outcome: AppLoaderOutcome) {
        let presentation = StatusPresenter.presentation(for: outcome)
        if let text = presentation.text {
            setStatus(text: text, state: presentation.state)
        }
        switch outcome {
        case let .cached(url):
            appendReady(url)
            if frontImageView.image == nil {
                showImmediate(url: url)
            }
        case let .pipelineCompleted(listedImagePathCount, lastDownloadError):
            if !readyURLs.isEmpty {
                setStatus(text: "", state: .idle)
                return
            }
            if listedImagePathCount == 0 {
                return
            }
            if let e = lastDownloadError {
                setStatus(text: "Error: \(e.localizedDescription)", state: .error)
                return
            }
            setStatus(text: "No displayable images", state: .other)
        case .status, .failed:
            break
        }
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
    func testHook_installLoaderForRunningSession(_ loader: AppCloudImagesFolderImageLoader) {
        imageLoader = loader
    }

    var testHook_statusState: ScreenSaverStatusState {
        statusState
    }
}

enum ScreenSaverStatusState: Equatable {
    case idle
    case preview
    case connecting
    case progress
    case error
    case other
}

enum StatusPresenter {
    struct Presentation {
        let text: String?
        let state: ScreenSaverStatusState
    }

    static func presentation(for outcome: AppLoaderOutcome) -> Presentation {
        switch outcome {
        case let .status(status):
            if status.message.isEmpty {
                return .init(text: "", state: .idle)
            }
            switch status.kind {
            case .connecting:
                return .init(text: status.message, state: .connecting)
            case .progress:
                return .init(text: status.message, state: .progress)
            case .info:
                return .init(text: status.message, state: .other)
            }
        case let .failed(error):
            return .init(text: "Error: \(error.localizedDescription)", state: .error)
        case .cached:
            return .init(text: nil, state: .other)
        case .pipelineCompleted:
            return .init(text: nil, state: .other)
        }
    }
}

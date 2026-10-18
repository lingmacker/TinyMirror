import AppKit
import AVFoundation

final class MirrorWindowController: NSWindowController, NSWindowDelegate {
    enum PlaybackState { case waiting, connecting, mirroring, unavailable }
    private enum ResizeAxis { case undecided, width, height }

    // Sizes include the 5pt bezel; the idle picture itself uses a 9:18 ratio.
    private static let idleWindowSize = NSSize(width: 370, height: 730)
    private static let idleMinimumSize = NSSize(width: 250, height: 490)

    private let frameView = MirrorFrameView()
    var videoView: MirrorVideoView { frameView.videoView }
    private let waitingView = NSBox()
    private let waitingTitle = NSTextField(wrappingLabelWithString: String(localized: "Ready to mirror", bundle: .appLocalization))
    private let waitingHint = NSTextField(wrappingLabelWithString: "")
    private var receiverName = "MirrorDeck"
    private var receiverAvailable = true
    private var deviceName: String?
    private var videoSize: NSSize = .zero
    private var fullScreenVideoSize: NSSize = .zero
    private var firstFrameReady = false
    private var buttonTrackingArea: NSTrackingArea?
    private var liveResizeAxis: ResizeAxis?
    private(set) var playbackState = PlaybackState.waiting

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.idleWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "MirrorDeck"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        super.init(window: window)
        window.delegate = self
        frameView.frame = window.contentView!.bounds
        frameView.autoresizingMask = [.width, .height]
        window.contentView = frameView
        frameView.layoutSubtreeIfNeeded()
        buildWaitingView()
        refreshWindowButtons()
        NotificationCenter.default.addObserver(
            self, selector: #selector(videoReadinessChanged),
            name: .AVSampleBufferDisplayLayerReadyForDisplayDidChange,
            object: videoView.displayLayer)
        updatePlaybackState()
        resetIdleWindowSize()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func buildWaitingView() {
        waitingView.boxType = .custom
        waitingView.borderWidth = 0
        waitingView.titlePosition = .noTitle
        waitingView.fillColor = .windowBackgroundColor
        waitingView.contentViewMargins = .zero
        waitingView.frame = videoView.bounds
        waitingView.autoresizingMask = [.width, .height]
        videoView.addSubview(waitingView)

        let symbol = NSImageView(image: NSImage(
            systemSymbolName: "airplay.video", accessibilityDescription: nil)!)
        symbol.symbolConfiguration = .init(pointSize: 36, weight: .light)
        symbol.contentTintColor = .secondaryLabelColor
        waitingTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        waitingHint.font = .systemFont(ofSize: 13)
        waitingHint.textColor = .secondaryLabelColor
        waitingHint.alignment = .center
        waitingTitle.alignment = .center
        waitingTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        waitingHint.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [symbol, waitingTitle, waitingHint])
        stack.orientation = .vertical
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        waitingView.contentView!.addSubview(stack)
        let preferredWidth = stack.widthAnchor.constraint(equalToConstant: 280)
        preferredWidth.priority = .init(NSLayoutConstraint.Priority.defaultLow.rawValue + 1)
        NSLayoutConstraint.activate([
            preferredWidth,
            stack.centerXAnchor.constraint(equalTo: waitingView.contentView!.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: waitingView.contentView!.centerYAnchor, constant: -16),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            stack.widthAnchor.constraint(lessThanOrEqualTo: waitingView.widthAnchor, constant: -48),
            waitingTitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            waitingHint.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    func setReceiverState(name: String, isRunning: Bool) {
        receiverName = name
        receiverAvailable = isRunning
        updatePlaybackState()
    }

    func setDeviceName(_ name: String?) {
        if name != deviceName || name == nil { firstFrameReady = false }
        deviceName = name
        if name == nil {
            videoSize = .zero
            resetIdleWindowSize()
        }
        updatePlaybackState()
    }

    private func resetIdleWindowSize() {
        guard let window, !frameView.isFullScreen, !window.styleMask.contains(.fullScreen) else { return }
        window.minSize = Self.idleMinimumSize
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        resizeWindow(to: Self.idleWindowSize, on: screen)
    }

    @objc private func videoReadinessChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.firstFrameReady = self.videoView.displayLayer.isReadyForDisplay
            self.updatePlaybackState()
        }
    }

    private func updatePlaybackState() {
        if deviceName != nil {
            playbackState = firstFrameReady ? .mirroring : .connecting
        } else {
            playbackState = receiverAvailable ? .waiting : .unavailable
        }
        window?.title = deviceName ?? "MirrorDeck"
        waitingView.isHidden = playbackState == .mirroring
        switch playbackState {
        case .waiting:
            waitingTitle.stringValue = String(localized: "Ready to mirror", bundle: .appLocalization)
            waitingHint.stringValue = String.localizedStringWithFormat(
                String(localized: "On your iPhone, open Control Center → Screen Mirroring and choose “%@”.", bundle: .appLocalization),
                receiverName)
        case .connecting:
            waitingTitle.stringValue = String(localized: "Waiting for your screen", bundle: .appLocalization)
            waitingHint.stringValue = String(localized: "Keep Screen Mirroring enabled on your iPhone. The picture will appear here.", bundle: .appLocalization)
        case .mirroring:
            break
        case .unavailable:
            waitingTitle.stringValue = String(localized: "Unable to start mirroring", bundle: .appLocalization)
            waitingHint.stringValue = String(localized: "Quit and reopen MirrorDeck to try again. Check that local network access is allowed in System Settings.", bundle: .appLocalization)
        }
    }

    private func setWindowButtonsVisible(_ hovering: Bool) {
        guard let window else { return }
        // Full screen owns its title-bar reveal; VoiceOver must retain native actions.
        let visible = hovering || window.styleMask.contains(.fullScreen) || NSWorkspace.shared.isVoiceOverEnabled
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = !visible
        }
    }

    private func refreshWindowButtons() {
        guard let window else { return }
        guard !window.styleMask.contains(.fullScreen) else {
            setWindowButtonsVisible(true)
            return
        }
        let rect = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .reduce(NSRect.null) { $0.union(frameView.convert($1.bounds, from: $1)) }
            .insetBy(dx: -8, dy: -8).intersection(frameView.bounds)
        if buttonTrackingArea?.rect != rect {
            if let buttonTrackingArea { frameView.removeTrackingArea(buttonTrackingArea) }
            let area = NSTrackingArea(
                rect: rect, options: [.mouseEnteredAndExited, .activeAlways, .enabledDuringMouseDrag],
                owner: self, userInfo: nil)
            frameView.addTrackingArea(area)
            buttonTrackingArea = area
        }
        let point = frameView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setWindowButtonsVisible(window.isVisible && rect.contains(point))
    }

    override func mouseEntered(with event: NSEvent) {
        let point = frameView.convert(event.locationInWindow, from: nil)
        setWindowButtonsVisible(buttonTrackingArea?.rect.contains(point) == true)
    }
    override func mouseExited(with event: NSEvent) { setWindowButtonsVisible(false) }

    func windowDidMove(_ notification: Notification) { refreshWindowButtons() }
    func windowWillStartLiveResize(_ notification: Notification) { liveResizeAxis = .undecided }
    func windowDidEndLiveResize(_ notification: Notification) { liveResizeAxis = nil }
    func windowDidResize(_ notification: Notification) {
        frameView.needsLayout = true
        frameView.layoutSubtreeIfNeeded()
        refreshWindowButtons()
    }
    func windowWillClose(_ notification: Notification) { setWindowButtonsVisible(false) }

    var isAlwaysOnTop = false {
        didSet { updateWindowLevel() }
    }

    private func updateWindowLevel() {
        window?.level = isAlwaysOnTop && window?.styleMask.contains(.fullScreen) != true ? .floating : .normal
    }

    override func cancelOperation(_ sender: Any?) {
        if window?.styleMask.contains(.fullScreen) == true {
            window?.toggleFullScreen(nil)
        }
    }

    /// The bezel sits outside the picture, so only the inner rectangle follows the video ratio.
    func setVideoDimensions(width: Int, height: Int) {
        guard let window, width > 0, height > 0 else { return }
        videoSize = NSSize(width: width, height: height)
        guard !frameView.isFullScreen, !window.styleMask.contains(.fullScreen) else { return }
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let aspect = videoSize.width / videoSize.height
        let border = frameView.contentInset * 2
        let targetHeight = min(780, screen.height * 0.8 - border, (screen.width * 0.8 - border) / aspect)
        let pictureWidth = targetHeight * aspect
        let size = NSSize(width: pictureWidth + border, height: targetHeight + border)
        let minWidth = min(pictureWidth, max(260, 160 * aspect))
        window.minSize = NSSize(width: minWidth + border, height: minWidth / aspect + border)
        resizeWindow(to: size, on: screen)
    }

    private func resizeWindow(to size: NSSize, on screen: NSRect) {
        guard let window else { return }
        let center = window.isVisible
            ? NSPoint(x: window.frame.midX, y: window.frame.midY)
            : NSPoint(x: screen.maxX - size.width / 2 - 48, y: screen.midY)
        let origin = NSPoint(
            x: max(screen.minX, min(center.x - size.width / 2, screen.maxX - size.width)),
            y: max(screen.minY, min(center.y - size.height / 2, screen.maxY - size.height)))
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // Zeroing native aspectRatio also zeros resize increments and breaks AppKit restoration.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard videoSize != .zero, !frameView.isFullScreen, !sender.styleMask.contains(.fullScreen) else { return frameSize }
        let border = frameView.contentInset * 2
        let aspect = videoSize.width / videoSize.height
        let width = max(frameSize.width, sender.minSize.width)
        let height = max(frameSize.height, sender.minSize.height)
        let suggestedAxis: ResizeAxis = abs(frameSize.width - sender.frame.width)
            > abs(frameSize.height - sender.frame.height) * aspect ? .width : .height
        if liveResizeAxis == .undecided {
            guard frameSize != sender.frame.size else { return frameSize }
            liveResizeAxis = suggestedAxis
        }
        // Keep one axis per gesture so our corrected size cannot flip the next resize decision.
        if (liveResizeAxis ?? suggestedAxis) == .width {
            return NSSize(width: width, height: (width - border) / aspect + border)
        }
        return NSSize(width: (height - border) * aspect + border, height: height)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        fullScreenVideoSize = videoSize
        frameView.isFullScreen = true
        frameView.layoutSubtreeIfNeeded()
        setWindowButtonsVisible(true)
        window?.level = .normal
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        frameView.isFullScreen = false
        frameView.layoutSubtreeIfNeeded()
        updateWindowLevel()
        if videoSize == .zero && fullScreenVideoSize != .zero {
            resetIdleWindowSize()
        } else if videoSize != .zero && videoSize != fullScreenVideoSize {
            setVideoDimensions(width: Int(videoSize.width), height: Int(videoSize.height))
        }
        refreshWindowButtons()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        frameView.isFullScreen = false
        frameView.layoutSubtreeIfNeeded()
        updateWindowLevel()
        refreshWindowButtons()
    }

    func present() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(videoView)
        NSApp.activate(ignoringOtherApps: true)
        refreshWindowButtons()
    }

    func dismiss() {
        window?.orderOut(nil)
        setWindowButtonsVisible(false)
    }
}

import AppKit
import AVFoundation

final class MirrorWindowController: NSWindowController, NSWindowDelegate {
    enum PlaybackState { case waiting, connecting, mirroring, unavailable }
    private enum ResizeAxis { case undecided, width, height }
    private enum FullScreenTransition { case entering, exiting }

    // Sizes include the 5pt side/bottom bezel and top status bar; idle picture uses 9:18.
    static let idleWindowSize = NSSize(
        width: 360 + MirrorFrameView.borderWidth * 2,
        height: 720 + MirrorFrameView.topBarHeight + MirrorFrameView.borderWidth)
    static let idleMinimumSize = NSSize(
        width: 240 + MirrorFrameView.borderWidth * 2,
        height: 480 + MirrorFrameView.topBarHeight + MirrorFrameView.borderWidth)

    private let frameView = MirrorFrameView()
    var videoView: MirrorVideoView { frameView.videoView }
    var topBar: MirrorTopBarView { frameView.topBar }

    var onToggleBluetoothControl: ((Bool) -> Void)?
    var onReconnectBluetooth: (() -> Void)?
    var onSendHomeButton: (() -> Void)?
    var hasSavedPairedHost: (() -> Bool)?

    private let waitingView = NSBox()
    private let waitingTitle = NSTextField(wrappingLabelWithString: String(localized: "Ready to mirror", bundle: .appLocalization))
    private let waitingHint = NSTextField(wrappingLabelWithString: "")
    private var receiverName = "TinyMirror"
    private var receiverAvailable = true
    private var deviceName: String?
    private var canvasSize: NSSize = .zero
    private var fullScreenCanvasSize: NSSize?
    private var firstFrameReady = false
    private var liveResizeAxis: ResizeAxis?
    private var fullScreenTransition: FullScreenTransition?
    private var dismissAfterFullScreen = false
    private(set) var playbackState = PlaybackState.waiting

    private var bluetoothStatus = BluetoothHIDStatus.disabled()
    private let pairingPopover = NSPopover()
    private let pairingPopoverController = BluetoothPairingPopoverController()
    private var pairingGuideTimer: DispatchWorkItem?

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.idleWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "TinyMirror"
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
        wireTopBar()
        ensureWindowButtonsVisible()
        alignTopBarControls()
        NotificationCenter.default.addObserver(
            self, selector: #selector(videoReadinessChanged),
            name: .AVSampleBufferDisplayLayerReadyForDisplayDidChange,
            object: videoView.displayLayer)
        updatePlaybackState()
        resetIdleWindowSize()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        pairingGuideTimer?.cancel()
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

    private func wireTopBar() {
        pairingPopover.behavior = .semitransient
        pairingPopover.contentViewController = pairingPopoverController
        pairingPopoverController.onReconnect = { [weak self] in
            self?.onReconnectBluetooth?()
        }
        pairingPopoverController.onTurnOff = { [weak self] in
            guard let self else { return }
            self.cancelPairingGuideTimer()
            self.pairingPopover.performClose(nil)
            self.onToggleBluetoothControl?(false)
        }
        frameView.topBar.onBluetoothButtonClick = { [weak self] in
            self?.handleBluetoothButtonClick()
        }
        frameView.topBar.onHomeButtonClick = { [weak self] in
            self?.onSendHomeButton?()
        }
        frameView.topBar.updateBluetoothStatus(bluetoothStatus)
    }

    // MARK: - Bluetooth Control Top Bar & Pairing Popover

    func setBluetoothStatus(_ status: BluetoothHIDStatus) {
        bluetoothStatus = status
        frameView.topBar.updateBluetoothStatus(status)
        pairingPopoverController.update(status: status)
        if !status.isEnabled || (status.isConnected && status.pointerReady) {
            cancelPairingGuideTimer()
            if pairingPopover.isShown {
                pairingPopover.performClose(nil)
            }
        }
    }

    private func handleBluetoothButtonClick() {
        if !bluetoothStatus.isEnabled {
            onToggleBluetoothControl?(true)
            let hasSaved = hasSavedPairedHost?() == true
            if hasSaved {
                // Give silent auto-reconnect a brief window before showing pairing instructions.
                cancelPairingGuideTimer()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.bluetoothStatus.isEnabled,
                          !(self.bluetoothStatus.isConnected && self.bluetoothStatus.pointerReady) else { return }
                    self.showPairingPopover()
                }
                pairingGuideTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
            } else {
                showPairingPopover()
            }
            return
        }

        if bluetoothStatus.isConnected && bluetoothStatus.pointerReady {
            cancelPairingGuideTimer()
            pairingPopover.performClose(nil)
            onToggleBluetoothControl?(false)
            return
        }

        // Enabled but waiting to pair, reconnecting, or missing AssistiveTouch.
        if pairingPopover.isShown {
            pairingPopover.performClose(nil)
        } else {
            showPairingPopover()
        }
    }

    private func showPairingPopover() {
        guard let window, window.isVisible, !frameView.isFullScreen else { return }
        pairingPopoverController.update(status: bluetoothStatus)
        if !pairingPopover.isShown {
            pairingPopover.show(
                relativeTo: frameView.topBar.bluetoothButton.bounds,
                of: frameView.topBar.bluetoothButton,
                preferredEdge: .minY)
        }
    }

    private func cancelPairingGuideTimer() {
        pairingGuideTimer?.cancel()
        pairingGuideTimer = nil
    }

    // MARK: - Mirror State

    func setReceiverState(name: String, isRunning: Bool) {
        receiverName = name
        receiverAvailable = isRunning
        updatePlaybackState()
    }

    func setDeviceName(_ name: String?) {
        if name != nil { dismissAfterFullScreen = false }
        if name != deviceName || name == nil { firstFrameReady = false }
        deviceName = name
        if name == nil {
            canvasSize = .zero
            fullScreenCanvasSize = nil
            videoView.videoSize = .zero
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
        window?.title = deviceName ?? "TinyMirror"
        videoView.showingVideo = playbackState == .mirroring
        waitingView.isHidden = videoView.showingVideo
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
            waitingHint.stringValue = String(localized: "Quit and reopen TinyMirror to try again. Check that local network access is allowed in System Settings.", bundle: .appLocalization)
        }
    }

    private func ensureWindowButtonsVisible() {
        guard let window else { return }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = false
        }
    }

    private func alignTopBarControls() {
        guard let window, !frameView.isFullScreen,
              let closeButton = window.standardWindowButton(.closeButton)
        else {
            frameView.topBar.alignControlsVertically(toLocalY: nil)
            return
        }
        let rectInBar = frameView.topBar.convert(closeButton.bounds, from: closeButton)
        frameView.topBar.alignControlsVertically(toLocalY: rectInBar.midY)
    }

    func windowDidMove(_ notification: Notification) { alignTopBarControls() }
    func windowWillStartLiveResize(_ notification: Notification) { liveResizeAxis = .undecided }
    func windowDidEndLiveResize(_ notification: Notification) { liveResizeAxis = nil }
    func windowDidResize(_ notification: Notification) {
        frameView.needsLayout = true
        frameView.layoutSubtreeIfNeeded()
        ensureWindowButtonsVisible()
        alignTopBarControls()
    }
    func windowDidResignKey(_ notification: Notification) { videoView.resetPointer() }
    func windowWillClose(_ notification: Notification) {
        cancelPairingGuideTimer()
        pairingPopover.performClose(nil)
        videoView.resetPointer()
    }

    var isAlwaysOnTop = false {
        didSet { updateWindowLevel() }
    }

    private func updateWindowLevel() {
        window?.level = isAlwaysOnTop && window?.styleMask.contains(.fullScreen) != true ? .floating : .normal
    }

    override func cancelOperation(_ sender: Any?) {
        if pairingPopover.isShown {
            pairingPopover.performClose(nil)
            return
        }
        if fullScreenTransition == nil, window?.styleMask.contains(.fullScreen) == true {
            window?.toggleFullScreen(nil)
        }
    }

    /// The top bar and bezel sit outside the picture, so only the inner video rectangle follows the aspect ratio.
    func setVideoDimensions(width: Int, height: Int) {
        guard let window, width > 0, height > 0 else { return }
        videoView.videoSize = CGSize(width: width, height: height)
        let firstCanvas = canvasSize == .zero
        let orientationChanged = width != height && (canvasSize.width == canvasSize.height
            || (width > height) != (canvasSize.width > canvasSize.height))
        // Fit changing content inside a stable canvas; only a direction change resizes the window.
        guard firstCanvas || orientationChanged else { return }
        canvasSize = NSSize(width: width, height: height)
        guard !frameView.isFullScreen, !window.styleMask.contains(.fullScreen) else { return }
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let aspect = canvasSize.width / canvasSize.height
        let hChrome = frameView.horizontalChrome
        let vChrome = frameView.verticalChrome
        let targetHeight: CGFloat
        if firstCanvas {
            targetHeight = min(780, screen.height * 0.8 - vChrome, (screen.width * 0.8 - hChrome) / aspect)
        } else {
            let longEdge = max(window.frame.width - hChrome, window.frame.height - vChrome)
            targetHeight = min(longEdge / max(1, aspect), screen.height - vChrome, (screen.width - hChrome) / aspect)
        }
        let pictureWidth = targetHeight * aspect
        let size = NSSize(width: pictureWidth + hChrome, height: targetHeight + vChrome)
        let minWidth = min(pictureWidth, max(260, 160 * aspect))
        window.minSize = NSSize(width: minWidth + hChrome, height: minWidth / aspect + vChrome)
        resizeWindow(to: size, on: screen)
    }

    private func resizeWindow(to size: NSSize, on screen: NSRect) {
        guard let window else { return }
        let center = window.isVisible
            ? NSPoint(x: window.frame.midX, y: window.frame.midY)
            : NSPoint(x: screen.midX, y: screen.midY)
        let origin = NSPoint(
            x: max(screen.minX, min(center.x - size.width / 2, screen.maxX - size.width)),
            y: max(screen.minY, min(center.y - size.height / 2, screen.maxY - size.height)))
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // Zeroing native aspectRatio also zeros resize increments and breaks AppKit restoration.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard canvasSize != .zero, !frameView.isFullScreen, !sender.styleMask.contains(.fullScreen) else { return frameSize }
        let hChrome = frameView.horizontalChrome
        let vChrome = frameView.verticalChrome
        let aspect = canvasSize.width / canvasSize.height
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
            return NSSize(width: width, height: (width - hChrome) / aspect + vChrome)
        }
        return NSSize(width: (height - vChrome) * aspect + hChrome, height: height)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        fullScreenTransition = .entering
        fullScreenCanvasSize = canvasSize
        cancelPairingGuideTimer()
        pairingPopover.performClose(nil)
        frameView.isFullScreen = true
        frameView.layoutSubtreeIfNeeded()
        ensureWindowButtonsVisible()
        window?.level = .normal
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        fullScreenTransition = nil
        // AppKit releases its entry transition after this callback returns.
        if dismissAfterFullScreen {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.dismissAfterFullScreen, self.fullScreenTransition == nil else { return }
                self.window?.toggleFullScreen(nil)
            }
        }
    }

    func windowWillExitFullScreen(_ notification: Notification) { fullScreenTransition = .exiting }

    func windowDidExitFullScreen(_ notification: Notification) {
        fullScreenTransition = nil
        frameView.isFullScreen = false
        frameView.layoutSubtreeIfNeeded()
        updateWindowLevel()
        restoreWindowedCanvas()
        ensureWindowButtonsVisible()
        alignTopBarControls()
        if dismissAfterFullScreen {
            dismissAfterFullScreen = false
            dismiss()
        }
    }

    private func restoreWindowedCanvas() {
        let nextCanvas = canvasSize
        canvasSize = fullScreenCanvasSize ?? .zero
        if nextCanvas == .zero {
            canvasSize = .zero
            if fullScreenCanvasSize != NSSize.zero { resetIdleWindowSize() }
        } else {
            setVideoDimensions(width: Int(nextCanvas.width), height: Int(nextCanvas.height))
        }
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        fullScreenTransition = nil
        frameView.isFullScreen = false
        frameView.layoutSubtreeIfNeeded()
        updateWindowLevel()
        restoreWindowedCanvas()
        ensureWindowButtonsVisible()
        alignTopBarControls()
        if dismissAfterFullScreen {
            dismissAfterFullScreen = false
            dismiss()
        }
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        fullScreenTransition = nil
        dismissAfterFullScreen = false
        ensureWindowButtonsVisible()
        alignTopBarControls()
    }

    func present() {
        dismissAfterFullScreen = false
        guard let window else { return }
        if !window.isVisible, !frameView.isFullScreen, !window.styleMask.contains(.fullScreen),
           let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            resizeWindow(to: window.frame.size, on: screen)
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(videoView)
        NSApp.activate(ignoringOtherApps: true)
        ensureWindowButtonsVisible()
        alignTopBarControls()
    }

    func dismiss() {
        guard let window else { return }
        cancelPairingGuideTimer()
        pairingPopover.performClose(nil)
        if frameView.isFullScreen || window.styleMask.contains(.fullScreen) {
            // Leave the native Space before hiding, including when entry is still animating.
            let shouldExit = !dismissAfterFullScreen && fullScreenTransition == nil
            dismissAfterFullScreen = true
            if shouldExit { window.toggleFullScreen(nil) }
            return
        }
        window.orderOut(nil)
    }
}

import AppKit
import AVFoundation

final class MirrorVideoView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Mirrored device screen", bundle: .appLocalization))
        setAccessibilityHelp(String(localized: "Escape exits full screen.", bundle: .appLocalization))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer { displayLayer }

    var hidControl: BluetoothHIDController? {
        didSet {
            if hidControl !== oldValue { resetPointer() }
        }
    }

    var hidStatus: BluetoothHIDStatus? {
        didSet {
            if hidStatus?.pointerReady != true { resetPointer() }
        }
    }

    var videoSize: CGSize = .zero {
        didSet {
            if videoSize != oldValue { resetPointer() }
        }
    }

    var showingVideo = false {
        willSet { if !newValue { resetPointer() } }
    }

    private var activeButtonMask: UInt8 = 0
    private var mouseArea: NSTrackingArea?
    private var lastHoverSentAt: TimeInterval = 0
    private var pendingHoverPoint: CGPoint?
    private var hoverTimer: Timer?
    private var scrollRemainderX: CGFloat = 0
    private var scrollRemainderY: CGFloat = 0

    private static let hoverInterval: TimeInterval = 1.0 / 30.0
    private static let preciseScrollUnit: CGFloat = 16.0

    private var pointerForwarding: Bool {
        hidControl != nil && hidStatus?.pointerReady == true && showingVideo && window?.isKeyWindow == true
    }

    private var keyboardForwarding: Bool {
        hidControl != nil && hidStatus?.keyboardReady == true && showingVideo && window?.isKeyWindow == true
    }

    private var usesAbsolutePointer: Bool {
        hidStatus?.absolutePointerReady == true && videoSize.width > 0 && videoSize.height > 0
    }

    func resetPointer() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        pendingHoverPoint = nil
        scrollRemainderX = 0
        scrollRemainderY = 0
        if activeButtonMask != 0 {
            activeButtonMask = 0
            hidControl?.cancelPointer()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        if frame.size != newSize { resetPointer() }
        super.setFrameSize(newSize)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseArea { removeTrackingArea(mouseArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        mouseArea = area
    }

    // MARK: - Pointer Events

    override func mouseEntered(with event: NSEvent) {
        guard pointerForwarding else { super.mouseEntered(with: event); return }
        if usesAbsolutePointer, let point = normalizedPoint(for: event.locationInWindow, clamp: false) {
            submitAbsoluteHover(point, immediate: true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverTimer?.invalidate()
        hoverTimer = nil
        pendingHoverPoint = nil
        if activeButtonMask == 0 {
            super.mouseExited(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard pointerForwarding else { super.mouseMoved(with: event); return }
        if usesAbsolutePointer {
            if let point = normalizedPoint(for: event.locationInWindow, clamp: false) {
                submitAbsoluteHover(point, immediate: false)
            }
        } else {
            hidControl?.sendRelativeMove(dx: Int(event.deltaX.rounded()), dy: Int(event.deltaY.rounded()))
        }
    }

    override func mouseDown(with event: NSEvent) {
        handleButtonDown(buttonMask: 0x01, event: event) { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        handleButtonDragged(buttonMask: 0x01, event: event) { super.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        handleButtonUp(buttonMask: 0x01, event: event) { super.mouseUp(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        handleButtonDown(buttonMask: 0x02, event: event) { super.rightMouseDown(with: event) }
    }

    override func rightMouseDragged(with event: NSEvent) {
        handleButtonDragged(buttonMask: 0x02, event: event) { super.rightMouseDragged(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        handleButtonUp(buttonMask: 0x02, event: event) { super.rightMouseUp(with: event) }
    }

    private func handleButtonDown(buttonMask: UInt8, event: NSEvent, fallback: () -> Void) {
        guard pointerForwarding else { fallback(); return }
        window?.makeFirstResponder(self)
        clearPendingHover()
        if usesAbsolutePointer {
            guard let point = normalizedPoint(for: event.locationInWindow, clamp: false) else {
                fallback()
                return
            }
            activeButtonMask |= buttonMask
            hidControl?.pressAbsolute(buttonMask: buttonMask, x: point.x, y: point.y)
        } else {
            activeButtonMask |= buttonMask
            hidControl?.pressRelative(buttonMask: buttonMask)
        }
    }

    private func handleButtonDragged(buttonMask: UInt8, event: NSEvent, fallback: () -> Void) {
        guard pointerForwarding, (activeButtonMask & buttonMask) != 0 else { fallback(); return }
        clearPendingHover()
        if usesAbsolutePointer {
            if let point = normalizedPoint(for: event.locationInWindow, clamp: true) {
                hidControl?.dragAbsolute(x: point.x, y: point.y)
            }
        } else {
            hidControl?.sendRelativeMove(dx: Int(event.deltaX.rounded()), dy: Int(event.deltaY.rounded()))
        }
    }

    private func handleButtonUp(buttonMask: UInt8, event: NSEvent, fallback: () -> Void) {
        guard (activeButtonMask & buttonMask) != 0 else { fallback(); return }
        activeButtonMask &= ~buttonMask
        clearPendingHover()
        if usesAbsolutePointer, let point = normalizedPoint(for: event.locationInWindow, clamp: true) {
            hidControl?.releaseAbsolute(buttonMask: buttonMask, x: point.x, y: point.y)
        } else {
            hidControl?.releaseRelative(buttonMask: buttonMask)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard pointerForwarding, hidStatus?.relativePointerReady == true else {
            super.scrollWheel(with: event)
            return
        }
        if event.phase == .began {
            scrollRemainderX = 0
            scrollRemainderY = 0
        }
        let ticksY: Int
        let ticksX: Int
        if event.hasPreciseScrollingDeltas {
            scrollRemainderY += event.scrollingDeltaY
            scrollRemainderX += event.scrollingDeltaX
            ticksY = Int((scrollRemainderY / Self.preciseScrollUnit).rounded(.towardZero))
            ticksX = Int((scrollRemainderX / Self.preciseScrollUnit).rounded(.towardZero))
            scrollRemainderY -= CGFloat(ticksY) * Self.preciseScrollUnit
            scrollRemainderX -= CGFloat(ticksX) * Self.preciseScrollUnit
        } else {
            ticksY = Int(event.scrollingDeltaY.rounded())
            ticksX = Int(event.scrollingDeltaX.rounded())
        }
        if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
            scrollRemainderX = 0
            scrollRemainderY = 0
        }
        let clampedY = max(-10, min(10, ticksY))
        let clampedX = max(-10, min(10, ticksX))
        guard clampedY != 0 || clampedX != 0 else { return }
        hidControl?.sendScroll(verticalTicks: clampedY, horizontalTicks: clampedX)
    }

    // MARK: - Keyboard Events

    override var mouseDownCanMoveWindow: Bool { !pointerForwarding }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, window?.styleMask.contains(.fullScreen) == true {
            window?.windowController?.cancelOperation(nil)
            return
        }
        guard keyboardForwarding, let command = MirrorKeyboardEvent(event).command else {
            if event.keyCode == 53 {
                window?.windowController?.cancelOperation(nil)
            } else {
                super.keyDown(with: event)
            }
            return
        }
        forwardKeyboardCommand(command)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard keyboardForwarding, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command),
           let key = event.charactersIgnoringModifiers?.lowercased(),
           ["a", "c", "x", "v", "z"].contains(key)
        {
            if let command = MirrorKeyboardEvent(event).command {
                forwardKeyboardCommand(command)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func forwardKeyboardCommand(_ command: MirrorKeyboardCommand) {
        switch command {
        case .key(let name, let modifiers):
            _ = hidControl?.sendKey(name, modifiers: modifiers)
        case .text(let text, let modifiers):
            _ = hidControl?.sendText(text, modifiers: modifiers)
        }
    }

    // MARK: - Coordinate & Hover Helpers

    private func normalizedPoint(for windowPoint: NSPoint, clamp: Bool) -> CGPoint? {
        let local = convert(windowPoint, from: nil)
        guard let layout = MirrorControlLayout(videoSize: videoSize, bounds: bounds) else { return nil }
        return layout.normalizedPoint(local, clamp: clamp)
    }

    private func clearPendingHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        pendingHoverPoint = nil
    }

    private func submitAbsoluteHover(_ point: CGPoint, immediate: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if immediate || (now - lastHoverSentAt) >= Self.hoverInterval {
            clearPendingHover()
            lastHoverSentAt = now
            hidControl?.moveAbsolute(x: point.x, y: point.y)
            return
        }
        pendingHoverPoint = point
        guard hoverTimer == nil else { return }
        let remaining = max(0.005, Self.hoverInterval - (now - lastHoverSentAt))
        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.hoverTimer = nil
            guard self.pointerForwarding, self.usesAbsolutePointer, let target = self.pendingHoverPoint else {
                self.pendingHoverPoint = nil
                return
            }
            self.pendingHoverPoint = nil
            self.lastHoverSentAt = ProcessInfo.processInfo.systemUptime
            self.hidControl?.moveAbsolute(x: target.x, y: target.y)
        }
        hoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

/// A graphite bezel with an integrated top status bar; full screen stays edge-to-edge.
final class MirrorFrameView: NSView {
    static let borderWidth: CGFloat = 5
    static let topBarHeight: CGFloat = MirrorTopBarView.height
    static let cornerRadius: CGFloat = 16
    static let innerCornerRadius: CGFloat = cornerRadius - borderWidth

    let topBar = MirrorTopBarView()
    let videoView = MirrorVideoView()

    var isFullScreen = false {
        didSet {
            topBar.isHidden = isFullScreen
            needsLayout = true
        }
    }

    var contentInset: CGFloat { isFullScreen ? 0 : Self.borderWidth }
    var topChromeInset: CGFloat { isFullScreen ? 0 : Self.topBarHeight }
    var horizontalChrome: CGFloat { isFullScreen ? 0 : Self.borderWidth * 2 }
    var verticalChrome: CGFloat { isFullScreen ? 0 : Self.topBarHeight + Self.borderWidth }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        videoView.displayLayer.cornerCurve = .continuous
        videoView.displayLayer.masksToBounds = true
        addSubview(videoView)
        addSubview(topBar)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        let topH = topChromeInset
        topBar.frame = NSRect(x: 0, y: max(0, bounds.height - topH), width: bounds.width, height: topH)
        videoView.frame = NSRect(
            x: contentInset,
            y: contentInset,
            width: max(0, bounds.width - horizontalChrome),
            height: max(0, bounds.height - verticalChrome))
        layer?.cornerRadius = isFullScreen ? 0 : Self.cornerRadius
        videoView.displayLayer.cornerRadius = isFullScreen ? 0 : Self.innerCornerRadius
    }
}

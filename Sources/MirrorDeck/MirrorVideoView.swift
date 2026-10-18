import AppKit
import AVFoundation

/// A display-only surface; mouse drags move the Mac window, never the phone.
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
        setAccessibilityLabel("Mirrored device screen")
        setAccessibilityHelp("Escape exits full screen.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer { displayLayer }
    override var mouseDownCanMoveWindow: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            window?.windowController?.cancelOperation(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}

/// A thin, concentric bezel around the picture; full screen stays edge-to-edge.
final class MirrorFrameView: NSView {
    static let borderWidth: CGFloat = 5
    static let cornerRadius: CGFloat = 18
    let videoView = MirrorVideoView()

    var isFullScreen = false {
        didSet { needsLayout = true }
    }

    var contentInset: CGFloat { isFullScreen ? 0 : Self.borderWidth }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        videoView.displayLayer.cornerCurve = .continuous
        videoView.displayLayer.masksToBounds = true
        addSubview(videoView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        videoView.frame = bounds.insetBy(dx: contentInset, dy: contentInset)
        layer?.cornerRadius = isFullScreen ? 0 : Self.cornerRadius
        videoView.displayLayer.cornerRadius = isFullScreen ? 0 : Self.cornerRadius - contentInset
    }
}

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
        setAccessibilityRole(.image)
        setAccessibilityLabel("Mirrored device screen")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer { displayLayer }
    override var mouseDownCanMoveWindow: Bool { true }
}

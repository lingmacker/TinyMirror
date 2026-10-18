// Run from the repository root (no AirPlay library or phone required):
// swiftc -target "$(uname -m)-apple-macos26.0" -module-cache-path .build/module-cache Sources/MirrorDeck/{Localization,MirrorVideoView,MirrorWindowController}.swift scripts/TestResources.swift scripts/check-window.swift -o .build/check-window
// .build/check-window [--snapshots]
import AppKit
import AVFoundation

@main
struct WindowChecks {
    static func wait(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        assert(condition(), "Timed out waiting for the player state")
    }

    // shortcut: snapshots use synthetic content; use a phone for end-to-end playback checks.
    static func snapshot(_ name: String, window: NSWindow) throws {
        guard CommandLine.arguments.contains("--snapshots") else { return }
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let frameView = window.contentView!.superview!
            let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)!
            frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(
                to: URL(fileURLWithPath: ".build/window-\(name)-\(theme).png"))
        }
    }

    static func assertButtonsFollowPointer(in window: NSWindow) {
        let view = window.contentView!
        let area = view.trackingAreas.first { $0.owner === window.windowController }!
        if !window.styleMask.contains(.fullScreen) {
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                let button = window.standardWindowButton(type)!
                assert(area.rect.contains(view.convert(button.bounds, from: button)),
                       "Resizing must keep the hover region aligned with the native buttons")
            }
            assert(!area.rect.contains(NSPoint(x: view.bounds.midX, y: view.bounds.midY)))
        }
        let hovered = window.isVisible && area.rect.contains(view.convert(window.mouseLocationOutsideOfEventStream, from: nil))
        let visible = hovered || window.styleMask.contains(.fullScreen) || NSWorkspace.shared.isVoiceOverEnabled
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            assert(window.standardWindowButton(type)!.isHidden == !visible,
                   "Opening, moving, or restoring a window must refresh button visibility")
        }
    }

    static func assertPictureFrame(in window: NSWindow) {
        let frame = window.contentView as! MirrorFrameView
        let inset = frame.isFullScreen ? 0 : MirrorFrameView.borderWidth
        assert(frame.videoView.frame == frame.bounds.insetBy(dx: inset, dy: inset),
               "The border must have equal width on every edge")
        assert(frame.layer!.cornerRadius == (frame.isFullScreen ? 0 : MirrorFrameView.cornerRadius))
        assert(frame.videoView.displayLayer.cornerRadius == (frame.isFullScreen ? 0 : MirrorFrameView.cornerRadius - inset))
    }

    static func assertIdleWindow(in window: NSWindow) {
        assert(window.frame.size == NSSize(width: 370, height: 730),
               "An idle mirror must restore the default phone-sized window")
        let picture = (window.contentView as! MirrorFrameView).videoView.bounds
        assert(abs(picture.width / picture.height - 9.0 / 18) < 0.001,
               "The idle picture must use a 9:18 portrait ratio")
    }

    static func previewImage(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(starting: NSColor(red: 0.08, green: 0.13, blue: 0.34, alpha: 1),
                   ending: NSColor(red: 0.12, green: 0.53, blue: 0.65, alpha: 1))!
            .draw(in: NSRect(origin: .zero, size: size), angle: -65)
        ("MirrorDeck\nLayout preview" as NSString).draw(
            in: NSRect(x: 28, y: size.height / 2, width: size.width - 56, height: 64),
            withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .medium), .foregroundColor: NSColor.white])
        image.unlockFocus()
        return image
    }

    static func enqueueFirstFrame(on layer: AVSampleBufferDisplayLayer) {
        var pixelBuffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                                        nil, &pixelBuffer) == kCVReturnSuccess)
        CVPixelBufferLockBaseAddress(pixelBuffer!, [])
        memset(CVPixelBufferGetBaseAddress(pixelBuffer!), 128,
               CVPixelBufferGetBytesPerRow(pixelBuffer!) * 64)
        CVPixelBufferUnlockBaseAddress(pixelBuffer!, [])
        var format: CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer!,
            formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer!, formatDescription: format!,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        layer.sampleBufferRenderer.enqueue(sample!)
    }

    static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let controller = MirrorWindowController()
        let window = controller.window!
        let frameView = window.contentView as! MirrorFrameView
        assertPictureFrame(in: window)
        assertIdleWindow(in: window)
        assert(!window.isOpaque && window.hasShadow)
        assert(controller.windowWillResize(window, to: NSSize(width: 450, height: 620)) == NSSize(width: 450, height: 620))
        let screen = NSScreen.main!.visibleFrame
        assert(window.styleMask.contains([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]))
        assert(window.titlebarAppearsTransparent && window.titleVisibility == .hidden)
        assert(window.toolbar == nil && window.collectionBehavior.contains(.fullScreenPrimary))
        assert(controller.videoView.mouseDownCanMoveWindow && controller.videoView.acceptsFirstResponder)
        assert(controller.videoView.displayLayer.videoGravity == .resizeAspect)

        assert(controller.videoView.subviews.count == 1 && controller.videoView.subviews.first is NSBox,
               "Only the waiting view may overlay the picture")
        controller.isAlwaysOnTop = true
        assert(window.level == .floating)
        controller.isAlwaysOnTop = false
        assert(window.level == .normal)
        let windowButtons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map {
            window.standardWindowButton($0)!
        }
        let usingVoiceOver = NSWorkspace.shared.isVoiceOverEnabled
        assert(windowButtons.allSatisfy { $0.isHidden == !usingVoiceOver },
               "Window buttons must start hidden unless VoiceOver needs them")
        let area = frameView.trackingAreas.first { $0.owner === controller }!
        assert(!area.options.contains(.inVisibleRect), "Do not use the entire picture as the hover region")
        assert(area.rect.width <= 120 && area.rect.height <= 48 && !area.rect.isEmpty,
               "The hover region must stay close to the native buttons")
        for button in windowButtons {
            assert(area.rect.contains(frameView.convert(button.bounds, from: button)),
                   "All three native buttons must remain inside the hover region")
        }
        let canvasCenter = NSPoint(x: frameView.bounds.midX, y: frameView.bounds.midY)
        assert(!area.rect.contains(canvasCenter), "Hovering the picture must not reveal the buttons")
        let canvasEntered = NSEvent.enterExitEvent(
            with: .mouseEntered, location: frameView.convert(canvasCenter, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, trackingNumber: 0, userData: nil)!
        controller.mouseEntered(with: canvasEntered)
        assert(windowButtons.allSatisfy { $0.isHidden == !usingVoiceOver })
        let buttonCenter = NSPoint(x: area.rect.midX, y: area.rect.midY)
        let entered = NSEvent.enterExitEvent(
            with: .mouseEntered, location: frameView.convert(buttonCenter, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil)!
        let exited = NSEvent.enterExitEvent(
            with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1,
            trackingNumber: 0, userData: nil)!
        controller.mouseEntered(with: entered)
        assert(windowButtons.allSatisfy { !$0.isHidden }, "Hovering must reveal all three native buttons")
        controller.mouseExited(with: exited)
        assert(windowButtons.allSatisfy { $0.isHidden == !usingVoiceOver }, "Leaving must hide the buttons")
        assert(frameView.trackingAreas.contains {
            $0.owner === controller && $0.options.contains([.mouseEnteredAndExited, .activeAlways])
        }, "Track only the native window-button region")

        controller.setReceiverState(name: "Alex’s Mac (MirrorDeck)", isRunning: true)
        controller.present()
        assertButtonsFollowPointer(in: window)
        let awayX = NSEvent.mouseLocation.x < screen.midX ? screen.maxX - window.frame.width : screen.minX
        window.setFrameOrigin(NSPoint(x: awayX, y: window.frame.minY))
        assertButtonsFollowPointer(in: window)
        assert(controller.playbackState == .waiting)
        let waiting = controller.videoView.subviews.first as! NSBox
        let labels = (waiting.contentView!.subviews.first as! NSStackView).arrangedSubviews.compactMap { $0 as? NSTextField }
        let language = Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: Locale.preferredLanguages + ["en"]).first!
        let chinese = language == "zh-Hans"
        assert(labels[0].stringValue == (chinese ? "准备投屏" : "Ready to mirror"))
        assert(labels[1].stringValue.contains("Alex’s Mac (MirrorDeck)"), "Device names must survive localized formatting")
        print("UI localization: \(language)")
        window.contentView?.layoutSubtreeIfNeeded()
        assert(abs(labels[1].alignmentRect(forFrame: labels[1].frame).width - min(280, controller.videoView.bounds.width - 48)) < 1,
               "Localized instructions must use the available width instead of collapsing into a narrow column")
        try snapshot("waiting", window: window)
        controller.setReceiverState(name: "Alex’s Mac (MirrorDeck)", isRunning: false)
        assert(controller.playbackState == .unavailable)
        try snapshot("unavailable", window: window)
        controller.setReceiverState(name: "Alex’s Mac (MirrorDeck)", isRunning: true)
        controller.setDeviceName("Alex’s iPhone — a long device name")
        controller.setVideoDimensions(width: 1179, height: 2556)
        assert(controller.playbackState == .connecting, "Dimensions alone must not hide the waiting state")
        try snapshot("connecting", window: window)
        enqueueFirstFrame(on: controller.videoView.displayLayer)
        wait { controller.playbackState == .mirroring }
        assert(controller.videoView.subviews.allSatisfy(\.isHidden), "Live playback must not have any overlay UI")

        // Synthetic, labeled picture for layout captures: not a phone screenshot.
        let preview = NSImageView(frame: controller.videoView.bounds)
        preview.autoresizingMask = [.width, .height]
        preview.imageScaling = .scaleAxesIndependently
        controller.videoView.addSubview(preview, positioned: .below, relativeTo: controller.videoView.subviews.first)

        for (name, width, height) in [
            ("portrait", 1179, 2556), ("landscape", 2556, 1179),
            ("tablet", 2048, 2732), ("ultrawide", 5120, 1440)
        ] {
            controller.setVideoDimensions(width: width, height: height)
            window.contentView?.layoutSubtreeIfNeeded()
            let content = controller.videoView.bounds
            assertPictureFrame(in: window)
            let border = MirrorFrameView.borderWidth * 2
            for proposed in [NSSize(width: window.frame.width + 100, height: window.frame.height),
                             NSSize(width: window.frame.width, height: window.frame.height + 100), .zero] {
                let resized = controller.windowWillResize(window, to: proposed)
                assert(abs((resized.width - border) / (resized.height - border) - CGFloat(width) / CGFloat(height)) < 0.0001)
                assert(resized.width >= window.minSize.width - 0.01 && resized.height >= window.minSize.height - 0.01)
            }
            preview.image = previewImage(size: content.size)
            assert(abs(content.width / content.height - CGFloat(width) / CGFloat(height)) < 0.01,
                   "Picture aspect ratio changed: \(name)")
            assert(screen.insetBy(dx: -1, dy: -1).contains(window.frame), "Window escaped the display")
            assertButtonsFollowPointer(in: window)
            print("\(name): window \(window.frame.size), picture \(content.size)")
            try snapshot(name, window: window)
        }

        controller.setVideoDimensions(width: 1179, height: 2556)
        window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        assertPictureFrame(in: window)
        preview.image = previewImage(size: controller.videoView.bounds.size)
        try snapshot("compact", window: window)
        window.makeFirstResponder(controller.videoView)
        let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        window.sendEvent(escape)
        assert(window.isVisible, "Escape outside full screen must not dismiss the mirror")

        let frame = window.frame
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        assert(frameView.isFullScreen)
        assertPictureFrame(in: window)
        assert(controller.windowWillResize(window, to: screen.size) == screen.size)
        assert(windowButtons.allSatisfy { !$0.isHidden }, "Full screen must retain its native title-bar buttons")
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        assert(!frameView.isFullScreen)
        assertPictureFrame(in: window)
        assertButtonsFollowPointer(in: window)
        assert(window.frame == frame, "Unchanged video must preserve the restored window size after full screen")
        controller.setVideoDimensions(width: 0, height: 100)
        controller.setVideoDimensions(width: 100, height: -1)
        assert(window.frame == frame)
        preview.removeFromSuperview()
        controller.videoView.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        wait { controller.playbackState == .connecting }
        controller.setDeviceName(nil)
        assert(controller.playbackState == .waiting)
        assertIdleWindow(in: window)
        controller.dismiss()
        controller.present()
        assertIdleWindow(in: window)
        controller.setDeviceName("Landscape iPhone")
        controller.setVideoDimensions(width: 2556, height: 1179)
        controller.setDeviceName(nil)
        assertIdleWindow(in: window)
        controller.setDeviceName("Full-screen iPhone")
        controller.setVideoDimensions(width: 1179, height: 2556)
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        let fullScreenFrame = window.frame
        controller.setDeviceName(nil)
        assert(window.frame == fullScreenFrame, "Disconnecting must not resize a full-screen window")
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        assertIdleWindow(in: window)
        assertPictureFrame(in: window)
        controller.setDeviceName("Another iPhone")
        assert(controller.playbackState == .connecting, "A new device must never show a previous device’s frame")
        controller.mouseEntered(with: entered)
        window.close()
        assert(!window.isVisible)
        assert(windowButtons.allSatisfy { $0.isHidden == !usingVoiceOver })
        controller.present()
        assert(window.isVisible)
        assertButtonsFollowPointer(in: window)
        controller.mouseEntered(with: entered)
        controller.dismiss()
        assert(windowButtons.allSatisfy { $0.isHidden == !usingVoiceOver })
        controller.present()
        assert(window.isVisible)
        assertButtonsFollowPointer(in: window)
        controller.dismiss()
        print("Immersive window checks passed")
    }
}

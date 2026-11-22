import AppKit
import Foundation

// Standalone window checks use fallback labels and never open a window.
extension Bundle { static let module = Bundle.main }

@main
private enum WindowBehaviorChecks {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let controller = MirrorWindowController()
        let window = controller.window!
        let hChrome = MirrorFrameView.borderWidth * 2
        let vChrome = MirrorFrameView.topBarHeight + MirrorFrameView.borderWidth
        precondition(controller.videoView.hidControl == nil && controller.videoView.mouseDownCanMoveWindow)
        precondition(!controller.topBar.isHidden && !controller.topBar.homeButton.isEnabled)
        precondition(window.standardWindowButton(.closeButton)?.isHidden == false)
        controller.setDeviceName("Test iPhone")
        controller.setVideoDimensions(width: 720, height: 1280)
        precondition(controller.videoView.videoSize == CGSize(width: 720, height: 1280))
        let first = window.frame
        let height = max(window.minSize.height - vChrome, (first.height - vChrome) * 0.85)
        let manual = NSRect(origin: first.origin,
                            size: NSSize(width: height * 720 / 1280 + hChrome, height: height + vChrome))
        window.setFrame(manual, display: false)
        let chosen = window.frame
        let minimum = window.minSize
        controller.setVideoDimensions(width: 1440, height: 2560)
        precondition(window.frame == chosen, "Adaptive resolution reset the user's chosen window frame")
        precondition(controller.videoView.videoSize == CGSize(width: 1440, height: 2560),
                     "Same-direction resolution updates must still update videoSize for pointer mapping")
        for size in [(828, 1792), (1080, 1920), (1170, 2532), (640, 1136), (1080, 1080)] {
            controller.setVideoDimensions(width: size.0, height: size.1)
            precondition(window.frame == chosen, "Same-direction content changed the outer window")
            precondition(window.minSize == minimum)
        }
        controller.setVideoDimensions(width: 0, height: 1280)
        controller.setVideoDimensions(width: 720, height: -1)
        precondition(window.frame == chosen)
        let resized = controller.windowWillResize(window, to: NSSize(width: chosen.width + 60, height: chosen.height + 60))
        precondition(abs((resized.width - hChrome) / (resized.height - vChrome) - 720.0 / 1280) < 0.001)
        print("PASS adaptive resolution, portrait aspect changes, square/invalid content, and resize constraints preserve the canvas")

        controller.setVideoDimensions(width: 1280, height: 720)
        let landscape = window.frame
        precondition(landscape.width > landscape.height)
        precondition(abs((landscape.width - hChrome) - (landscape.height - vChrome) * 1280 / 720) < 2,
                     "Rotated picture has the wrong aspect: \(landscape), minSize: \(window.minSize)")
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let expectedWidth = min(max(chosen.width - hChrome, chosen.height - vChrome),
                                screen.width - hChrome, (screen.height - vChrome) * 1280 / 720) + hChrome
        precondition(abs(landscape.width - expectedWidth) < 2,
                     "Rotation must preserve the user's selected scale within the display bounds")
        controller.setVideoDimensions(width: 1920, height: 1080)
        precondition(window.frame == landscape)
        controller.setVideoDimensions(width: 1080, height: 1080)
        precondition(window.frame == landscape)
        print("PASS rotation fits the frame and landscape/square content does not cause resizing")

        controller.setVideoDimensions(width: 720, height: 1280)
        let portrait = window.frame
        precondition(abs((portrait.height - vChrome) - (landscape.width - hChrome)) < 2)
        precondition(abs((portrait.width - hChrome) - (portrait.height - vChrome) * 720 / 1280) < 2)
        let note = Notification(name: NSWindow.willEnterFullScreenNotification, object: window)
        controller.windowWillEnterFullScreen(note)
        precondition(controller.topBar.isHidden, "Top bar must hide in full screen")
        controller.setVideoDimensions(width: 1280, height: 720)
        controller.setVideoDimensions(width: 1080, height: 1920)
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        precondition(!controller.topBar.isHidden)
        precondition(window.frame == portrait, "A full-screen round trip reset the restored portrait window")
        print("PASS full-screen content changes restore the user's window frame")

        controller.windowWillEnterFullScreen(note)
        controller.setVideoDimensions(width: 1920, height: 1080)
        precondition(window.frame == portrait)
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        precondition(window.frame.width > window.frame.height)
        controller.windowWillEnterFullScreen(note)
        controller.setVideoDimensions(width: 720, height: 1280)
        controller.windowDidFailToEnterFullScreen(window)
        precondition(window.frame.height > window.frame.width)
        print("PASS full-screen orientation changes and failed-entry recovery apply the pending direction")

        controller.windowWillEnterFullScreen(note)
        controller.setDeviceName(nil)
        controller.setDeviceName("Reconnected iPhone")
        controller.setVideoDimensions(width: 828, height: 1792)
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        precondition(abs((window.frame.width - hChrome) - (window.frame.height - vChrome) * 828 / 1792) < 2,
                     "A new session inside full screen must adopt its own initial canvas")
        print("PASS reconnecting inside full screen adopts the new session's canvas")

        controller.windowWillEnterFullScreen(note)
        controller.setDeviceName(nil)
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        let idle = window.frame
        precondition(abs(idle.width - MirrorWindowController.idleWindowSize.width) < 1
                     && abs(idle.height - MirrorWindowController.idleWindowSize.height) < 1)
        controller.setDeviceName("Test iPhone")
        controller.setVideoDimensions(width: 1920, height: 1080)
        precondition(window.frame.width > window.frame.height)
        precondition(!window.isVisible)
        window.close()
        print("PASS disconnect resets the idle canvas and reconnect adopts the new orientation; no window was displayed")
    }
}

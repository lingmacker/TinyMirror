// Run from the repository root; this temporarily opens native full-screen Spaces.
// swiftc -target "$(uname -m)-apple-macos26.0" -module-cache-path .build/module-cache Sources/MirrorDeck/{Localization,MirrorVideoView,MirrorWindowController,StatusBarController,Settings}.swift scripts/TestResources.swift scripts/check-window-transitions.swift -o .build/check-window-transitions
// .build/check-window-transitions
import AppKit
import Darwin

@main
struct WindowTransitionChecks {
    static func require(_ condition: Bool, _ message: String) {
        if !condition {
            fputs("FAIL: \(message)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    static func pump(until condition: () -> Bool, timeout: TimeInterval = 6, context: String = "settling") {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01),
                                           inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
        require(condition(), "Native window transition timed out: \(context)")
    }

    static func settle() {
        let end = Date().addingTimeInterval(0.3)
        pump(until: { Date() >= end }, timeout: 1)
    }

    static func requireSize(_ actual: NSSize, _ expected: NSSize) {
        require(abs(actual.width - expected.width) < 2 && abs(actual.height - expected.height) < 2,
                "Restored size \(actual) does not match \(expected)")
    }

    static func main() {
        // A blocked main thread must not leave the automated check stuck in a Space.
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
            fputs("FAIL: Window transition checks exceeded 45 seconds\n", stderr)
            exit(EXIT_FAILURE)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let statusBar = StatusBarController()
        let controller = MirrorWindowController()
        let window = controller.window!
        let frameView = window.contentView as! MirrorFrameView
        controller.isAlwaysOnTop = true

        for (name, width, height) in [
            ("idle", 0, 0), ("portrait", 1179, 2556), ("landscape", 2556, 1179),
            ("rotate", 1179, 2556), ("disconnect", 1179, 2556),
            ("stop", 1179, 2556), ("stop-entering", 1179, 2556), ("stop-exiting", 1179, 2556)
        ] {
            controller.setDeviceName(width == 0 ? nil : "Window transition test phone")
            if width > 0 { controller.setVideoDimensions(width: width, height: height) }
            controller.present()
            pump(until: { app.isActive && window.isKeyWindow }, context: "\(name) activation")
            settle()
            let originalSize = window.frame.size

            if name == "idle" || name == "portrait" || name == "landscape" {
                window.zoom(nil)
                settle()
                window.zoom(nil)
                settle()
                requireSize(window.frame.size, originalSize)
            }

            var entered = false
            var exited = false
            let enter = NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in entered = true }
            let leave = NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in exited = true }
            var stopOnEntry: NSObjectProtocol?
            if name == "stop-entering" {
                stopOnEntry = NotificationCenter.default.addObserver(
                    forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { _ in
                        DispatchQueue.main.async {
                            controller.dismiss()
                            controller.setDeviceName(nil)
                        }
                    }
            }
            defer {
                NotificationCenter.default.removeObserver(enter)
                NotificationCenter.default.removeObserver(leave)
                if let stopOnEntry { NotificationCenter.default.removeObserver(stopOnEntry) }
            }
            func verifyStopped() {
                pump(until: { exited && !window.isVisible }, context: "\(name) dismiss")
                require(!window.styleMask.contains(.fullScreen) && !frameView.isFullScreen,
                        "Stopping must close the native full-screen Space before hiding")
                requireSize(window.frame.size, NSSize(width: 370, height: 730))
                controller.present()
                pump(until: { app.isActive && window.isKeyWindow }, context: "\(name) reopen")
                require(window.isVisible, "The receiver window must remain reusable after stopping")
                print("Native full-screen stop passed: \(name)")
            }
            window.toggleFullScreen(nil)
            if name == "stop-entering" {
                verifyStopped()
                continue
            }
            pump(until: { entered }, context: "\(name) enter full screen")
            settle()
            require(window.styleMask.contains(.fullScreen) && frameView.isFullScreen,
                    "Native full screen did not complete")
            require(window.level == .normal, "Full screen must not keep the floating level")
            if name == "stop" || name == "stop-exiting" {
                if name == "stop-exiting" { window.toggleFullScreen(nil) }
                controller.dismiss()
                controller.dismiss()
                controller.setDeviceName(nil)
                verifyStopped()
                continue
            }
            let fullScreenFrame = window.frame
            if name == "rotate" {
                controller.setVideoDimensions(width: 2556, height: 1179)
            } else if name == "disconnect" {
                controller.setDeviceName(nil)
            }
            require(window.frame == fullScreenFrame, "Video state must not resize the full-screen window")

            let escape = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53)!
            app.sendEvent(escape)
            pump(until: { exited }, context: "\(name) Escape exit")
            settle()
            require(!window.styleMask.contains(.fullScreen) && !frameView.isFullScreen,
                    "Escape failed to leave native full screen")
            require(window.level == .floating, "Leaving full screen must restore always-on-top")
            if name == "disconnect" {
                requireSize(window.frame.size, NSSize(width: 370, height: 730))
            } else if name == "rotate" {
                let picture = controller.videoView.bounds
                require(abs(picture.width / picture.height - 2556.0 / 1179) < 0.01,
                        "Leaving full screen must apply the updated video aspect ratio")
            } else {
                requireSize(window.frame.size, originalSize)
            }
            print("Native zoom/full-screen restore passed: \(name)")
            fflush(stdout)
        }
        controller.dismiss()
        withExtendedLifetime(statusBar) {}
        print("Native window transition checks passed")
    }
}

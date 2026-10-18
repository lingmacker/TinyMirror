// Run from the repository root (no AirPlay library or phone required):
// swiftc -module-cache-path .build/module-cache Sources/MirrorDeck/Mirror{VideoView,WindowController}.swift scripts/check-window.swift -o .build/check-window
// .build/check-window [--snapshots]
import AppKit

@main
struct WindowChecks {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = MirrorWindowController()
        let window = controller.window!
        let screen = NSScreen.main!.visibleFrame
        assert(window.styleMask.contains([.titled, .closable, .miniaturizable, .resizable]))
        assert(window.collectionBehavior.contains(.fullScreenPrimary))
        assert(controller.videoView.mouseDownCanMoveWindow)
        assert(!controller.videoView.acceptsFirstResponder)

        let pin = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "KeepOnTop" }!.view as! NSButton
        var pinned: Bool?
        controller.onToggleAlwaysOnTop = { pinned = $0 }
        pin.performClick(nil)
        assert(pinned == true && controller.isAlwaysOnTop && window.level == .floating)
        controller.isAlwaysOnTop = false
        assert(pin.state == .off && window.level == .normal)
        assert(window.standardWindowButton(.closeButton) != nil)

        for (name, width, height) in [
            ("portrait", 1179, 2556), ("landscape", 2556, 1179),
            ("tablet", 2048, 2732), ("ultrawide", 5120, 1440)
        ] {
            controller.setDeviceName("Alex’s iPhone — a long device name")
            controller.setVideoDimensions(width: width, height: height)
            controller.present()
            window.contentView?.layoutSubtreeIfNeeded()
            let content = controller.videoView.bounds
            assert(abs(content.width / content.height - CGFloat(width) / CGFloat(height)) < 0.01,
                   "Picture aspect ratio changed: \(name)")
            assert(screen.insetBy(dx: -1, dy: -1).contains(window.frame),
                   "Window escaped the display: \(name)")
            assert(window.contentMinSize.width <= content.width + 1)
            print("\(name): window \(window.frame.size), video \(content.size)")

            if CommandLine.arguments.contains("--snapshots") {
                for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    window.appearance = NSAppearance(named: appearance)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                    let frameView = window.contentView!.superview!
                    let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)!
                    frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(
                        to: URL(fileURLWithPath: ".build/window-\(name)-\(theme).png"))
                }
            }
        }

        let frame = window.frame
        controller.setVideoDimensions(width: 0, height: 100)
        controller.setVideoDimensions(width: 100, height: -1)
        assert(window.frame == frame, "Invalid dimensions must not resize the window")
        window.close()
        assert(!window.isVisible)
        controller.present()
        assert(window.isVisible, "A closed mirror must be reopenable")
        controller.dismiss()
        controller.present()
        assert(window.isVisible, "An immediate reconnect must not be hidden by an old animation")
        controller.dismiss()
        print("Window checks passed")
    }
}

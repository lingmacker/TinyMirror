// Run from the repository root (no AirPlay library or phone required):
// swiftc -target "$(uname -m)-apple-macos26.0" -module-cache-path .build/module-cache Sources/MirrorDeck/{Localization,MirrorVideoView,MirrorWindowController,StatusBarController,Settings}.swift scripts/TestResources.swift scripts/check-shortcuts.swift -o .build/check-shortcuts
// .build/check-shortcuts
import AppKit

@main
struct ShortcutChecks {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let statusBar = StatusBarController()
        let controller = MirrorWindowController()
        let window = controller.window!
        var toggles: [Bool] = []
        var shows = 0
        var quits = 0
        statusBar.onToggleAlwaysOnTop = { on in
            toggles.append(on)
            controller.isAlwaysOnTop = on
            statusBar.setAlwaysOnTop(on)
        }
        statusBar.onShowWindow = {
            shows += 1
            controller.present()
        }
        statusBar.onQuit = { quits += 1 }
        statusBar.setAlwaysOnTop(true)
        controller.isAlwaysOnTop = true
        controller.present()
        let deadline = Date().addingTimeInterval(3)
        while (!app.isActive || !window.isKeyWindow) && Date() < deadline {
            if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01),
                                         inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
        }
        assert(app.isActive && window.isKeyWindow,
               "The mirror must be active (active: \(app.isActive), key: \(window.isKeyWindow))")
        assert(window.firstResponder === controller.videoView)

        func press(_ key: String, code: UInt16) {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: code)!
            app.sendEvent(event)
        }

        press("t", code: 17)
        assert(toggles == [false], "Command-T must invoke the menu action while the mirror is active")
        assert(window.level == .normal)
        let menu = app.mainMenu!.items.first!.submenu!
        let onTopItem = menu.items.first { $0.keyEquivalent == "t" }!
        assert(onTopItem.state == .off)
        press("t", code: 17)
        assert(toggles == [false, true] && window.level == .floating && onTopItem.state == .on)
        press("m", code: 46)
        assert(shows == 1 && window.isVisible && !window.isMiniaturized,
               "Command-M must show the mirror, not minimize it")
        press("q", code: 12)
        assert(quits == 1, "Command-Q must invoke the menu's quit callback")
        controller.dismiss()
        print("Active mirror menu shortcut checks passed")
    }
}

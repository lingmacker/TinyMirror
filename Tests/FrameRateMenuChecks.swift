import AppKit
import CMirrorBridge

extension Bundle { static let module = Bundle.main }

@main
private enum FrameRateMenuChecks {
    static func main() {
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? ""
        precondition(home.hasPrefix(FileManager.default.currentDirectoryPath + "/.build/"), "Run with an isolated test home")
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "frameRate")
        precondition(Settings.frameRate == .standard)
        defaults.set(120, forKey: "frameRate")
        precondition(Settings.frameRate == .standard, "Invalid stored FPS must fall back to 30")
        Settings.frameRate = .smooth
        precondition(defaults.integer(forKey: "frameRate") == 60 && Settings.frameRate == .smooth)
        defaults.removeObject(forKey: "frameRate")
        defaults.set(true, forKey: "didWarnIconBehindNotch")
        Settings.receiverName = "No-network menu check"

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let delegate = AppDelegate()
        let notification = Notification(name: NSApplication.didFinishLaunchingNotification)
        delegate.applicationDidFinishLaunching(notification)
        defer { delegate.applicationWillTerminate(notification) }
        precondition(mb_test_frame_rate() == 30)

        let menu = NSApp.mainMenu!.items[0].submenu!
        let quitTitle = String(localized: "Quit", bundle: .appLocalization)
        precondition(menu.items.contains { $0.title == quitTitle && $0.keyEquivalent == "q" })
        let title = String(localized: "Frame Rate", bundle: .appLocalization)
        let frameRateMenu = menu.items.first { $0.title == title }!.submenu!
        let fpsItems = frameRateMenu.items.filter { $0.action != nil }
        precondition(fpsItems.map(\.tag) == [30, 60])
        let fps30 = fpsItems[0], fps60 = fpsItems[1]
        precondition(fps30.state == .on && fps60.state == .off)
        func choose(_ item: NSMenuItem) {
            NSApp.sendAction(item.action!, to: item.target, from: item)
        }
        choose(fps60)
        precondition(Settings.frameRate == .smooth && mb_test_frame_rate() == 60)
        precondition(fps30.state == .off && fps60.state == .on)
        let starts = mb_test_start_count()
        choose(fps60)
        precondition(mb_test_start_count() == starts, "Selecting the current FPS must not restart")

        func event(_ event: mb_event_t) {
            let receiver = AirPlayReceiver.shared
            let handler = receiver.onEvent
            var delivered = false
            receiver.onEvent = { value in handler?(value); delivered = true }
            defer { receiver.onEvent = handler }
            mb_test_event(Int32(event.rawValue), 0, nil)
            let deadline = Date().addingTimeInterval(2)
            while !delivered, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(delivered, "Receiver did not deliver the queued menu event")
        }
        event(MB_EVENT_CONN_INIT)
        precondition(fpsItems.allSatisfy { !$0.isEnabled })
        let resolutionTitle = String(localized: "Resolution", bundle: .appLocalization)
        let resolutionMenu = menu.items.first { $0.title == resolutionTitle }!.submenu!
        precondition(resolutionMenu.items.filter { $0.action != nil }.allSatisfy { !$0.isEnabled })
        choose(fps30)
        precondition(Settings.frameRate == .smooth && mb_test_start_count() == starts)
        event(MB_EVENT_CONN_DESTROY)
        precondition(fpsItems.allSatisfy(\.isEnabled))
        precondition(resolutionMenu.items.filter { $0.action != nil }.allSatisfy(\.isEnabled))
        choose(fps30)
        precondition(Settings.frameRate == .standard && mb_test_frame_rate() == 30)
        precondition(fps30.state == .on && fps60.state == .off)
        choose(fps60)
        AirPlayReceiver.shared.stop()
        let stoppedStarts = mb_test_start_count()
        choose(fps60)
        precondition(AirPlayReceiver.shared.isRunning && mb_test_start_count() == stoppedStarts + 1)
        precondition(mb_test_frame_rate() == 60)
        print("PASS FPS default/fallback/persistence, menu selection, receiver restart and connected-state guards; no network opened")
    }
}

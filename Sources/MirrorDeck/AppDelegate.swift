import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let receiver = AirPlayReceiver.shared
    private let pipeline = VideoPipeline()
    // Created after NSApplication.run() so the menu bar item can be placed.
    private lazy var statusBar = StatusBarController()
    private let windowController = MirrorWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        wireVideo()
        wireUI()
        startReceiver()
    }

    func applicationWillTerminate(_ notification: Notification) {
        receiver.stop()
    }

    private func wireVideo() {
        pipeline.displayLayer = windowController.videoView.displayLayer
        receiver.onVideo = { [pipeline] data, length, isH265 in
            guard !isH265 else { return } // H.265 not advertised; ignore defensively
            pipeline.handleAccessUnit(data, length)
        }
        pipeline.onDimensions = { [weak self] width, height in
            guard let self else { return }
            self.windowController.setVideoDimensions(width: width, height: height)
            if self.windowController.window?.isVisible != true {
                self.windowController.present()
            }
        }
        receiver.onEvent = { [weak self] event in
            self?.handleReceiverEvent(event)
        }
        receiver.onLog = { level, message in
            if level <= 6 { NSLog("[receiver] %@", message) }
        }
    }

    private func wireUI() {
        statusBar.onShowWindow = { [weak self] in self?.windowController.present() }
        statusBar.onQuit = { NSApp.terminate(nil) }
        statusBar.onToggleAlwaysOnTop = { [weak self] on in
            self?.setAlwaysOnTop(on)
        }
        windowController.onToggleAlwaysOnTop = { [weak self] on in
            self?.setAlwaysOnTop(on)
        }
        setAlwaysOnTop(Settings.alwaysOnTop)
    }

    private func setAlwaysOnTop(_ on: Bool) {
        Settings.alwaysOnTop = on
        windowController.isAlwaysOnTop = on
        statusBar.setAlwaysOnTop(on)
    }

    static let debugEnabled = ProcessInfo.processInfo.environment["MIRRORDECK_DEBUG"] == "1"

    private func startReceiver() {
        let name = Settings.receiverName
        if receiver.start(name: name, debug: AppDelegate.debugEnabled) {
            statusBar.setReceiverState("Visible as “\(name)”")
            NSLog("[MirrorDeck] receiver started, advertising as “%@”", name)
        } else {
            statusBar.setReceiverState("Receiver failed to start")
            NSLog("[MirrorDeck] RECEIVER FAILED TO START")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if AppDelegate.debugEnabled { self.statusBar.logPlacement() }
            if self.statusBar.isHiddenBehindNotch { self.warnIconHidden() }
        }

        if ProcessInfo.processInfo.environment["MIRRORDECK_PREVIEW"] == "1" {
            windowController.setDeviceName("Preview")
            windowController.setVideoDimensions(width: 1179, height: 2556)
            windowController.present()
        }
    }

    /// Shown once: an invisible menu bar item otherwise looks like a failed launch.
    private func warnIconHidden() {
        let key = "didWarnIconBehindNotch"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let alert = NSAlert()
        alert.messageText = "MirrorDeck's menu bar icon is hidden behind the notch"
        alert.informativeText = """
            MirrorDeck is running, but your menu bar is full, so macOS placed \
            its icon behind the camera notch where it cannot be seen or clicked.

            Quit or hide one or two other menu bar apps and it will appear. You \
            can then ⌘-drag it anywhere, and it will stay there.

            Mirroring works either way — pick this Mac from Screen Mirroring on \
            your iPhone and the window will open on its own.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func handleReceiverEvent(_ event: ReceiverEvent) {
        switch event {
        case .clientInfo(_, _, let name):
            let displayName = name.isEmpty ? "iPhone" : name
            statusBar.setClient(displayName)
            windowController.setDeviceName(displayName)
        case .disconnected:
            statusBar.setClient(nil)
            windowController.dismiss()
            pipeline.reset()
        case .videoFlush:
            pipeline.flush()
        case .connReset:
            pipeline.reset()
        default:
            break
        }
    }
}

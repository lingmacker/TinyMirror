import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let receiver = AirPlayReceiver.shared
    private let pipeline = VideoPipeline()
    // Created after NSApplication.run() so the menu bar item can be placed.
    private lazy var statusBar = StatusBarController()
    private let windowController = MirrorWindowController()
    private var clientConnected = false

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
            pipeline.handleAccessUnit(data, length, isH265: isH265)
        }
        pipeline.onDimensions = { [weak self] width, height, isH265 in
            guard let self else { return }
            self.statusBar.setVideoSize(width: width, height: height, isH265: isH265)
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
        statusBar.onResolutionChange = { [weak self] resolution in self?.setResolution(resolution) }
        statusBar.setResolution(Settings.resolution)
        setAlwaysOnTop(Settings.alwaysOnTop)
    }

    private func setAlwaysOnTop(_ on: Bool) {
        Settings.alwaysOnTop = on
        windowController.isAlwaysOnTop = on
        statusBar.setAlwaysOnTop(on)
    }

    private func setResolution(_ resolution: MirrorResolution) {
        guard !clientConnected else { return }
        guard resolution != Settings.resolution || !receiver.isRunning else { return }
        Settings.resolution = resolution
        statusBar.setResolution(resolution)
        receiver.stop()
        pipeline.reset()
        startReceiver()
    }

    static let debugEnabled = ProcessInfo.processInfo.environment["MIRRORDECK_DEBUG"] == "1"

    private func startReceiver() {
        let name = Settings.receiverName
        let started = receiver.start(name: name, resolution: Settings.resolution, debug: AppDelegate.debugEnabled)
        windowController.setReceiverState(name: name, isRunning: started)
        if started {
            statusBar.setReceiverState(String.localizedStringWithFormat(String(localized: "Visible as “%@”", bundle: .appLocalization), name))
            NSLog("[MirrorDeck] receiver started, advertising as “%@”", name)
        } else {
            statusBar.setReceiverState(String(localized: "Receiver failed to start", bundle: .appLocalization))
            NSLog("[MirrorDeck] RECEIVER FAILED TO START")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if AppDelegate.debugEnabled { self.statusBar.logPlacement() }
            if self.statusBar.isHiddenBehindNotch { self.warnIconHidden() }
        }

        if ProcessInfo.processInfo.environment["MIRRORDECK_PREVIEW"] == "1" {
            windowController.present()
        }
    }

    /// Shown once: an invisible menu bar item otherwise looks like a failed launch.
    private func warnIconHidden() {
        let key = "didWarnIconBehindNotch"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let alert = NSAlert()
        alert.messageText = String(localized: "MirrorDeck's menu bar icon is hidden behind the notch", bundle: .appLocalization)
        alert.informativeText = String(localized: "notch_warning_detail", bundle: .appLocalization)
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK", bundle: .appLocalization))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func handleReceiverEvent(_ event: ReceiverEvent) {
        switch event {
        case .connected:
            clientConnected = true
            statusBar.setResolutionEnabled(false)
        case .clientInfo(_, _, let name):
            let displayName = name.isEmpty ? "iPhone" : name
            clientConnected = true
            statusBar.setResolutionEnabled(false)
            statusBar.setClient(displayName)
            windowController.setDeviceName(displayName)
        case .disconnected:
            clientConnected = false
            statusBar.setResolutionEnabled(true)
            statusBar.setClient(nil)
            windowController.dismiss()
            windowController.setDeviceName(nil)
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

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let receiver = AirPlayReceiver.shared
    private let pipeline = VideoPipeline()
    // Created after NSApplication.run() so the menu bar item can be placed.
    private lazy var statusBar = StatusBarController()
    private let windowController = MirrorWindowController()
    private lazy var playback = MediaPlayback(displayLayer: windowController.videoView.displayLayer)
    private var clientConnected = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        wireMedia()
        wireUI()
        startReceiver()
        if ProcessInfo.processInfo.environment["TINYMIRROR_PREVIEW"] == "1" {
            windowController.present()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        receiver.stop()
        playback.reset()
    }

    private func wireMedia() {
        pipeline.onSampleBuffer = { [playback] sample, timestamp in
            playback.enqueueVideo(sample, timestamp: timestamp)
        }
        pipeline.onFlush = { [playback] removeImage in
            playback.flushVideo(removingDisplayedImage: removeImage)
        }
        receiver.onVideo = { [pipeline] data, length, isH265, timestamp in
            pipeline.handleAccessUnit(data, length, isH265: isH265, timestamp: timestamp)
        }
        receiver.onAudio = { [playback] data, length, ct, timestamp, position in
            playback.handleAudio(data, length, compressionType: ct, timestamp: timestamp, rtpTimestamp: position)
        }
        receiver.onAudioFormat = { [playback] ct, spf, usingScreen in
            playback.configureAudio(compressionType: ct, samplesPerFrame: spf, screenMirroring: usingScreen)
        }
        receiver.onAudioVolume = { [playback] volume in playback.setVolume(decibels: volume) }
        receiver.onAudioFlush = { [playback] in playback.flushAudio() }
        // Media teardown must precede new packets, not wait behind main-thread UI events.
        receiver.onMediaReset = { [pipeline, playback] in
            pipeline.reset()
            playback.reset()
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
        statusBar.onStopMirroring = { [weak self] in self?.stopMirroring() }
        statusBar.onQuit = { NSApp.terminate(nil) }
        statusBar.onToggleAlwaysOnTop = { [weak self] on in
            self?.setAlwaysOnTop(on)
        }
        statusBar.onResolutionChange = { [weak self] resolution in self?.setResolution(resolution) }
        statusBar.onFrameRateChange = { [weak self] frameRate in self?.setFrameRate(frameRate) }
        statusBar.setResolution(Settings.resolution)
        statusBar.setFrameRate(Settings.frameRate)
        setAlwaysOnTop(Settings.alwaysOnTop)
    }

    private func setAlwaysOnTop(_ on: Bool) {
        Settings.alwaysOnTop = on
        windowController.isAlwaysOnTop = on
        statusBar.setAlwaysOnTop(on)
    }

    private func stopMirroring() {
        guard clientConnected else { return }
        receiver.stop()
        pipeline.reset()
        playback.reset()
        clearMirroringState()
        startReceiver()
    }

    private func clearMirroringState() {
        clientConnected = false
        statusBar.setVideoSettingsEnabled(true)
        statusBar.setClient(nil)
        windowController.dismiss()
        windowController.setDeviceName(nil)
    }

    private func setResolution(_ resolution: MirrorResolution) {
        guard !clientConnected else { return }
        guard resolution != Settings.resolution || !receiver.isRunning else { return }
        Settings.resolution = resolution
        statusBar.setResolution(resolution)
        receiver.stop()
        pipeline.reset()
        playback.reset()
        startReceiver()
    }

    private func setFrameRate(_ frameRate: MirrorFrameRate) {
        guard !clientConnected else { return }
        guard frameRate != Settings.frameRate || !receiver.isRunning else { return }
        Settings.frameRate = frameRate
        statusBar.setFrameRate(frameRate)
        receiver.stop()
        pipeline.reset()
        playback.reset()
        startReceiver()
    }

    static let debugEnabled = ProcessInfo.processInfo.environment["TINYMIRROR_DEBUG"] == "1"

    private func startReceiver() {
        let name = Settings.receiverName
        let started = receiver.start(name: name, resolution: Settings.resolution,
                                     frameRate: Settings.frameRate, debug: AppDelegate.debugEnabled)
        windowController.setReceiverState(name: name, isRunning: started)
        if started {
            statusBar.setReceiverState(String.localizedStringWithFormat(String(localized: "Visible as “%@”", bundle: .appLocalization), name))
            NSLog("[TinyMirror] receiver started, advertising as “%@”", name)
        } else {
            statusBar.setReceiverState(String(localized: "Receiver failed to start", bundle: .appLocalization))
            NSLog("[TinyMirror] RECEIVER FAILED TO START")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if AppDelegate.debugEnabled { self.statusBar.logPlacement() }
            if self.statusBar.isHiddenBehindNotch { self.warnIconHidden() }
        }

    }

    /// Shown once: an invisible menu bar item otherwise looks like a failed launch.
    private func warnIconHidden() {
        let key = "didWarnIconBehindNotch"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let alert = NSAlert()
        alert.messageText = String(localized: "TinyMirror's menu bar icon is hidden behind the notch", bundle: .appLocalization)
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
            statusBar.setVideoSettingsEnabled(false)
        case .clientInfo(_, _, let name):
            let displayName = name.isEmpty ? "iPhone" : name
            clientConnected = true
            statusBar.setVideoSettingsEnabled(false)
            statusBar.setClient(displayName)
            windowController.setDeviceName(displayName)
        case .disconnected:
            clearMirroringState()
        case .videoFlush:
            pipeline.flush()
        default:
            break
        }
    }
}

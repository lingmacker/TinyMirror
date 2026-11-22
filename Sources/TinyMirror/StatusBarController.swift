import AppKit

/// The app's idle presence: a single menu bar item, no Dock icon.
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let stateItem = NSMenuItem(title: String(localized: "Starting…", bundle: .appLocalization), action: nil, keyEquivalent: "")
    private let clientItem = NSMenuItem(title: String(localized: "No device connected", bundle: .appLocalization), action: nil, keyEquivalent: "")
    private let showItem: NSMenuItem
    private let onTopItem: NSMenuItem
    private let stopItem: NSMenuItem
    private let resolutionMenu = NSMenu()
    private let frameRateMenu = NSMenu()
    private let videoInfoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    var onShowWindow: (() -> Void)?
    var onStopMirroring: (() -> Void)?
    var onQuit: (() -> Void)?
    var onToggleAlwaysOnTop: ((Bool) -> Void)?
    var onResolutionChange: ((MirrorResolution) -> Void)?
    var onFrameRateChange: ((MirrorFrameRate) -> Void)?
    private static let autosaveName = "TinyMirrorStatusItem"

    init() {
        // Given no stored preference, macOS picks a slot for a new item that on
        // a full menu bar can land behind the camera notch, where it renders as
        // nothing and cannot be clicked. Seeding a position once puts it in the
        // ordinary run of menu bar icons instead. Only seeded when absent, so a
        // position the user ⌘-drags to (saved under autosaveName) always wins.
        let positionKey = "NSStatusItem Preferred Position \(Self.autosaveName)"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(50.0, forKey: positionKey)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = Self.autosaveName
        statusItem.button?.image = Bundle.appResources.image(forResource: "MenuBarIcon")
        statusItem.button?.setAccessibilityLabel("TinyMirror")
        statusItem.button?.toolTip = "TinyMirror"

        showItem = NSMenuItem(title: String(localized: "Show Mirror Window", bundle: .appLocalization), action: #selector(showWindow), keyEquivalent: "m")
        onTopItem = NSMenuItem(title: String(localized: "Keep Window on Top", bundle: .appLocalization), action: #selector(toggleOnTop), keyEquivalent: "t")
        stopItem = NSMenuItem(title: String(localized: "Stop Mirroring", bundle: .appLocalization), action: #selector(stopMirroring), keyEquivalent: "M")
        stopItem.keyEquivalentModifierMask = [.command, .shift]
        stopItem.target = self
        stopItem.isEnabled = false

        let menu = NSMenu()
        stateItem.isEnabled = false
        clientItem.isEnabled = false
        showItem.target = self
        onTopItem.target = self
        let quitItem = NSMenuItem(title: String(localized: "Quit", bundle: .appLocalization), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self

        menu.addItem(stateItem)
        menu.addItem(clientItem)
        videoInfoItem.isEnabled = false
        videoInfoItem.isHidden = true
        menu.addItem(videoInfoItem)
        menu.addItem(.separator())
        menu.addItem(showItem)
        menu.addItem(stopItem)
        menu.addItem(onTopItem)
        let resolutionItem = NSMenuItem(title: String(localized: "Resolution", bundle: .appLocalization), action: nil, keyEquivalent: "")
        resolutionMenu.autoenablesItems = false
        for resolution in MirrorResolution.allCases {
            let item = NSMenuItem(title: resolution.title, action: #selector(selectResolution(_:)), keyEquivalent: "")
            item.target = self
            item.tag = resolution.rawValue
            resolutionMenu.addItem(item)
        }
        resolutionMenu.addItem(.separator())
        let hint = NSMenuItem(title: String(localized: "Stop mirroring to change; reconnect to apply.", bundle: .appLocalization), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        resolutionMenu.addItem(hint)
        resolutionItem.submenu = resolutionMenu
        menu.addItem(resolutionItem)
        let frameRateItem = NSMenuItem(title: String(localized: "Frame Rate", bundle: .appLocalization), action: nil, keyEquivalent: "")
        frameRateMenu.autoenablesItems = false
        for frameRate in MirrorFrameRate.allCases {
            let item = NSMenuItem(title: frameRate.title, action: #selector(selectFrameRate(_:)), keyEquivalent: "")
            item.target = self
            item.tag = frameRate.rawValue
            frameRateMenu.addItem(item)
        }
        frameRateMenu.addItem(.separator())
        let frameRateHint = NSMenuItem(title: hint.title, action: nil, keyEquivalent: "")
        frameRateHint.isEnabled = false
        frameRateMenu.addItem(frameRateHint)
        frameRateItem.submenu = frameRateMenu
        menu.addItem(frameRateItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        menu.autoenablesItems = false
        statusItem.menu = menu

        // Status-item menus alone are not searched for active-window shortcuts.
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(title: "TinyMirror", action: nil, keyEquivalent: "")
        appItem.submenu = menu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }

    /// Reflects the current state in the menu's checkmark.
    func setAlwaysOnTop(_ on: Bool) {
        onTopItem.state = on ? .on : .off
    }

    func setResolution(_ resolution: MirrorResolution) {
        for item in resolutionMenu.items where item.action != nil {
            item.state = item.tag == resolution.rawValue ? .on : .off
        }
    }

    func setFrameRate(_ frameRate: MirrorFrameRate) {
        for item in frameRateMenu.items where item.action != nil {
            item.state = item.tag == frameRate.rawValue ? .on : .off
        }
    }

    func setVideoSettingsEnabled(_ enabled: Bool) {
        for menu in [resolutionMenu, frameRateMenu] {
            for item in menu.items where item.action != nil { item.isEnabled = enabled }
        }
    }

    func setVideoSize(width: Int, height: Int, isH265: Bool) {
        videoInfoItem.title = String.localizedStringWithFormat(
            String(localized: "Actual stream: %d × %d (%@)", bundle: .appLocalization), width, height, isH265 ? "HEVC" : "H.264")
        videoInfoItem.isHidden = false
    }

    @objc private func selectResolution(_ sender: NSMenuItem) {
        guard sender.isEnabled, let resolution = MirrorResolution(rawValue: sender.tag) else { return }
        onResolutionChange?(resolution)
    }

    @objc private func selectFrameRate(_ sender: NSMenuItem) {
        guard sender.isEnabled, let frameRate = MirrorFrameRate(rawValue: sender.tag) else { return }
        onFrameRateChange?(frameRate)
    }

    @objc private func toggleOnTop() {
        let newValue = onTopItem.state != .on
        onTopItem.state = newValue ? .on : .off
        onToggleAlwaysOnTop?(newValue)
    }

    func setReceiverState(_ text: String) {
        stateItem.title = text
    }

    /// True when macOS placed the icon behind the display notch. That happens
    /// when the menu bar is full: the item reports itself visible and has a
    /// valid frame, but nothing renders there and it cannot be clicked.
    var isHiddenBehindNotch: Bool {
        guard let window = statusItem.button?.window else { return false }
        guard let screen = window.screen ?? NSScreen.main,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return false }
        let frame = window.frame
        return frame.minX < right.minX && frame.maxX > left.maxX
    }

    /// Logs where the icon ended up; both are invisible when something is wrong.
    func logPlacement() {
        guard let window = statusItem.button?.window else {
            NSLog("[TinyMirror] status item has no window — it was not placed")
            return
        }
        let frame = window.frame
        NSLog("[TinyMirror] status item at x=%.0f-%.0f y=%.0f visible=%@",
              frame.minX, frame.maxX, frame.minY,
              statusItem.isVisible ? "yes" : "no")
        guard let screen = window.screen ?? NSScreen.main,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else {
            NSLog("[TinyMirror] display has no notch")
            return
        }
        NSLog("[TinyMirror] notch spans x=%.0f-%.0f -> icon %@",
              left.maxX, right.minX,
              isHiddenBehindNotch ? "IS BEHIND THE NOTCH (free menu bar space)"
                                  : "is clear of the notch")
    }

    func setClient(_ name: String?) {
        stopItem.isEnabled = name != nil
        if name == nil { videoInfoItem.isHidden = true }
        clientItem.title = name.map {
            String.localizedStringWithFormat(String(localized: "Mirroring: %@", bundle: .appLocalization), $0)
        } ?? String(localized: "No device connected", bundle: .appLocalization)
        statusItem.button?.image = Bundle.appResources.image(
            forResource: name != nil ? "MenuBarIconConnected" : "MenuBarIcon")
    }

    @objc private func stopMirroring() {
        guard stopItem.isEnabled else { return }
        onStopMirroring?()
    }

    @objc private func showWindow() { onShowWindow?() }
    @objc private func quit() { onQuit?() }
}

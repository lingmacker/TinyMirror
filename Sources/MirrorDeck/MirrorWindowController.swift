import AppKit

final class MirrorWindowController: NSWindowController, NSToolbarDelegate {
    let videoView = MirrorVideoView()
    private let pinButton = NSButton()
    private let pinItemID = NSToolbarItem.Identifier("KeepOnTop")

    var onToggleAlwaysOnTop: ((Bool) -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "iPhone"
        window.subtitle = "Screen Mirroring"
        window.backgroundColor = .black
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        super.init(window: window)

        videoView.frame = window.contentView!.bounds
        videoView.autoresizingMask = [.width, .height]
        window.contentView = videoView

        pinButton.bezelStyle = .accessoryBarAction
        pinButton.setButtonType(.pushOnPushOff)
        pinButton.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Keep Window on Top")
        pinButton.imagePosition = .imageOnly
        pinButton.target = self
        pinButton.action = #selector(toggleOnTop)
        pinButton.frame = NSRect(x: 0, y: 0, width: 32, height: 28)
        updatePinButton()

        let toolbar = NSToolbar(identifier: "MirrorToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbarStyle = .unifiedCompact
        window.toolbar = toolbar
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, pinItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == pinItemID else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Keep Window on Top"
        item.view = pinButton
        return item
    }

    func setDeviceName(_ name: String) {
        window?.title = name
    }

    var isAlwaysOnTop = false {
        didSet {
            window?.level = isAlwaysOnTop ? .floating : .normal
            updatePinButton()
        }
    }

    private func updatePinButton() {
        pinButton.state = isAlwaysOnTop ? .on : .off
        pinButton.image = NSImage(
            systemSymbolName: isAlwaysOnTop ? "pin.fill" : "pin",
            accessibilityDescription: "Keep Window on Top")
        pinButton.toolTip = isAlwaysOnTop ? "Stop Keeping Window on Top" : "Keep Window on Top"
        pinButton.setAccessibilityLabel("Keep Window on Top")
    }

    @objc private func toggleOnTop() {
        isAlwaysOnTop.toggle()
        onToggleAlwaysOnTop?(isAlwaysOnTop)
    }

    /// Size the picture, not the window chrome, and fit both screen dimensions.
    func setVideoDimensions(width: Int, height: Int) {
        guard let window, width > 0, height > 0 else { return }
        let videoSize = NSSize(width: width, height: height)
        window.contentAspectRatio = videoSize
        let screen = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let chromeHeight = window.frame.height - window.contentLayoutRect.height
        let aspect = videoSize.width / videoSize.height
        let videoHeight = min(min(screen.height * 0.8 - chromeHeight, 780),
                              screen.width * 0.8 / aspect)
        let size = NSSize(width: videoHeight * aspect, height: videoHeight)
        let minWidth = min(240, size.width)
        window.contentMinSize = NSSize(width: minWidth, height: minWidth / aspect)

        // Full screen keeps the display's frame and aspect-fits the new picture.
        guard !window.styleMask.contains(.fullScreen) else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        if window.isVisible {
            frame.origin = NSPoint(x: window.frame.midX - frame.width / 2,
                                   y: window.frame.midY - frame.height / 2)
        } else {
            frame.origin = NSPoint(x: screen.maxX - frame.width - 48,
                                   y: screen.midY - frame.height / 2)
        }
        frame.origin.x = max(screen.minX, min(frame.origin.x, screen.maxX - frame.width))
        frame.origin.y = max(screen.minY, min(frame.origin.y, screen.maxY - frame.height))
        window.setFrame(frame, display: true)
    }

    func present() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        window?.orderOut(nil)
    }
}

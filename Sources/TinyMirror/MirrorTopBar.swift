import AppKit

/// Compact dark-graphite pill button designed for the mirror window's top chrome bar.
final class MirrorBarPillButton: NSControl {
    struct Style {
        var fill: NSColor
        var hoverFill: NSColor
        var pressedFill: NSColor
        var border: NSColor
        var foreground: NSColor
        var dotColor: NSColor?
    }

    var pillStyle = Style(
        fill: NSColor(calibratedWhite: 1, alpha: 0.08),
        hoverFill: NSColor(calibratedWhite: 1, alpha: 0.14),
        pressedFill: NSColor(calibratedWhite: 1, alpha: 0.20),
        border: NSColor(calibratedWhite: 1, alpha: 0.12),
        foreground: NSColor(calibratedWhite: 1, alpha: 0.86),
        dotColor: nil
    ) {
        didSet { applyStyle() }
    }

    var onClick: (() -> Void)?

    private let dotView = NSView()
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false

    override var isEnabled: Bool {
        didSet { applyStyle() }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    init(symbolName: String, title: String? = nil, accessibilityLabel: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 2.5
        dotView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dotView.widthAnchor.constraint(equalToConstant: 5),
            dotView.heightAnchor.constraint(equalToConstant: 5),
        ])
        dotView.isHidden = true

        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleField.font = .systemFont(ofSize: 10.5, weight: .medium)
        titleField.lineBreakMode = .byClipping
        titleField.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleField.setContentHuggingPriority(.required, for: .horizontal)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4.5
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(dotView)
        stack.addArrangedSubview(iconView)
        if let title {
            titleField.stringValue = title
            stack.addArrangedSubview(titleField)
        } else {
            titleField.isHidden = true
        }
        addSubview(stack)

        let horizontalPad: CGFloat = title == nil ? 6 : 8
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            widthAnchor.constraint(greaterThanOrEqualToConstant: title == nil ? 24 : 58),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPad),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPad),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setContent(symbolName: String, title: String?, accessibilityLabel: String, toolTip: String?) {
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        if let title {
            titleField.stringValue = title
            titleField.isHidden = false
        } else {
            titleField.stringValue = ""
            titleField.isHidden = true
        }
        setAccessibilityLabel(accessibilityLabel)
        self.toolTip = toolTip
        invalidateIntrinsicContentSize()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        applyStyle()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        applyStyle()
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        applyStyle()
        guard isEnabled, wasPressed else { return }
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onClick?()
        }
    }

    private func applyStyle() {
        let enabledAlpha: CGFloat = isEnabled ? 1.0 : 0.42
        let fill: NSColor
        if !isEnabled {
            fill = NSColor(calibratedWhite: 1, alpha: 0.04)
        } else if isPressed {
            fill = pillStyle.pressedFill
        } else if isHovered {
            fill = pillStyle.hoverFill
        } else {
            fill = pillStyle.fill
        }
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = (isEnabled ? pillStyle.border : NSColor(calibratedWhite: 1, alpha: 0.07)).cgColor
        let fg = pillStyle.foreground.withAlphaComponent(pillStyle.foreground.alphaComponent * enabledAlpha)
        iconView.contentTintColor = fg
        titleField.textColor = fg
        if let dotColor = pillStyle.dotColor {
            dotView.isHidden = false
            dotView.layer?.backgroundColor = dotColor.withAlphaComponent(enabledAlpha).cgColor
        } else {
            dotView.isHidden = true
        }
    }
}

/// Top window chrome bar hosting the native traffic lights on the left and
/// Bluetooth reverse-control / Home controls on the right.
final class MirrorTopBarView: NSView {
    static let height: CGFloat = 31

    var onBluetoothButtonClick: (() -> Void)?
    var onHomeButtonClick: (() -> Void)?

    let homeButton = MirrorBarPillButton(
        symbolName: "house",
        title: nil,
        accessibilityLabel: String(localized: "Send Home Button", bundle: .appLocalization))
    let bluetoothButton = MirrorBarPillButton(
        symbolName: "antenna.radiowaves.left.and.right",
        title: String(localized: "Bluetooth", bundle: .appLocalization),
        accessibilityLabel: String(localized: "Control iPhone via Bluetooth", bundle: .appLocalization))

    private let rightStack = NSStackView()
    private var rightStackCenterYConstraint: NSLayoutConstraint?

    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        homeButton.isEnabled = false
        homeButton.toolTip = String(localized: "Send Home Button", bundle: .appLocalization)
        homeButton.onClick = { [weak self] in self?.onHomeButtonClick?() }

        bluetoothButton.toolTip = String(localized: "Control iPhone via Bluetooth", bundle: .appLocalization)
        bluetoothButton.onClick = { [weak self] in self?.onBluetoothButtonClick?() }

        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 5
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.addArrangedSubview(homeButton)
        rightStack.addArrangedSubview(bluetoothButton)
        addSubview(rightStack)

        let centerY = rightStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        rightStackCenterYConstraint = centerY

        NSLayoutConstraint.activate([
            rightStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            centerY,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Aligns right-side controls vertically to the native traffic light buttons.
    func alignControlsVertically(toLocalY targetMidY: CGFloat?) {
        guard let targetMidY, bounds.height > 0 else {
            rightStackCenterYConstraint?.constant = 0
            return
        }
        let clamped = max(11, min(bounds.height - 11, targetMidY))
        rightStackCenterYConstraint?.constant = bounds.midY - clamped
    }

    func updateBluetoothStatus(_ status: BluetoothHIDStatus) {
        homeButton.isEnabled = status.isConnected && status.consumerReady
        homeButton.toolTip = status.isConnected
            ? String(localized: "Send Home Button", bundle: .appLocalization)
            : String(localized: "Connect Bluetooth control to use Home", bundle: .appLocalization)

        if !status.isEnabled {
            bluetoothButton.setContent(
                symbolName: "antenna.radiowaves.left.and.right",
                title: String(localized: "Bluetooth", bundle: .appLocalization),
                accessibilityLabel: String(localized: "Control iPhone via Bluetooth", bundle: .appLocalization),
                toolTip: String(localized: "Enable Bluetooth control for iPhone", bundle: .appLocalization))
            bluetoothButton.pillStyle = .init(
                fill: NSColor(calibratedWhite: 1, alpha: 0.08),
                hoverFill: NSColor(calibratedWhite: 1, alpha: 0.14),
                pressedFill: NSColor(calibratedWhite: 1, alpha: 0.20),
                border: NSColor(calibratedWhite: 1, alpha: 0.12),
                foreground: NSColor(calibratedWhite: 1, alpha: 0.80),
                dotColor: nil)
            return
        }

        if status.isConnected && status.pointerReady {
            bluetoothButton.setContent(
                symbolName: "cursorarrow.click.2",
                title: String(localized: "Connected", bundle: .appLocalization),
                accessibilityLabel: String(localized: "Bluetooth control connected", bundle: .appLocalization),
                toolTip: String(localized: "Bluetooth control active — click to turn off", bundle: .appLocalization))
            bluetoothButton.pillStyle = .init(
                fill: NSColor.systemGreen.withAlphaComponent(0.18),
                hoverFill: NSColor.systemGreen.withAlphaComponent(0.26),
                pressedFill: NSColor.systemGreen.withAlphaComponent(0.32),
                border: NSColor.systemGreen.withAlphaComponent(0.45),
                foreground: NSColor(calibratedWhite: 1, alpha: 0.94),
                dotColor: .systemGreen)
            return
        }

        let title: String
        if status.isConnected {
            title = String(localized: "AssistiveTouch", bundle: .appLocalization)
        } else if status.isReconnecting {
            title = String(localized: "Reconnecting", bundle: .appLocalization)
        } else {
            title = String(localized: "Pairing", bundle: .appLocalization)
        }
        bluetoothButton.setContent(
            symbolName: "antenna.radiowaves.left.and.right",
            title: title,
            accessibilityLabel: status.message ?? title,
            toolTip: status.message ?? title)
        bluetoothButton.pillStyle = .init(
            fill: NSColor.systemOrange.withAlphaComponent(0.18),
            hoverFill: NSColor.systemOrange.withAlphaComponent(0.26),
            pressedFill: NSColor.systemOrange.withAlphaComponent(0.32),
            border: NSColor.systemOrange.withAlphaComponent(0.45),
            foreground: NSColor(calibratedWhite: 1, alpha: 0.92),
            dotColor: .systemOrange)
    }
}

/// Native popover anchored to the top bar's Bluetooth button showing live status
/// and step-by-step iPhone AssistiveTouch pairing instructions.
final class BluetoothPairingPopoverController: NSViewController {
    var onReconnect: (() -> Void)?
    var onTurnOff: (() -> Void)?

    private let titleField = NSTextField(labelWithString: String(localized: "Connect Bluetooth Control", bundle: .appLocalization))
    private let statusDot = NSView()
    private let statusField = NSTextField(wrappingLabelWithString: "")
    private let stepsField = NSTextField(wrappingLabelWithString: "")
    private let reconnectButton = NSButton(
        title: String(localized: "Reconnect", bundle: .appLocalization),
        target: nil,
        action: nil)
    private let turnOffButton = NSButton(
        title: String(localized: "Turn Off", bundle: .appLocalization),
        target: nil,
        action: nil)

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .labelColor

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3.5
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),
        ])

        statusField.font = .systemFont(ofSize: 12, weight: .medium)
        statusField.textColor = .secondaryLabelColor
        statusField.maximumNumberOfLines = 0
        statusField.lineBreakMode = .byWordWrapping

        let statusRow = NSStackView(views: [statusDot, statusField])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 6

        let separator = NSBox()
        separator.boxType = .separator

        stepsField.font = .systemFont(ofSize: 12)
        stepsField.textColor = .labelColor
        stepsField.maximumNumberOfLines = 0
        stepsField.lineBreakMode = .byWordWrapping

        reconnectButton.bezelStyle = .rounded
        reconnectButton.controlSize = .small
        reconnectButton.target = self
        reconnectButton.action = #selector(handleReconnect)

        turnOffButton.bezelStyle = .rounded
        turnOffButton.controlSize = .small
        turnOffButton.target = self
        turnOffButton.action = #selector(handleTurnOff)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actionsRow = NSStackView(views: [reconnectButton, spacer, turnOffButton])
        actionsRow.orientation = .horizontal
        actionsRow.alignment = .centerY
        actionsRow.spacing = 8

        let stack = NSStackView(views: [titleField, statusRow, separator, stepsField, actionsRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 310),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stepsField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionsRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        self.view = root
    }

    func update(status: BluetoothHIDStatus) {
        _ = view
        statusField.stringValue = status.message ?? String(localized: "Starting Bluetooth control…", bundle: .appLocalization)
        statusDot.layer?.backgroundColor = (status.isConnected && status.pointerReady ? NSColor.systemGreen : NSColor.systemOrange).cgColor

        let deviceLabel: String
        if let btName = status.macBluetoothName, !btName.isEmpty, btName != status.advertisedName {
            deviceLabel = String.localizedStringWithFormat(
                String(localized: "“%@” (or “%@”)", bundle: .appLocalization),
                status.advertisedName, btName)
        } else {
            deviceLabel = String.localizedStringWithFormat(
                String(localized: "“%@”", bundle: .appLocalization),
                status.advertisedName)
        }

        stepsField.stringValue = String.localizedStringWithFormat(
            String(localized: "bluetooth_pairing_steps", bundle: .appLocalization),
            deviceLabel)

        reconnectButton.isHidden = !(status.isEnabled && !status.isConnected && status.canReconnectPairedHost)
        turnOffButton.isHidden = !status.isEnabled
    }

    @objc private func handleReconnect() {
        onReconnect?()
    }

    @objc private func handleTurnOff() {
        onTurnOff?()
    }
}

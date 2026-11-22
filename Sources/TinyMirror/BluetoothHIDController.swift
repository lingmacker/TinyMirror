import CoreBluetooth
import Foundation
import IOBluetooth

struct BluetoothHIDStatus: Equatable {
    let isEnabled: Bool
    let isConnected: Bool
    let pointerReady: Bool
    let absolutePointerReady: Bool
    let relativePointerReady: Bool
    let keyboardReady: Bool
    let consumerReady: Bool
    let canReconnectPairedHost: Bool
    let message: String?
}

/// Optional Bluetooth LE HID over GATT peripheral for reverse-controlling a
/// mirrored iPhone (absolute pointer + relative mouse/scroll + keyboard + Home).
///
/// Mirrors the proven HOGP GATT layout:
/// 1. 1801 Generic Attribute (2A05 Service Changed for stale-cache recovery)
/// 2. 1812 Primary HID (keyboard, relative mouse + wheel, consumer)
/// 3. 180A Device Information (2A29 Manufacturer + mandatory 2A50 PnP ID)
/// 4. 180F Battery Service (2A19 Battery Level)
/// 5. 1812 Absolute Pointer HID (isolated so iOS AssistiveTouch treats held touches as absolute)
final class BluetoothHIDController: NSObject, CBPeripheralManagerDelegate, CBCentralManagerDelegate {
    let localName = "TinyMirror"

    /// Called on the main queue whenever Bluetooth state or subscriptions change.
    var onStatusChange: ((BluetoothHIDStatus) -> Void)?

    /// Serial queue owning CoreBluetooth managers, GATT database, subscriptions and pending queue.
    private let bluetoothQueue = DispatchQueue(label: "tinymirror.bluetooth")
    /// Serial queue pacing sequenced HID reports (press/release settle, keystroke timing).
    private let inputQueue = DispatchQueue(label: "tinymirror.bluetooth.input")

    private let sequenceLock = NSLock()
    private var motionSequenceValue: UInt64 = 0

    // Bluetooth-queue-confined state.
    private var enabled = false
    private var systemSleeping = false
    private var manager: CBPeripheralManager?
    private var centralManager: CBCentralManager?
    private var servicesToAdd: [CBMutableService] = []
    private var serviceBeingAdded: CBMutableService?
    private var published = false
    private var inputs: [HIDReportID: CBMutableCharacteristic] = [:]
    private var reportMaps: [ObjectIdentifier: [UInt8]] = [:]
    private var keyboardOutput: CBMutableCharacteristic?
    private var batteryLevel: CBMutableCharacteristic?
    private var serviceChanged: CBMutableCharacteristic?
    private var centrals: [UUID: CBCentral] = [:]
    private var connections = BluetoothHIDConnectionState()
    private var serviceChangedSent = Set<UUID>()
    private var reconnectTracker = BluetoothHIDReconnectTracker()
    private var reconnectingPeripherals: [UUID: CBPeripheral] = [:]
    private var lastErrorMessage: String?
    private var savedHostID: UUID?
    private var controllerBluetoothName: String?
    private var controllerNameRequested = false

    // Input-queue-confined state.
    private var activeButtons: UInt8 = 0
    private var lastAbsolutePosition: (x: UInt16, y: UInt16)?
    private let reportStep: TimeInterval = 0.03

    private let loadSavedHost: () -> UUID?
    private let saveHost: (UUID?) -> Void

    init(
        loadSavedHost: @escaping () -> UUID? = { Settings.lastBluetoothHostID },
        saveHost: @escaping (UUID?) -> Void = { Settings.lastBluetoothHostID = $0 }
    ) {
        self.loadSavedHost = loadSavedHost
        self.saveHost = saveHost
        super.init()
    }

    var isEnabled: Bool {
        bluetoothQueue.sync { enabled }
    }

    var currentStatus: BluetoothHIDStatus {
        bluetoothQueue.sync { snapshotStatusOnQueue() }
    }

    // MARK: - Lifecycle

    func start() {
        bluetoothQueue.async {
            guard !self.enabled else { return }
            self.enabled = true
            self.lastErrorMessage = nil
            self.savedHostID = self.loadSavedHost()
            self.resolveControllerNameIfNeededOnQueue()
            self.applyCoreBluetoothLifecycleOnQueue()
            if let saved = self.savedHostID {
                self.updateReconnectTargetsOnQueue([saved], resetExhausted: true)
            }
            self.publishStatusOnQueue()
        }
    }

    func stop() {
        releaseButtonsSync()
        bluetoothQueue.sync {
            guard self.enabled || self.manager != nil || self.centralManager != nil else { return }
            self.enabled = false
            self.lastErrorMessage = nil
            self.teardownCoreBluetoothOnQueue(clearTargets: true)
            self.publishStatusOnQueue()
        }
    }

    /// Synchronously unregisters CoreBluetooth before macOS sleep so bonded BLE
    /// links cannot wake a sleeping Mac.
    func systemWillSleep() {
        releaseButtonsSync()
        bluetoothQueue.sync {
            self.systemSleeping = true
            self.teardownCoreBluetoothOnQueue(clearTargets: false)
            self.publishStatusOnQueue()
        }
    }

    private func releaseButtonsSync() {
        _ = advanceMotionSequence()
        inputQueue.sync {
            guard self.activeButtons != 0 else { return }
            self.activeButtons = 0
            if let route = self.activeInputRoute(for: .absolutePointer), let pos = self.lastAbsolutePosition {
                let payload = HIDReportPayload.absolutePointer(buttons: 0, x: pos.x, y: pos.y)
                self.enqueueReport(.absolutePointer, bytes: payload, route: route, absoluteRelease: true)
            }
            if let route = self.activeInputRoute(for: .relativeMouse) {
                let payload = HIDReportPayload.relativeMouse(buttons: 0)
                self.enqueueReport(.relativeMouse, bytes: payload, route: route)
            }
        }
    }

    func systemDidWake() {
        bluetoothQueue.async {
            self.systemSleeping = false
            guard self.enabled else { return }
            self.applyCoreBluetoothLifecycleOnQueue()
            if let saved = self.savedHostID {
                self.updateReconnectTargetsOnQueue([saved], resetExhausted: true)
            }
            self.publishStatusOnQueue()
        }
    }

    func reconnectPairedHost() {
        bluetoothQueue.async {
            guard self.enabled, !self.systemSleeping, let saved = self.savedHostID else { return }
            self.lastErrorMessage = nil
            self.updateReconnectTargetsOnQueue([saved], resetExhausted: true)
            self.publishStatusOnQueue()
        }
    }

    // MARK: - Input API (called from MirrorVideoView / StatusBarController on main thread)

    func moveAbsolute(x: Double, y: Double) {
        let sequence = advanceMotionSequence()
        inputQueue.async {
            guard self.isMotionSequenceCurrent(sequence),
                  let route = self.activeInputRoute(for: .absolutePointer)
            else { return }
            let coords = Self.scaledAbsoluteCoords(x: x, y: y)
            self.lastAbsolutePosition = coords
            let payload = HIDReportPayload.absolutePointer(buttons: self.activeButtons, x: coords.x, y: coords.y)
            self.enqueueReport(.absolutePointer, bytes: payload, route: route)
        }
    }

    func pressAbsolute(buttonMask: UInt8, x: Double, y: Double) {
        _ = advanceMotionSequence()
        inputQueue.async {
            guard let route = self.activeInputRoute(for: .absolutePointer) else { return }
            let coords = Self.scaledAbsoluteCoords(x: x, y: y)
            self.lastAbsolutePosition = coords
            // Land the pointer before pressing so AssistiveTouch clicks the exact coordinate.
            let movePayload = HIDReportPayload.absolutePointer(buttons: self.activeButtons, x: coords.x, y: coords.y)
            self.enqueueReport(.absolutePointer, bytes: movePayload, route: route)
            Thread.sleep(forTimeInterval: self.reportStep * 2)
            self.activeButtons |= buttonMask
            let pressPayload = HIDReportPayload.absolutePointer(buttons: self.activeButtons, x: coords.x, y: coords.y)
            self.enqueueReport(.absolutePointer, bytes: pressPayload, route: route)
        }
    }

    func dragAbsolute(x: Double, y: Double) {
        let sequence = advanceMotionSequence()
        inputQueue.async {
            guard self.activeButtons != 0,
                  self.isMotionSequenceCurrent(sequence),
                  let route = self.activeInputRoute(for: .absolutePointer)
            else { return }
            let coords = Self.scaledAbsoluteCoords(x: x, y: y)
            self.lastAbsolutePosition = coords
            let payload = HIDReportPayload.absolutePointer(buttons: self.activeButtons, x: coords.x, y: coords.y)
            self.enqueueReport(.absolutePointer, bytes: payload, route: route)
        }
    }

    func releaseAbsolute(buttonMask: UInt8, x: Double, y: Double) {
        _ = advanceMotionSequence()
        inputQueue.async {
            guard self.activeButtons != 0 else { return }
            let route = self.activeInputRoute(for: .absolutePointer)
            let coords = Self.scaledAbsoluteCoords(x: x, y: y)
            self.lastAbsolutePosition = coords
            if let route {
                let dragPayload = HIDReportPayload.absolutePointer(buttons: self.activeButtons, x: coords.x, y: coords.y)
                self.enqueueReport(.absolutePointer, bytes: dragPayload, route: route)
                Thread.sleep(forTimeInterval: self.reportStep * 2)
            }
            self.activeButtons &= ~buttonMask
            if let route {
                let releasePayload = HIDReportPayload.absolutePointer(buttons: self.activeButtons, x: coords.x, y: coords.y)
                self.enqueueReport(.absolutePointer, bytes: releasePayload, route: route, absoluteRelease: self.activeButtons == 0)
            }
        }
    }

    func sendRelativeMove(dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }
        inputQueue.async {
            guard let route = self.activeInputRoute(for: .relativeMouse) else { return }
            let payload = HIDReportPayload.relativeMouse(buttons: self.activeButtons, dx: dx, dy: dy)
            self.enqueueReport(.relativeMouse, bytes: payload, route: route)
        }
    }

    func pressRelative(buttonMask: UInt8) {
        _ = advanceMotionSequence()
        inputQueue.async {
            guard let route = self.activeInputRoute(for: .relativeMouse) else { return }
            self.activeButtons |= buttonMask
            let payload = HIDReportPayload.relativeMouse(buttons: self.activeButtons)
            self.enqueueReport(.relativeMouse, bytes: payload, route: route)
        }
    }

    func releaseRelative(buttonMask: UInt8) {
        _ = advanceMotionSequence()
        inputQueue.async {
            guard self.activeButtons != 0 else { return }
            self.activeButtons &= ~buttonMask
            guard let route = self.activeInputRoute(for: .relativeMouse) else { return }
            let payload = HIDReportPayload.relativeMouse(buttons: self.activeButtons)
            self.enqueueReport(.relativeMouse, bytes: payload, route: route)
        }
    }

    func sendScroll(verticalTicks: Int, horizontalTicks: Int) {
        guard verticalTicks != 0 || horizontalTicks != 0 else { return }
        inputQueue.async {
            guard let mouseRoute = self.activeInputRoute(for: .relativeMouse) else { return }
            if abs(verticalTicks) >= abs(horizontalTicks), verticalTicks != 0 {
                let payload = HIDReportPayload.relativeMouse(buttons: self.activeButtons, wheel: verticalTicks)
                self.enqueueReport(.relativeMouse, bytes: payload, route: mouseRoute)
            } else if horizontalTicks != 0 {
                let keyboardRoute = self.activeInputRoute(for: .keyboard)
                if let keyboardRoute {
                    self.enqueueReport(.keyboard, bytes: HIDReportPayload.keyboard(modifiers: HIDKeyboardMap.shift), route: keyboardRoute)
                    Thread.sleep(forTimeInterval: self.reportStep)
                }
                let payload = HIDReportPayload.relativeMouse(buttons: self.activeButtons, wheel: horizontalTicks)
                self.enqueueReport(.relativeMouse, bytes: payload, route: mouseRoute)
                if let keyboardRoute {
                    Thread.sleep(forTimeInterval: self.reportStep)
                    self.enqueueReport(.keyboard, bytes: HIDReportPayload.keyboard(), route: keyboardRoute)
                }
            }
        }
    }

    @discardableResult
    func sendKey(_ name: String, modifiers: [String] = []) -> Bool {
        guard let code = HIDKeyboardMap.code(for: name),
              let mask = HIDKeyboardMap.modifierMask(for: modifiers)
        else { return false }
        _ = advanceMotionSequence()
        inputQueue.async {
            guard let route = self.activeInputRoute(for: .keyboard) else { return }
            self.sendKeyStroke(HIDKeyboardMap.Stroke(code: code, modifiers: mask), route: route)
        }
        return true
    }

    @discardableResult
    func sendText(_ text: String, modifiers: [String] = []) -> Bool {
        guard let mask = HIDKeyboardMap.modifierMask(for: modifiers) else { return false }
        let strokes = text.compactMap { HIDKeyboardMap.stroke(for: $0) }.map {
            HIDKeyboardMap.Stroke(code: $0.code, modifiers: $0.modifiers | mask)
        }
        guard strokes.count == text.count, !strokes.isEmpty else { return false }
        _ = advanceMotionSequence()
        inputQueue.async {
            guard let route = self.activeInputRoute(for: .keyboard) else { return }
            for stroke in strokes {
                self.sendKeyStroke(stroke, route: route)
            }
        }
        return true
    }

    func sendHome() {
        _ = advanceMotionSequence()
        inputQueue.async {
            guard let route = self.activeInputRoute(for: .consumer) else { return }
            self.enqueueReport(.consumer, bytes: HIDReportPayload.consumer(HIDReportPayload.consumerHome), route: route)
            Thread.sleep(forTimeInterval: 0.08)
            self.enqueueReport(.consumer, bytes: HIDReportPayload.consumer(0), route: route)
            Thread.sleep(forTimeInterval: self.reportStep)
        }
    }

    func cancelPointer() {
        _ = advanceMotionSequence()
        inputQueue.async {
            guard self.activeButtons != 0 else { return }
            self.activeButtons = 0
            if let route = self.activeInputRoute(for: .absolutePointer), let pos = self.lastAbsolutePosition {
                let payload = HIDReportPayload.absolutePointer(buttons: 0, x: pos.x, y: pos.y)
                self.enqueueReport(.absolutePointer, bytes: payload, route: route, absoluteRelease: true)
            }
            if let route = self.activeInputRoute(for: .relativeMouse) {
                let payload = HIDReportPayload.relativeMouse(buttons: 0)
                self.enqueueReport(.relativeMouse, bytes: payload, route: route)
            }
        }
    }

    // MARK: - Input Helpers

    private func sendKeyStroke(_ stroke: HIDKeyboardMap.Stroke, route: (host: UUID, session: UUID)) {
        if stroke.modifiers != 0 {
            enqueueReport(.keyboard, bytes: HIDReportPayload.keyboard(modifiers: stroke.modifiers), route: route)
            Thread.sleep(forTimeInterval: reportStep)
        }
        enqueueReport(.keyboard, bytes: HIDReportPayload.keyboard(modifiers: stroke.modifiers, code: stroke.code), route: route)
        Thread.sleep(forTimeInterval: reportStep)
        enqueueReport(.keyboard, bytes: HIDReportPayload.keyboard(modifiers: stroke.modifiers), route: route)
        Thread.sleep(forTimeInterval: reportStep)
        if stroke.modifiers != 0 {
            enqueueReport(.keyboard, bytes: HIDReportPayload.keyboard(), route: route)
            Thread.sleep(forTimeInterval: reportStep)
        }
    }

    private func activeInputRoute(for report: HIDReportID) -> (host: UUID, session: UUID)? {
        bluetoothQueue.sync {
            guard manager?.state == .poweredOn, published,
                  let host = connections.preferredInputHost(matching: savedHostID),
                  let session = connections.sessions[host],
                  connections.isReady(report: report, host: host, session: session)
            else { return nil }
            return (host, session)
        }
    }

    private func enqueueReport(
        _ id: HIDReportID,
        bytes: [UInt8],
        route: (host: UUID, session: UUID),
        absoluteRelease: Bool = false
    ) {
        bluetoothQueue.async {
            guard self.manager?.state == .poweredOn, self.published else { return }
            self.connections.enqueue(
                .report(id),
                data: Data(bytes),
                host: route.host,
                session: route.session,
                absoluteRelease: absoluteRelease)
            self.drainOnQueue()
        }
    }

    private static func scaledAbsoluteCoords(x: Double, y: Double) -> (x: UInt16, y: UInt16) {
        let maxVal = Double(HIDReportMap.absoluteMax)
        let px = UInt16(max(0, min(maxVal, (x * maxVal).rounded())))
        let py = UInt16(max(0, min(maxVal, (y * maxVal).rounded())))
        return (px, py)
    }

    private func advanceMotionSequence() -> UInt64 {
        sequenceLock.withLock {
            motionSequenceValue &+= 1
            return motionSequenceValue
        }
    }

    private func isMotionSequenceCurrent(_ sequence: UInt64) -> Bool {
        sequenceLock.withLock { motionSequenceValue == sequence }
    }

    // MARK: - CoreBluetooth Lifecycle (bluetoothQueue)

    private func applyCoreBluetoothLifecycleOnQueue() {
        guard enabled, !systemSleeping else {
            teardownCoreBluetoothOnQueue(clearTargets: !enabled)
            return
        }
        guard manager == nil || centralManager == nil else { return }
        reconnectTracker.resetForCentralPowerOff()
        reconnectingPeripherals.removeAll()
        if manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: bluetoothQueue)
        }
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: bluetoothQueue)
        }
    }

    private func teardownCoreBluetoothOnQueue(clearTargets: Bool) {
        if manager?.state == .poweredOn {
            if manager?.isAdvertising == true {
                manager?.stopAdvertising()
            }
            manager?.removeAllServices()
        }
        let toCancel = clearTargets
            ? reconnectTracker.cancelAllForStop()
            : reconnectTracker.suspendForLifecycleTeardown()
        for host in toCancel {
            if let peripheral = reconnectingPeripherals[host] {
                centralManager?.cancelPeripheralConnection(peripheral)
            }
        }
        reconnectingPeripherals.removeAll()
        centralManager?.delegate = nil
        centralManager = nil
        manager?.delegate = nil
        manager = nil
        resetConnectionStateOnQueue()
        reportMaps.removeAll()
        keyboardOutput = nil
        batteryLevel = nil
        serviceChanged = nil
    }

    private func resetConnectionStateOnQueue() {
        connections.reset()
        centrals.removeAll()
        serviceChangedSent.removeAll()
        servicesToAdd.removeAll()
        serviceBeingAdded = nil
        inputs.removeAll()
        published = false
        for host in reconnectTracker.cancelEstablishedOnPeripheralReset() {
            if let peripheral = reconnectingPeripherals[host] {
                centralManager?.cancelPeripheralConnection(peripheral)
            } else {
                _ = reconnectTracker.handleTermination(host: host, hasActiveSession: false)
            }
        }
    }

    private func resolveControllerNameIfNeededOnQueue() {
        guard !controllerNameRequested else { return }
        controllerNameRequested = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let resolved = IOBluetoothHostController.default()?.nameAsString()?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self else { return }
            self.bluetoothQueue.async {
                self.controllerBluetoothName = resolved?.isEmpty == true ? nil : resolved
                if self.enabled {
                    self.publishStatusOnQueue()
                }
            }
        }
    }

    // MARK: - GATT Database (bluetoothQueue)

    private static func sig(_ short: String) -> CBUUID {
        CBUUID(string: "0000\(short)-0000-1000-8000-00805F9B34FB")
    }

    private func buildServicesOnQueue() -> [CBMutableService] {
        reportMaps.removeAll()
        // Service and characteristic order is cached by bonded iOS hosts.
        let gatt = makeGenericAttributeService()
        let primaryHID = makeHIDService(reports: HIDReportMap.primaryReports)
        let deviceInfo = makeDeviceInformationService()
        let battery = makeBatteryService()
        let absoluteHID = makeHIDService(reports: HIDReportMap.absoluteReports)
        return [gatt, primaryHID, deviceInfo, battery, absoluteHID]
    }

    private func makeGenericAttributeService() -> CBMutableService {
        let characteristic = CBMutableCharacteristic(
            type: CBUUID(string: "2A05"),
            properties: [.indicate],
            value: nil,
            permissions: [.readable])
        serviceChanged = characteristic
        let service = CBMutableService(type: Self.sig("1801"), primary: true)
        service.characteristics = [characteristic]
        return service
    }

    private func makeHIDService(reports: [HIDReportID]) -> CBMutableService {
        let info = CBMutableCharacteristic(
            type: CBUUID(string: "2A4A"),
            properties: [.read],
            value: Data([0x11, 0x01, 0x00, 0x02]),
            permissions: [.readable])
        let reportMap = CBMutableCharacteristic(
            type: CBUUID(string: "2A4B"),
            properties: [.read],
            value: nil,
            permissions: [.readEncryptionRequired])
        reportMaps[ObjectIdentifier(reportMap)] = HIDReportMap.descriptor(for: reports)
        let control = CBMutableCharacteristic(
            type: CBUUID(string: "2A4C"),
            properties: [.writeWithoutResponse],
            value: nil,
            permissions: [.writeEncryptionRequired])
        let protocolMode = CBMutableCharacteristic(
            type: CBUUID(string: "2A4E"),
            properties: [.read, .writeWithoutResponse],
            value: nil,
            permissions: [.readable, .writeable])

        var characteristics: [CBMutableCharacteristic] = [info, reportMap, control, protocolMode]
        for id in reports {
            let report = CBMutableCharacteristic(
                type: CBUUID(string: "2A4D"),
                properties: [.read, .notify],
                value: nil,
                permissions: [.readEncryptionRequired])
            report.descriptors = [CBMutableDescriptor(type: CBUUID(string: "2908"), value: Data([id.rawValue, 1]))]
            inputs[id] = report
            characteristics.append(report)
        }
        if reports.contains(.keyboard) {
            let output = CBMutableCharacteristic(
                type: CBUUID(string: "2A4D"),
                properties: [.read, .write, .writeWithoutResponse],
                value: nil,
                permissions: [.readEncryptionRequired, .writeEncryptionRequired])
            output.descriptors = [
                CBMutableDescriptor(type: CBUUID(string: "2908"), value: Data([HIDReportID.keyboard.rawValue, 2]))
            ]
            keyboardOutput = output
            characteristics.append(output)
        }

        let service = CBMutableService(type: Self.sig("1812"), primary: true)
        service.characteristics = characteristics
        return service
    }

    private func makeDeviceInformationService() -> CBMutableService {
        let service = CBMutableService(type: Self.sig("180A"), primary: true)
        service.characteristics = [
            CBMutableCharacteristic(
                type: CBUUID(string: "2A29"),
                properties: [.read],
                value: Data(localName.utf8),
                permissions: [.readable]),
            CBMutableCharacteristic(
                type: CBUUID(string: "2A50"),
                properties: [.read],
                value: Data([0x02, 0xFF, 0xFF, 0x00, 0x01, 0x00, 0x01]),
                permissions: [.readable]),
        ]
        return service
    }

    private func makeBatteryService() -> CBMutableService {
        let level = CBMutableCharacteristic(
            type: CBUUID(string: "2A19"),
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable])
        batteryLevel = level
        let service = CBMutableService(type: Self.sig("180F"), primary: true)
        service.characteristics = [level]
        return service
    }

    private func addNextServiceOnQueue() {
        guard let manager, manager.state == .poweredOn else { return }
        guard !servicesToAdd.isEmpty else {
            published = true
            advertiseOnQueue()
            attemptReconnectionsOnQueue()
            publishStatusOnQueue()
            return
        }
        let service = servicesToAdd.removeFirst()
        serviceBeingAdded = service
        manager.add(service)
    }

    private func advertiseOnQueue() {
        guard let manager, manager.state == .poweredOn, published, !manager.isAdvertising else { return }
        manager.startAdvertising([
            CBAdvertisementDataLocalNameKey: localName,
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "1812")],
        ])
    }

    // MARK: - CBPeripheralManagerDelegate (bluetoothQueue)

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        NSLog("[TinyMirror BLE] state=%d auth=%d", peripheral.state.rawValue, CBManager.authorization.rawValue)
        resetConnectionStateOnQueue()
        lastErrorMessage = nil
        if peripheral.state == .poweredOn {
            peripheral.removeAllServices()
            servicesToAdd = buildServicesOnQueue()
            addNextServiceOnQueue()
        }
        publishStatusOnQueue()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard peripheral === manager, peripheral.state == .poweredOn, service === serviceBeingAdded else { return }
        serviceBeingAdded = nil
        if let error {
            NSLog("[TinyMirror BLE] failed to add service %@: %@", service.uuid.uuidString, error.localizedDescription)
            lastErrorMessage = error.localizedDescription
            publishStatusOnQueue()
            return
        }
        NSLog("[TinyMirror BLE] added service %@", service.uuid.uuidString)
        addNextServiceOnQueue()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard peripheral === manager, peripheral.state == .poweredOn, published else { return }
        if let error, (error as? CBError)?.code != .alreadyAdvertising {
            NSLog("[TinyMirror BLE] advertising failed: %@", error.localizedDescription)
            lastErrorMessage = error.localizedDescription
        } else {
            NSLog("[TinyMirror BLE] advertising as %@", localName)
            lastErrorMessage = nil
        }
        publishStatusOnQueue()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard peripheral === manager else {
            peripheral.respond(to: request, withResult: .unlikelyError)
            return
        }
        let value: Data
        switch request.characteristic.uuid {
        case CBUUID(string: "2A4B"):
            guard let descriptor = reportMaps[ObjectIdentifier(request.characteristic)] else {
                peripheral.respond(to: request, withResult: .attributeNotFound)
                return
            }
            NSLog("[TinyMirror BLE] report map read: %d bytes offset=%d", descriptor.count, request.offset)
            value = Data(descriptor)
        case CBUUID(string: "2A4E"):
            value = Data([0x01])
        case CBUUID(string: "2A19"):
            value = Data([100])
        case CBUUID(string: "2A4D"):
            value = Data(count: reportLengthOnQueue(request.characteristic))
        default:
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        guard request.offset <= value.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = value.subdata(in: request.offset..<value.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard peripheral === manager, peripheral.state == .poweredOn, published else {
            if let first = requests.first { peripheral.respond(to: first, withResult: .unlikelyError) }
            return
        }
        for request in requests {
            centrals[request.central.identifier] = request.central
            if request.characteristic.uuid == CBUUID(string: "2A4C") {
                recoverStaleCacheIfNeededOnQueue(request.central)
            }
        }
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        guard peripheral === manager, published, peripheral.state == .poweredOn,
              let channel = channelOnQueue(for: characteristic)
        else { return }
        centrals[central.identifier] = central
        connections.subscribe(channel, host: central.identifier)
        NSLog("[TinyMirror BLE] subscribe %@ channel=%@ from %@", characteristic.uuid.uuidString, String(describing: channel), central.identifier.uuidString)
        if channel.isInput {
            reconnectTracker.noteSessionEstablished(central.identifier)
            // Persist iPhone host UUID once pointer or keyboard reports subscribe so
            // future sessions can wake it automatically via CBCentralManager.
            let reports = connections.subscribedReports(for: central.identifier)
            if reports.contains(.absolutePointer) || savedHostID == nil {
                savedHostID = central.identifier
                saveHost(central.identifier)
            }
            advertiseOnQueue()
            publishStatusOnQueue()
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard peripheral === manager, published, peripheral.state == .poweredOn,
              let channel = channelOnQueue(for: characteristic)
        else { return }
        connections.unsubscribe(channel, host: central.identifier)
        NSLog("[TinyMirror BLE] unsubscribe %@ channel=%@ from %@", characteristic.uuid.uuidString, String(describing: channel), central.identifier.uuidString)
        if connections.subscriptions[central.identifier] == nil {
            centrals[central.identifier] = nil
        }
        advertiseOnQueue()
        drainOnQueue()
        publishStatusOnQueue()
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        drainOnQueue()
    }

    // MARK: - CBCentralManagerDelegate (bonded host wake/reconnect)

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === centralManager else { return }
        if central.state == .poweredOn {
            attemptReconnectionsOnQueue()
        } else {
            reconnectTracker.resetForCentralPowerOff()
            reconnectingPeripherals.removeAll()
        }
        publishStatusOnQueue()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === centralManager else { return }
        NSLog("[TinyMirror BLE] woke paired host %@", String(peripheral.identifier.uuidString.prefix(8)))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === centralManager else { return }
        handleCentralTerminationOnQueue(for: peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === centralManager else { return }
        handleCentralTerminationOnQueue(for: peripheral.identifier)
    }

    private func updateReconnectTargetsOnQueue(_ hosts: Set<UUID>, resetExhausted: Bool) {
        let activeSessions = Set(connections.sessions.keys)
        let toCancel = reconnectTracker.updateTargets(
            hosts, activeSessions: activeSessions, resetExhausted: resetExhausted)
        for host in toCancel {
            if let peripheral = reconnectingPeripherals[host] {
                centralManager?.cancelPeripheralConnection(peripheral)
            } else {
                _ = reconnectTracker.handleTermination(host: host, hasActiveSession: activeSessions.contains(host))
            }
        }
        attemptReconnectionsOnQueue()
    }

    private func handleCentralTerminationOnQueue(for host: UUID) {
        reconnectingPeripherals[host] = nil
        let hasSession = connections.sessions[host] != nil
        switch reconnectTracker.handleTermination(host: host, hasActiveSession: hasSession) {
        case .none:
            break
        case .retryNow:
            attemptReconnectionsOnQueue()
        case .scheduleBackoff(let token, let delay):
            bluetoothQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let active = self.connections.sessions[host] != nil
                if self.reconnectTracker.completeBackoff(host: host, token: token, hasActiveSession: active) {
                    self.attemptReconnectionsOnQueue()
                }
            }
        case .notifyChanged:
            publishStatusOnQueue()
        }
    }

    private func attemptReconnectionsOnQueue() {
        guard let manager, manager.state == .poweredOn, published,
              let centralManager, centralManager.state == .poweredOn
        else { return }
        let activeSessions = Set(connections.sessions.keys)
        let missing = reconnectTracker.connectableHosts(activeSessions: activeSessions)
        guard !missing.isEmpty else { return }
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: Array(missing))
        let retrievedIDs = Set(peripherals.map(\.identifier))
        var anyUnretrievable = false
        for unretrievable in missing.subtracting(retrievedIDs) {
            reconnectTracker.markUnretrievable(unretrievable)
            anyUnretrievable = true
        }
        for peripheral in peripherals {
            let host = peripheral.identifier
            reconnectingPeripherals[host] = peripheral
            let attempt = reconnectTracker.beginConnecting(host)
            centralManager.connect(peripheral, options: nil)
            bluetoothQueue.asyncAfter(deadline: .now() + BluetoothHIDReconnectTracker.attemptTimeout) { [weak self] in
                guard let self else { return }
                let hasSession = self.connections.sessions[host] != nil
                guard self.reconnectTracker.markTimedOut(host: host, attempt: attempt, hasActiveSession: hasSession) else {
                    return
                }
                if let active = self.reconnectingPeripherals[host] {
                    self.centralManager?.cancelPeripheralConnection(active)
                } else {
                    self.handleCentralTerminationOnQueue(for: host)
                }
                if (self.reconnectTracker.attemptsUsed[host] ?? 0) >= BluetoothHIDReconnectTracker.maxAutomaticAttempts {
                    self.publishStatusOnQueue()
                }
            }
        }
        if anyUnretrievable {
            publishStatusOnQueue()
        }
    }

    // MARK: - Drain & Stale Cache Recovery (bluetoothQueue)

    private func drainOnQueue() {
        guard let manager, manager.state == .poweredOn, published else { return }
        var blockedHosts: Set<UUID> = []
        while let (index, report) = connections.nextPendingReportIndex(excludingHosts: blockedHosts) {
            guard let characteristic = characteristicOnQueue(for: report.channel),
                  let central = centrals[report.host]
            else {
                connections.removePending(at: index, accepted: false)
                continue
            }
            let sent = manager.updateValue(report.data, for: characteristic, onSubscribedCentrals: [central])
            guard sent else {
                blockedHosts.insert(report.host)
                continue
            }
            connections.removePending(at: index, accepted: true)
        }
    }

    /// A bonded iPhone with a stale GATT handle cache writes Control Point (2A4C)
    /// without subscribing to any input report. Indicating Service Changed forces
    /// iOS to rediscover services and subscribe cleanly.
    private func recoverStaleCacheIfNeededOnQueue(_ central: CBCentral) {
        let subscribed = connections.subscriptions[central.identifier] ?? []
        guard !subscribed.contains(where: \.isInput),
              subscribed.contains(.serviceChanged),
              !serviceChangedSent.contains(central.identifier)
        else { return }
        serviceChangedSent.insert(central.identifier)
        NSLog("[TinyMirror BLE] stale GATT cache detected; indicating Service Changed")
        connections.enqueue(.serviceChanged, data: Data([0x10, 0x00, 0xFF, 0xFF]), host: central.identifier)
        drainOnQueue()
    }

    private func channelOnQueue(for characteristic: CBCharacteristic) -> BluetoothHIDConnectionState.Channel? {
        if let id = inputs.first(where: { $0.value === characteristic })?.key { return .report(id) }
        if let serviceChanged, characteristic === serviceChanged { return .serviceChanged }
        if let batteryLevel, characteristic === batteryLevel { return .battery }
        return nil
    }

    private func characteristicOnQueue(for channel: BluetoothHIDConnectionState.Channel) -> CBMutableCharacteristic? {
        switch channel {
        case .report(let id): return inputs[id]
        case .serviceChanged: return serviceChanged
        case .battery: return batteryLevel
        }
    }

    private func reportLengthOnQueue(_ characteristic: CBCharacteristic) -> Int {
        if let keyboardOutput, characteristic === keyboardOutput { return 1 }
        if let id = inputs.first(where: { $0.value === characteristic })?.key { return id.reportLength }
        return 0
    }

    // MARK: - Status Projection

    private func snapshotStatusOnQueue() -> BluetoothHIDStatus {
        guard enabled else {
            return BluetoothHIDStatus(
                isEnabled: false,
                isConnected: false,
                pointerReady: false,
                absolutePointerReady: false,
                relativePointerReady: false,
                keyboardReady: false,
                consumerReady: false,
                canReconnectPairedHost: false,
                message: nil)
        }
        if systemSleeping {
            return BluetoothHIDStatus(
                isEnabled: true,
                isConnected: false,
                pointerReady: false,
                absolutePointerReady: false,
                relativePointerReady: false,
                keyboardReady: false,
                consumerReady: false,
                canReconnectPairedHost: false,
                message: nil)
        }
        if let errorMessage = lastErrorMessage {
            return BluetoothHIDStatus(
                isEnabled: true,
                isConnected: false,
                pointerReady: false,
                absolutePointerReady: false,
                relativePointerReady: false,
                keyboardReady: false,
                consumerReady: false,
                canReconnectPairedHost: savedHostID != nil,
                message: errorMessage)
        }
        guard let manager else {
            return BluetoothHIDStatus(
                isEnabled: true,
                isConnected: false,
                pointerReady: false,
                absolutePointerReady: false,
                relativePointerReady: false,
                keyboardReady: false,
                consumerReady: false,
                canReconnectPairedHost: false,
                message: String(localized: "Starting Bluetooth control…", bundle: .appLocalization))
        }
        switch manager.state {
        case .poweredOn:
            break
        case .unauthorized:
            return BluetoothHIDStatus(
                isEnabled: true,
                isConnected: false,
                pointerReady: false,
                absolutePointerReady: false,
                relativePointerReady: false,
                keyboardReady: false,
                consumerReady: false,
                canReconnectPairedHost: false,
                message: String(localized: "Bluetooth permission denied. Allow TinyMirror in System Settings.", bundle: .appLocalization))
        case .poweredOff:
            return BluetoothHIDStatus(
                isEnabled: true,
                isConnected: false,
                pointerReady: false,
                absolutePointerReady: false,
                relativePointerReady: false,
                keyboardReady: false,
                consumerReady: false,
                canReconnectPairedHost: false,
                message: String(localized: "Turn on Bluetooth on your Mac.", bundle: .appLocalization))
        case .unknown, .resetting:
            return BluetoothHIDStatus(
                isEnabled: true,
                isConnected: false,
                pointerReady: false,
                absolutePointerReady: false,
                relativePointerReady: false,
                keyboardReady: false,
                consumerReady: false,
                canReconnectPairedHost: false,
                message: String(localized: "Starting Bluetooth control…", bundle: .appLocalization))
        default:
            return BluetoothHIDStatus(
                isEnabled: true,
                isConnected: false,
                pointerReady: false,
                absolutePointerReady: false,
                relativePointerReady: false,
                keyboardReady: false,
                consumerReady: false,
                canReconnectPairedHost: false,
                message: String(localized: "Bluetooth unavailable. Check power and permission.", bundle: .appLocalization))
        }

        guard published else {
            return BluetoothHIDStatus(
                isEnabled: true,
                isConnected: false,
                pointerReady: false,
                absolutePointerReady: false,
                relativePointerReady: false,
                keyboardReady: false,
                consumerReady: false,
                canReconnectPairedHost: false,
                message: String(localized: "Starting Bluetooth control…", bundle: .appLocalization))
        }

        if let host = connections.preferredInputHost(matching: savedHostID) {
            let reports = connections.subscribedReports(for: host)
            let absReady = reports.contains(.absolutePointer)
            let relReady = reports.contains(.relativeMouse)
            let kbReady = reports.contains(.keyboard)
            let consReady = reports.contains(.consumer)
            let ptrReady = absReady || relReady
            let message: String
            if ptrReady && kbReady {
                message = String(localized: "Bluetooth control connected", bundle: .appLocalization)
            } else if ptrReady {
                message = String(localized: "Bluetooth pointer connected", bundle: .appLocalization)
            } else {
                message = String(localized: "Connected — enable AssistiveTouch on iPhone for pointer", bundle: .appLocalization)
            }
            return BluetoothHIDStatus(
                isEnabled: true,
                isConnected: true,
                pointerReady: ptrReady,
                absolutePointerReady: absReady,
                relativePointerReady: relReady,
                keyboardReady: kbReady,
                consumerReady: consReady,
                canReconnectPairedHost: false,
                message: message)
        }

        let isReconnecting = !reconnectTracker.reconnectingHosts(activeSessions: Set(connections.sessions.keys)).isEmpty
        let message: String
        if isReconnecting {
            message = String(localized: "Reconnecting to paired iPhone…", bundle: .appLocalization)
        } else if let btName = controllerBluetoothName, btName != localName {
            message = String.localizedStringWithFormat(
                String(localized: "Pair “%@” (or “%@”) in iPhone AssistiveTouch → Bluetooth Devices", bundle: .appLocalization),
                localName, btName)
        } else {
            message = String.localizedStringWithFormat(
                String(localized: "Pair “%@” in iPhone AssistiveTouch → Bluetooth Devices", bundle: .appLocalization),
                localName)
        }
        return BluetoothHIDStatus(
            isEnabled: true,
            isConnected: false,
            pointerReady: false,
            absolutePointerReady: false,
            relativePointerReady: false,
            keyboardReady: false,
            consumerReady: false,
            canReconnectPairedHost: savedHostID != nil,
            message: message)
    }

    private func publishStatusOnQueue() {
        let status = snapshotStatusOnQueue()
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChange?(status)
        }
    }
}

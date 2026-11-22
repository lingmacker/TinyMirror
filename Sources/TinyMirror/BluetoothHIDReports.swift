import AppKit
import CoreGraphics
import Foundation

/// Report IDs live in the Report Reference descriptor (0x2908), so notification
/// payloads omit the leading report ID byte.
enum HIDReportID: UInt8, CaseIterable, Hashable {
    case keyboard = 1
    case absolutePointer = 2
    case relativeMouse = 3
    case consumer = 4

    var reportLength: Int {
        switch self {
        case .keyboard: return 8
        case .absolutePointer: return 5
        case .relativeMouse: return 4
        case .consumer: return 2
        }
    }
}

/// HID over GATT report descriptors modeled on two isolated HID services:
/// primary service exposes keyboard + relative mouse (with wheel) + consumer controls,
/// while a dedicated second HID service exposes the absolute pointer alone so iOS
/// AssistiveTouch does not route held absolute touches as relative mouse input.
enum HIDReportMap {
    static let absoluteMax: Int = 32767

    static let primaryReports: [HIDReportID] = [.keyboard, .relativeMouse, .consumer]
    static let absoluteReports: [HIDReportID] = [.absolutePointer]

    static func descriptor(for reports: [HIDReportID]) -> [UInt8] {
        reports.flatMap { id in
            switch id {
            case .keyboard: return keyboard
            case .absolutePointer: return absolutePointer
            case .relativeMouse: return relativeMouse
            case .consumer: return consumer
            }
        }
    }

    // 8-byte input: modifiers, reserved, 6 key codes. 1-byte LED output.
    static let keyboard: [UInt8] = [
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,
        0x85, HIDReportID.keyboard.rawValue,
        0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
        0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65,
        0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
        0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02,
        0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
        0xC0,
    ]

    // 5-byte input: 3 buttons + 5 padding bits, X (u16), Y (u16) in 0...32767.
    static let absolutePointer: [UInt8] = [
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01,
        0x85, HIDReportID.absolutePointer.rawValue,
        0x09, 0x01, 0xA1, 0x00,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01,
        0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x05, 0x81, 0x01,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31,
        0x16, 0x00, 0x00, 0x26, 0xFF, 0x7F,
        0x75, 0x10, 0x95, 0x02, 0x81, 0x02,
        0xC0, 0xC0,
    ]

    // 4-byte input: 3 buttons + 5 padding bits, dX, dY, wheel (signed bytes).
    static let relativeMouse: [UInt8] = [
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01,
        0x85, HIDReportID.relativeMouse.rawValue,
        0x09, 0x01, 0xA1, 0x00,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01,
        0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x05, 0x81, 0x01,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38,
        0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06,
        0xC0, 0xC0,
    ]

    // 2-byte input: one 16-bit consumer usage (Home is 0x0223).
    static let consumer: [UInt8] = [
        0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01,
        0x85, HIDReportID.consumer.rawValue,
        0x15, 0x00, 0x26, 0xFF, 0x03, 0x19, 0x00, 0x2A, 0xFF, 0x03,
        0x75, 0x10, 0x95, 0x01, 0x81, 0x00,
        0xC0,
    ]
}

/// Byte payload builders corresponding to `HIDReportMap`.
enum HIDReportPayload {
    static let consumerHome: UInt16 = 0x0223

    static func keyboard(modifiers: UInt8 = 0, code: UInt8 = 0) -> [UInt8] {
        [modifiers, 0, code, 0, 0, 0, 0, 0]
    }

    static func absolutePointer(buttons: UInt8, x: UInt16, y: UInt16) -> [UInt8] {
        [buttons, UInt8(x & 0xFF), UInt8(x >> 8), UInt8(y & 0xFF), UInt8(y >> 8)]
    }

    static func absolutePointer(buttons: UInt8, normalizedX: Double, normalizedY: Double) -> [UInt8] {
        let maxValue = Double(HIDReportMap.absoluteMax)
        let clampedX = UInt16(max(0, min(maxValue, (normalizedX * maxValue).rounded())))
        let clampedY = UInt16(max(0, min(maxValue, (normalizedY * maxValue).rounded())))
        return absolutePointer(buttons: buttons, x: clampedX, y: clampedY)
    }

    static func relativeMouse(buttons: UInt8, dx: Int = 0, dy: Int = 0, wheel: Int = 0) -> [UInt8] {
        let clampedX = max(-127, min(127, dx))
        let clampedY = max(-127, min(127, dy))
        let clampedWheel = max(-127, min(127, wheel))
        return [
            buttons,
            UInt8(bitPattern: Int8(clampedX)),
            UInt8(bitPattern: Int8(clampedY)),
            UInt8(bitPattern: Int8(clampedWheel)),
        ]
    }

    static func consumer(_ usage: UInt16) -> [UInt8] {
        [UInt8(usage & 0xFF), UInt8(usage >> 8)]
    }
}

/// US keyboard layout, HID usage page 0x07.
enum HIDKeyboardMap {
    struct Stroke: Equatable {
        let code: UInt8
        let modifiers: UInt8
    }

    static let shift: UInt8 = 0x02

    static let modifiers: [String: UInt8] = [
        "ctrl": 0x01, "control": 0x01,
        "shift": 0x02,
        "alt": 0x04, "option": 0x04,
        "cmd": 0x08, "command": 0x08,
    ]

    static let named: [String: UInt8] = [
        "enter": 0x28, "return": 0x28, "escape": 0x29, "esc": 0x29,
        "backspace": 0x2A, "delete": 0x2A, "tab": 0x2B, "space": 0x2C,
        "capslock": 0x39, "caps_lock": 0x39,
        "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52,
        "forwarddelete": 0x4C, "home": 0x4A, "end": 0x4D, "pageup": 0x4B, "pagedown": 0x4E,
    ]

    private static let plain: [Character: UInt8] = {
        var map: [Character: UInt8] = [:]
        for (index, character) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            map[character] = 0x04 + UInt8(index)
        }
        for (index, character) in "1234567890".enumerated() {
            map[character] = 0x1E + UInt8(index)
        }
        let rest: [(Character, UInt8)] = [
            ("\n", 0x28), ("\t", 0x2B), (" ", 0x2C), ("-", 0x2D), ("=", 0x2E), ("[", 0x2F), ("]", 0x30),
            ("\\", 0x31), (";", 0x33), ("'", 0x34), ("`", 0x35), (",", 0x36), (".", 0x37), ("/", 0x38),
        ]
        for (character, code) in rest { map[character] = code }
        return map
    }()

    private static let shifted: [Character: Character] = {
        var map: [Character: Character] = [:]
        for character in "abcdefghijklmnopqrstuvwxyz" {
            map[Character(character.uppercased())] = character
        }
        for (upper, lower) in zip("!@#$%^&*()_+{}|:\"~<>?", "1234567890-=[]\\;'`,./") {
            map[upper] = lower
        }
        return map
    }()

    static func code(for name: String) -> UInt8? {
        if let code = named[name.lowercased()] { return code }
        guard name.count == 1, let character = name.first else { return nil }
        return stroke(for: character)?.code
    }

    static func modifierMask(for names: [String]) -> UInt8? {
        var mask: UInt8 = 0
        for name in names {
            guard let bit = modifiers[name.lowercased()] else { return nil }
            mask |= bit
        }
        return mask
    }

    static func stroke(for character: Character) -> Stroke? {
        if let code = plain[character] { return Stroke(code: code, modifiers: 0) }
        if let base = shifted[character], let code = plain[base] {
            return Stroke(code: code, modifiers: shift)
        }
        return nil
    }
}

/// Computes the exact aspect-fit picture rectangle matching `AVSampleBufferDisplayLayer`
/// with `.resizeAspect` and maps AppKit bottom-left coordinates to HID top-left `[0, 1]`.
struct MirrorControlLayout: Equatable {
    let imageRect: CGRect

    init?(videoSize: CGSize, bounds: CGRect) {
        guard videoSize.width.isFinite, videoSize.height.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              videoSize.width > 0, videoSize.height > 0,
              bounds.width > 0, bounds.height > 0
        else { return nil }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let fitted = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        imageRect = CGRect(
            x: bounds.midX - fitted.width / 2,
            y: bounds.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height)
    }

    func normalizedPoint(_ point: CGPoint, clamp: Bool = false) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        guard clamp || imageRect.contains(point) else { return nil }
        let clampedX = max(imageRect.minX, min(imageRect.maxX, point.x))
        let clampedY = max(imageRect.minY, min(imageRect.maxY, point.y))
        return CGPoint(
            x: (clampedX - imageRect.minX) / imageRect.width,
            y: (imageRect.maxY - clampedY) / imageRect.height)
    }
}

enum MirrorKeyboardCommand: Equatable {
    case key(String, modifiers: [String])
    case text(String, modifiers: [String])
}

struct MirrorKeyboardEvent {
    let keyCode: UInt16
    let modifierFlags: NSEvent.ModifierFlags
    let characters: String?
    let charactersIgnoringModifiers: String?

    init(_ event: NSEvent) {
        self.init(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers)
    }

    init(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = [],
        characters: String? = nil,
        charactersIgnoringModifiers: String? = nil
    ) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
    }

    var isPasteShortcut: Bool {
        modifierFlags.contains(.command) && charactersIgnoringModifiers?.lowercased() == "v"
    }

    var command: MirrorKeyboardCommand? {
        let modifiers = modifierNames
        if let key = Self.specialKeys[keyCode] {
            return .key(key, modifiers: modifiers)
        }
        if isPasteShortcut {
            return .key("v", modifiers: ["cmd"])
        }
        let hasShortcutModifier = modifiers.contains { ["cmd", "alt", "ctrl"].contains($0) }
        let text = (hasShortcutModifier ? charactersIgnoringModifiers : characters) ?? ""
        guard !text.isEmpty else { return nil }
        return .text(text, modifiers: hasShortcutModifier ? modifiers : [])
    }

    private var modifierNames: [String] {
        var names: [String] = []
        if modifierFlags.contains(.command) { names.append("cmd") }
        if modifierFlags.contains(.shift) { names.append("shift") }
        if modifierFlags.contains(.option) { names.append("alt") }
        if modifierFlags.contains(.control) { names.append("ctrl") }
        return names
    }

    private static let specialKeys: [UInt16: String] = [
        0x24: "enter", 0x4C: "enter", 0x30: "tab", 0x31: "space",
        0x33: "backspace", 0x75: "forwarddelete", 0x35: "escape",
        0x7B: "left", 0x7C: "right", 0x7D: "down", 0x7E: "up",
        0x73: "home", 0x77: "end", 0x74: "pageup", 0x79: "pagedown",
    ]
}

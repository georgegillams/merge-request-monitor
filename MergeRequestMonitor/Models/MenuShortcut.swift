//
//  MenuShortcut.swift
//  MergeRequestMonitor
//

import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut. Absent means the popover has no shortcut.
struct MenuShortcut: Equatable, Codable {
    let keyCode: UInt16
    /// Command, shift, option, and control bits from `NSEvent.ModifierFlags`.
    let modifiers: UInt

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.recordedModifiers)
    }

    /// Symbols then the key, in the same order as macOS menus.
    var displayString: String {
        var label = ""
        let flags = modifierFlags
        if flags.contains(.control) { label += "⌃" }
        if flags.contains(.option) { label += "⌥" }
        if flags.contains(.shift) { label += "⇧" }
        if flags.contains(.command) { label += "⌘" }
        label += Self.keyLabel(for: keyCode)
        return label
    }

    /// Carbon modifier mask for `RegisterEventHotKey`.
    var carbonModifiers: UInt32 {
        var carbon: UInt32 = 0
        let flags = modifierFlags
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }

    init?(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .intersection(Self.recordedModifiers)
        guard Self.isAcceptable(keyCode: keyCode, modifiers: flags) else { return nil }
        self.keyCode = keyCode
        self.modifiers = flags.rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        let rawModifiers = try container.decode(UInt.self, forKey: .modifiers)
        let flags = NSEvent.ModifierFlags(rawValue: rawModifiers).intersection(Self.recordedModifiers)
        guard Self.isAcceptable(keyCode: keyCode, modifiers: flags) else {
            throw DecodingError.dataCorruptedError(
                forKey: .keyCode,
                in: container,
                debugDescription: "Shortcut cannot be used as a global hotkey."
            )
        }
        self.keyCode = keyCode
        self.modifiers = flags.rawValue
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers, forKey: .modifiers)
    }

    /// Shift alone is rejected: it would swallow ordinary typing. Function keys may stand alone.
    static func isAcceptable(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        if modifierKeyCodes.contains(keyCode) { return false }
        let flags = modifiers.intersection(recordedModifiers)
        if flags.contains(.command) || flags.contains(.option) || flags.contains(.control) {
            return true
        }
        return functionKeyCodes.contains(keyCode)
    }

    private static let recordedModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    /// Virtual key codes for keys that are themselves modifiers (HIToolbox `Events.h`).
    private static let modifierKeyCodes: Set<UInt16> = [
        0x36, 0x37, // command
        0x38, 0x3C, // shift
        0x3A, 0x3D, // option
        0x3B, 0x3E, // control
        0x39, // caps lock
        0x3F // fn
    ]

    private static let functionKeyCodes: Set<UInt16> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F, // F1–F12
        0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A // F13–F20
    ]

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case modifiers
    }

    private static func keyLabel(for keyCode: UInt16) -> String {
        if let special = specialKeyLabels[keyCode] {
            return special
        }
        if let translated = translatedKeyLabel(for: keyCode) {
            return translated
        }
        if let fallback = ansiFallback[keyCode] {
            return fallback
        }
        return "Key \(keyCode)"
    }

    /// Current keyboard layout, so a non-US layout shows the character on the key.
    private static func translatedKeyLabel(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawLayout).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )
        guard status == noErr, length > 0 else { return nil }
        return printableLabel(String(utf16CodeUnits: chars, count: length))
    }

    private static func printableLabel(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        guard !cleaned.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics
            .union(.punctuationCharacters)
            .union(.symbols)
        guard cleaned.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        if cleaned.rangeOfCharacter(from: .letters) != nil, cleaned.count == 1 {
            return cleaned.uppercased()
        }
        return cleaned
    }

    private static let specialKeyLabels: [UInt16: String] = [
        0x24: "↩",
        0x30: "⇥",
        0x31: "Space",
        0x33: "⌫",
        0x35: "⎋",
        0x4C: "⌅",
        0x47: "⌧",
        0x72: "Help",
        0x73: "↖",
        0x74: "⇞",
        0x75: "⌦",
        0x77: "↘",
        0x79: "⇟",
        0x7B: "←",
        0x7C: "→",
        0x7D: "↓",
        0x7E: "↑",
        0x7A: "F1",
        0x78: "F2",
        0x63: "F3",
        0x76: "F4",
        0x60: "F5",
        0x61: "F6",
        0x62: "F7",
        0x64: "F8",
        0x65: "F9",
        0x6D: "F10",
        0x67: "F11",
        0x6F: "F12",
        0x69: "F13",
        0x6B: "F14",
        0x71: "F15",
        0x6A: "F16",
        0x40: "F17",
        0x4F: "F18",
        0x50: "F19",
        0x5A: "F20"
    ]

    /// US ANSI labels used only when the active layout cannot be read.
    private static let ansiFallback: [UInt16: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
        0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
        0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T",
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5",
        0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0",
        0x1E: "]", 0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P",
        0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";", 0x2A: "\\",
        0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x32: "`"
    ]
}

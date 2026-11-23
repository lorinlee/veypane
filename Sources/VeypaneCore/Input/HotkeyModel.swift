import Foundation

public struct HotkeyModifiers: OptionSet, Codable, Equatable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let control = HotkeyModifiers(rawValue: 1 << 0)
    public static let option  = HotkeyModifiers(rawValue: 1 << 1)
    public static let shift   = HotkeyModifiers(rawValue: 1 << 2)
    public static let command = HotkeyModifiers(rawValue: 1 << 3)

    /// Carbon Event Manager modifier mask (`cmdKey = 256`, `shiftKey = 512`, `optionKey = 2048`, `controlKey = 4096`).
    public var carbonFlags: UInt32 {
        var mask: UInt32 = 0
        if contains(.command) { mask |= 256 }
        if contains(.shift)   { mask |= 512 }
        if contains(.option)  { mask |= 2048 }
        if contains(.control) { mask |= 4096 }
        return mask
    }

    public init(carbonFlags: UInt32) {
        var mods: HotkeyModifiers = []
        if (carbonFlags & 256) != 0  { mods.insert(.command) }
        if (carbonFlags & 512) != 0  { mods.insert(.shift) }
        if (carbonFlags & 2048) != 0 { mods.insert(.option) }
        if (carbonFlags & 4096) != 0 { mods.insert(.control) }
        self = mods
    }

    public var symbolString: String {
        var out = ""
        if contains(.control) { out += "⌃" }
        if contains(.option)  { out += "⌥" }
        if contains(.shift)   { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }
}

public struct HotkeyBinding: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: HotkeyModifiers

    public init(keyCode: UInt32, modifiers: HotkeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Default toggle hotkey per SPEC.md #3: `⌃`` (Control + Grave Accent, virtual key code 0x32 = 50).
    public static let defaultToggle = HotkeyBinding(keyCode: 0x32, modifiers: [.control])

    public var displayString: String {
        "\(modifiers.symbolString)\(HotkeyCatalog.keyName(for: keyCode))"
    }
}

public enum HotkeyParseError: Error, Equatable, Sendable {
    case emptyInput
    case missingModifiers
    case unknownKey(String)
}

public enum HotkeyCatalog {
    private static let codeToLabel: [UInt32: String] = [
        0x32: "`",
        0x31: "Space",
        0x24: "Return",
        0x30: "Tab",
        0x35: "Esc",
        0x33: "Delete",
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E",
        0x03: "F", 0x05: "G", 0x04: "H", 0x22: "I", 0x26: "J",
        0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O",
        0x23: "P", 0x0C: "Q", 0x0F: "R", 0x01: "S", 0x11: "T",
        0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X", 0x10: "Y",
        0x06: "Z",
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4",
        0x17: "5", 0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9",
        0x1B: "-", 0x18: "=", 0x21: "[", 0x1E: "]", 0x2A: "\\",
        0x29: ";", 0x27: "'", 0x2B: ",", 0x2F: ".", 0x2C: "/",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4",
        0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
        0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x7B: "Left", 0x7C: "Right", 0x7D: "Down", 0x7E: "Up"
    ]

    private static let tokenToCode: [String: UInt32] = {
        var map: [String: UInt32] = [:]
        for (code, label) in codeToLabel {
            map[label.lowercased()] = code
        }
        map["grave"] = 0x32
        map["backtick"] = 0x32
        map["tilde"] = 0x32
        map["~"] = 0x32
        map["spacebar"] = 0x31
        map["enter"] = 0x24
        map["escape"] = 0x35
        map["backspace"] = 0x33
        map["←"] = 0x7B
        map["→"] = 0x7C
        map["↓"] = 0x7D
        map["↑"] = 0x7E
        return map
    }()

    public static func keyName(for keyCode: UInt32) -> String {
        codeToLabel[keyCode] ?? String(format: "Key0x%02X", keyCode)
    }

    public static func keyCode(for token: String) -> UInt32? {
        tokenToCode[token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    /// Parses strings like `"⌃`"`, `"Ctrl+`"`, `"⌘⇧Space"`, `"Cmd+Option+S"`, or `"F12"`.
    public static func parse(_ raw: String, requireModifierUnlessFunctionKey: Bool = true) throws -> HotkeyBinding {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HotkeyParseError.emptyInput
        }

        var modifiers: HotkeyModifiers = []
        var remainder = ""

        // Extract leading/inline modifier symbols first (`⌃`, `⌥`, `⇧`, `⌘`)
        for scalar in trimmed {
            switch scalar {
            case "⌃": modifiers.insert(.control)
            case "⌥": modifiers.insert(.option)
            case "⇧": modifiers.insert(.shift)
            case "⌘": modifiers.insert(.command)
            default: remainder.append(scalar)
            }
        }

        // Split remaining text by `+` or `-` when used as modifier separator (careful with `-` key itself)
        let parts: [String]
        if remainder.contains("+") {
            let rawParts = remainder.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            // Handle trailing `+` meaning `=`/`+` key if applicable, otherwise filter empty
            parts = rawParts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        } else {
            parts = [remainder]
        }

        var keyToken: String?
        for part in parts {
            let token = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty { continue }
            switch token.lowercased() {
            case "ctrl", "control", "ctl":
                modifiers.insert(.control)
            case "opt", "option", "alt":
                modifiers.insert(.option)
            case "shift", "shft":
                modifiers.insert(.shift)
            case "cmd", "command", "super", "meta":
                modifiers.insert(.command)
            default:
                keyToken = token
            }
        }

        guard let resolvedToken = keyToken, !resolvedToken.isEmpty else {
            throw HotkeyParseError.unknownKey("")
        }

        guard let code = keyCode(for: resolvedToken) else {
            throw HotkeyParseError.unknownKey(resolvedToken)
        }

        let isFunctionKey = [
            UInt32(0x7A), 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F
        ].contains(code)

        if requireModifierUnlessFunctionKey && modifiers.isEmpty && !isFunctionKey {
            throw HotkeyParseError.missingModifiers
        }

        return HotkeyBinding(keyCode: code, modifiers: modifiers)
    }
}

/// Standard macOS responder-chain text/document editing commands (`Edit` menu nil-target selectors).
/// Must never be intercepted by app or browser-extension shortcuts so native responder chains handle them.
public enum StandardEditCommand: String, CaseIterable, Codable, Equatable, Sendable {
    case undo
    case redo
    case cut
    case copy
    case paste
    case selectAll

    public var selectorName: String {
        switch self {
        case .undo: "undo:"
        case .redo: "redo:"
        case .cut: "cut:"
        case .copy: "copy:"
        case .paste: "paste:"
        case .selectAll: "selectAll:"
        }
    }

    public var keyEquivalent: String {
        switch self {
        case .undo, .redo: "z"
        case .cut: "x"
        case .copy: "c"
        case .paste: "v"
        case .selectAll: "a"
        }
    }

    public var requiresShift: Bool {
        self == .redo
    }

    public static func match(
        modifiers: HotkeyModifiers,
        charactersIgnoringModifiers: String?,
        keyCode: UInt16? = nil
    ) -> StandardEditCommand? {
        let normalizedChar: String = {
            let trimmed = (charactersIgnoringModifiers ?? "").lowercased()
            if !trimmed.isEmpty { return trimmed }
            switch keyCode {
            case 0x00: return "a"
            case 0x06: return "z"
            case 0x07: return "x"
            case 0x08: return "c"
            case 0x09: return "v"
            default: return ""
            }
        }()

        if modifiers == [.command] {
            switch normalizedChar {
            case "z": return .undo
            case "x": return .cut
            case "c": return .copy
            case "v": return .paste
            case "a": return .selectAll
            default: return nil
            }
        }
        if modifiers == [.command, .shift], normalizedChar == "z" {
            return .redo
        }
        return nil
    }
}

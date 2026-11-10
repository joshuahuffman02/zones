import Carbon
import CoreGraphics

/// Parses "ctrl+opt+shift+left" style strings.
enum KeySpec {
    static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
        "=": kVK_ANSI_Equal, "-": kVK_ANSI_Minus, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, ";": kVK_ANSI_Semicolon,
        "'": kVK_ANSI_Quote, "`": kVK_ANSI_Grave, "\\": kVK_ANSI_Backslash,
        "space": kVK_Space, "return": kVK_Return, "tab": kVK_Tab,
        "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
    ]

    static let symbols: [String: String] = [
        "left": "←", "right": "→", "up": "↑", "down": "↓", "space": "Space", "return": "↩", "tab": "⇥",
    ]

    /// Returns (key code, Carbon modifiers) or nil if the string can't be parsed.
    static func parse(_ spec: String) -> (UInt32, UInt32)? {
        var mods: UInt32 = 0
        var key: Int?
        for part in spec.lowercased().split(separator: "+") {
            let p = String(part)
            switch p {
            case "cmd", "command": mods |= UInt32(cmdKey)
            case "ctrl", "control": mods |= UInt32(controlKey)
            case "opt", "option", "alt": mods |= UInt32(optionKey)
            case "shift": mods |= UInt32(shiftKey)
            default:
                guard key == nil, let k = keyCodes[p] else { return nil }
                key = k
            }
        }
        guard let k = key, mods != 0 else { return nil }
        return (UInt32(k), mods)
    }

    /// "⌃⌥⇧←" for menus.
    static func display(_ spec: String) -> String {
        var out = ""
        var key = ""
        for part in spec.lowercased().split(separator: "+") {
            switch part {
            case "ctrl", "control": out += "⌃"
            case "opt", "option", "alt": out += "⌥"
            case "shift": out += "⇧"
            case "cmd", "command": out += "⌘"
            default: key = symbols[String(part)] ?? part.uppercased()
            }
        }
        return out + key
    }

    /// CGEventFlags for a modifier-only string like "ctrl+opt".
    static func flags(_ spec: String) -> CGEventFlags? {
        var f: CGEventFlags = []
        for part in spec.lowercased().split(separator: "+") {
            switch part {
            case "cmd", "command": f.insert(.maskCommand)
            case "ctrl", "control": f.insert(.maskControl)
            case "opt", "option", "alt": f.insert(.maskAlternate)
            case "shift": f.insert(.maskShift)
            default: return nil
            }
        }
        return f.isEmpty ? nil : f
    }
}

/// Global hotkeys through Carbon. Needs no extra permission beyond what the app already has.
final class HotKeyCenter {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard err == noErr else { return err }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            center.actions[hk.id]?()
            return noErr
        }, 1, &spec, me, &handler)
    }

    /// Returns false if the system refused the combination (usually already taken).
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x5354_5250), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        actions[id] = action
        return true
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }
}

import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Acts on other apps: accessibility actions on elements, and synthesized mouse and keyboard events
/// (which need the same Accessibility permission Xamine already has for reading).
enum InputSynthesizer {
    struct Key: Sendable {
        let code: CGKeyCode
        /// How the key is written in XCUITest: an `XCUIKeyboardKey` member or a string literal.
        let xcuiName: String
    }

    // MARK: - Accessibility actions

    static func actions(of element: AXElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element.raw, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    static func perform(_ action: String, on element: AXElement) -> Bool {
        AXUIElementPerformAction(element.raw, action as CFString) == .success
    }

    static func focus(_ element: AXElement) -> Bool {
        AXUIElementSetAttributeValue(element.raw, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    /// Brings the app forward and raises the element's window, so synthesized events land on it.
    static func bringForward(pid: pid_t, window: AXElement?) async {
        if let window { _ = perform(kAXRaiseAction, on: window) }
        let app = NSRunningApplication(processIdentifier: pid)
        if app?.isActive != true {
            app?.activate()
            // Activation is asynchronous; give the window server a moment.
            for _ in 0..<20 where NSRunningApplication(processIdentifier: pid)?.isActive != true {
                try? await Task.sleep(for: .milliseconds(50))
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Mouse

    static func click(at point: CGPoint) async {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(50))
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(30))
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(150))
    }

    static func scroll(at point: CGPoint, dx: Int32, dy: Int32) async {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(50))
        let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        event?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - Keyboard

    static func type(_ text: String) async {
        let source = CGEventSource(stateID: .hidSystemState)
        for character in text {
            let units = Array(String(character).utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.flags = []
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event?.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(12))
        }
        try? await Task.sleep(for: .milliseconds(150))
    }

    static func press(_ key: Key, modifiers: [String]) async {
        let source = CGEventSource(stateID: .hidSystemState)
        let flags = modifierFlags(modifiers)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(150))
    }

    static let modifierNames = ["command", "shift", "option", "control"]

    static func modifierFlags(_ modifiers: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option": flags.insert(.maskAlternate)
            case "control": flags.insert(.maskControl)
            default: break
            }
        }
        return flags
    }

    /// Normalizes "cmd, Shift" → ["command", "shift"]; `nil` if one isn't recognized.
    static func parseModifiers(_ string: String?) -> [String]? {
        guard let string, !string.isEmpty else { return [] }
        let aliases = ["cmd": "command", "⌘": "command", "opt": "option", "alt": "option", "⌥": "option", "ctrl": "control", "⌃": "control", "⇧": "shift"]
        var result: [String] = []
        for part in string.split(whereSeparator: { $0 == "," || $0 == "+" || $0 == " " }) {
            let name = aliases[part.lowercased()] ?? part.lowercased()
            guard modifierNames.contains(name) else { return nil }
            if !result.contains(name) { result.append(name) }
        }
        return result
    }

    /// A named key (return, escape, up…) or a single letter, digit or punctuation character.
    static func key(named name: String) -> Key? {
        let named: [String: (Int, String)] = [
            "return": (kVK_Return, ".return"), "enter": (kVK_Return, ".return"),
            "escape": (kVK_Escape, ".escape"), "esc": (kVK_Escape, ".escape"),
            "tab": (kVK_Tab, ".tab"), "space": (kVK_Space, ".space"),
            "delete": (kVK_Delete, ".delete"), "backspace": (kVK_Delete, ".delete"),
            "forwarddelete": (kVK_ForwardDelete, ".forwardDelete"),
            "up": (kVK_UpArrow, ".upArrow"), "uparrow": (kVK_UpArrow, ".upArrow"),
            "down": (kVK_DownArrow, ".downArrow"), "downarrow": (kVK_DownArrow, ".downArrow"),
            "left": (kVK_LeftArrow, ".leftArrow"), "leftarrow": (kVK_LeftArrow, ".leftArrow"),
            "right": (kVK_RightArrow, ".rightArrow"), "rightarrow": (kVK_RightArrow, ".rightArrow"),
            "home": (kVK_Home, ".home"), "end": (kVK_End, ".end"),
            "pageup": (kVK_PageUp, ".pageUp"), "pagedown": (kVK_PageDown, ".pageDown"),
        ]
        if let (code, xcui) = named[name.lowercased()] { return Key(code: CGKeyCode(code), xcuiName: xcui) }
        guard name.count == 1, let code = characterCodes[name.lowercased()] else { return nil }
        return Key(code: CGKeyCode(code), xcuiName: QueryBuilder.literal(name.lowercased()))
    }

    private static let characterCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, ";": kVK_ANSI_Semicolon,
        "'": kVK_ANSI_Quote, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "-": kVK_ANSI_Minus,
        "=": kVK_ANSI_Equal, "`": kVK_ANSI_Grave, "\\": kVK_ANSI_Backslash,
    ]
}

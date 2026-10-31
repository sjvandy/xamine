import AppKit
import Carbon.HIToolbox
import SwiftUI

struct Shortcut: Codable, Equatable, Sendable {
    var keyCode: Int
    var modifiers: Int
    var key: String

    static let inspectDefault = Shortcut(keyCode: kVK_ANSI_X, modifiers: cmdKey | shiftKey, key: "x")
    static let handsOffDefault = Shortcut(keyCode: kVK_ANSI_X, modifiers: cmdKey | shiftKey | optionKey, key: "x")

    var displayString: String {
        var text = ""
        if modifiers & controlKey != 0 { text += "⌃" }
        if modifiers & optionKey != 0 { text += "⌥" }
        if modifiers & shiftKey != 0 { text += "⇧" }
        if modifiers & cmdKey != 0 { text += "⌘" }
        return text + key.uppercased()
    }

    var keyEquivalent: KeyEquivalent {
        KeyEquivalent(key.first ?? "x")
    }

    var eventModifiers: SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        if modifiers & controlKey != 0 { result.insert(.control) }
        if modifiers & optionKey != 0 { result.insert(.option) }
        if modifiers & shiftKey != 0 { result.insert(.shift) }
        if modifiers & cmdKey != 0 { result.insert(.command) }
        return result
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var result = 0
        if flags.contains(.control) { result |= controlKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.shift) { result |= shiftKey }
        if flags.contains(.command) { result |= cmdKey }
        return result
    }
}

enum ShortcutAction: String, CaseIterable {
    case inspect = "inspectShortcut"
    case handsOff = "handsOffShortcut"

    var defaultShortcut: Shortcut {
        switch self {
        case .inspect: .inspectDefault
        case .handsOff: .handsOffDefault
        }
    }
}

@Observable @MainActor
final class ShortcutStore {
    static let shared = ShortcutStore()

    private(set) var inspect: Shortcut
    private(set) var handsOff: Shortcut

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        inspect = Self.load(.inspect, from: defaults)
        handsOff = Self.load(.handsOff, from: defaults)
    }

    func shortcut(for action: ShortcutAction) -> Shortcut {
        switch action {
        case .inspect: inspect
        case .handsOff: handsOff
        }
    }

    func conflictingAction(for shortcut: Shortcut, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && Self.sameBinding(self.shortcut(for: $0), shortcut) }
    }

    @discardableResult
    func set(_ shortcut: Shortcut, for action: ShortcutAction) -> Bool {
        guard conflictingAction(for: shortcut, excluding: action) == nil else { return false }
        apply(shortcut, for: action)
        return true
    }

    func reset(_ action: ShortcutAction) {
        apply(action.defaultShortcut, for: action)
    }

    func resetAll() {
        ShortcutAction.allCases.forEach(reset)
    }

    func revert(_ action: ShortcutAction, to shortcut: Shortcut) {
        apply(shortcut, for: action)
    }

    private func apply(_ shortcut: Shortcut, for action: ShortcutAction) {
        switch action {
        case .inspect: inspect = shortcut
        case .handsOff: handsOff = shortcut
        }
        if let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: action.rawValue)
        }
        onChange?()
    }

    private static func sameBinding(_ lhs: Shortcut, _ rhs: Shortcut) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    private static func load(_ action: ShortcutAction, from defaults: UserDefaults) -> Shortcut {
        guard let data = defaults.data(forKey: action.rawValue),
              let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) else {
            return action.defaultShortcut
        }
        return shortcut
    }
}

import AppKit
import SwiftUI

struct ShortcutRecorderView: View {
    let title: String
    let action: ShortcutAction
    let store: ShortcutStore

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        LabeledContent(title) {
            HStack {
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button(isRecording ? "Type shortcut…" : store.shortcut(for: action).displayString) {
                    isRecording ? stopRecording() : startRecording()
                }
                .frame(minWidth: 110)
                Button("Reset") {
                    changeShortcut(to: action.defaultShortcut)
                }
                .disabled(store.shortcut(for: action) == action.defaultShortcut)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        message = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = Int(event.keyCode)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
            MainActor.assumeIsolated {
                handle(keyCode: keyCode, flags: flags, characters: characters)
            }
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(keyCode: Int, flags: NSEvent.ModifierFlags, characters: String) {
        if keyCode == 53 {
            stopRecording()
            return
        }
        let modifiers = Shortcut.carbonModifiers(from: flags)
        guard modifiers != 0 else {
            message = "Include ⌘, ⌃ or ⌥"
            return
        }
        guard characters.count == 1, let scalar = characters.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar), scalar.value < 0xF700 else {
            message = "Unsupported key"
            return
        }
        changeShortcut(to: Shortcut(keyCode: keyCode, modifiers: modifiers, key: characters))
    }

    private func changeShortcut(to shortcut: Shortcut) {
        let previous = store.shortcut(for: action)
        if let other = store.conflictingAction(for: shortcut, excluding: action) {
            message = "Already used by \(other == .inspect ? "Pick a window" : "Inspect under cursor")"
            stopRecording()
            return
        }
        store.set(shortcut, for: action)
        if !AppState.shared.hotKeysRegistered {
            store.revert(action, to: previous)
            message = "In use by another app"
        } else {
            message = nil
        }
        stopRecording()
    }
}

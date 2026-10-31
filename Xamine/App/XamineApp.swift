import SwiftUI

@main
struct XamineApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: AppState.shared)
        } label: {
            MenuBarIcon(isAgentActive: AppState.shared.isAgentActive)
        }
        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if DebugDump.runIfRequested() { return }
        #endif
        AppState.shared.didLaunch()
    }

    /// Opening Xamine again while it's running starts the picker, like pressing ⌘⇧5.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppState.shared.startPicking()
        return false
    }
}

private struct MenuContent: View {
    let state: AppState
    let shortcuts = ShortcutStore.shared

    var body: some View {
        Button("Inspect Application…") { state.startPicking() }
            .keyboardShortcut(shortcuts.inspect.keyEquivalent, modifiers: shortcuts.inspect.eventModifiers)
        Button("Inspect Under Cursor") { state.startHandsOff(delay: 0) }
            .keyboardShortcut(shortcuts.handsOff.keyEquivalent, modifiers: shortcuts.handsOff.eventModifiers)
        Button("Inspect Under Cursor in 5 Seconds") { state.startHandsOff(delay: 5) }

        Button("Inspect iOS Device…") { state.showDevices() }

        if state.inspector.summary != nil {
            Button("Show Inspector") { state.showInspector() }
        }

        if !state.recents.isEmpty {
            Divider()
            Text("Recent")
            ForEach(state.recents, id: \.windowID) { recent in
                Button("\(recent.appName)\(recent.title.nonEmpty.map { " — \($0)" } ?? "")") {
                    state.inspect(recent)
                }
            }
        }

        #if DEBUG
        Divider()
        Toggle("Preview AI Agent Icon", isOn: Bindable(state).isAgentActive)
        #endif

        Divider()
        if !state.permissions.allGranted {
            Button("Grant Permissions…") { state.showOnboarding() }
        }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Check for Updates…") { Updater.shared.checkForUpdates() }
            .disabled(Updater.shared.isChecking)
        Button("Quit Xamine") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct SettingsView: View {
    @AppStorage("pickOnLaunch") private var pickOnLaunch = false

    var body: some View {
        Form {
            Toggle("Start picking a window when Xamine launches", isOn: $pickOnLaunch)
            Section("Shortcuts") {
                ShortcutRecorderView(title: "Pick a window", action: .inspect, store: ShortcutStore.shared)
                ShortcutRecorderView(title: "Inspect under cursor", action: .handsOff, store: ShortcutStore.shared)
                Button("Restore Defaults") { ShortcutStore.shared.resetAll() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}

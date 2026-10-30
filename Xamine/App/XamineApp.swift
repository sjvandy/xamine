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

    var body: some View {
        Button("Inspect Application…") { state.startPicking() }
            .keyboardShortcut("x", modifiers: [.command, .shift])
        Button("Inspect Under Cursor") { state.startHandsOff(delay: 0) }
            .keyboardShortcut("x", modifiers: [.command, .shift, .option])
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
        Button("Quit Xamine") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct SettingsView: View {
    @AppStorage("pickOnLaunch") private var pickOnLaunch = false

    var body: some View {
        Form {
            Toggle("Start picking a window when Xamine launches", isOn: $pickOnLaunch)
            LabeledContent("Pick a window", value: "⌘⇧X")
            LabeledContent("Inspect under cursor (Spotlight, Control Center, menus)", value: "⌥⌘⇧X")
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}

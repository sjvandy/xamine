import Carbon.HIToolbox
import SwiftUI

/// App-wide coordinator: owns the picker, the inspector window and permissions.
@Observable @MainActor
final class AppState {
    static let shared = AppState()

    let permissions = PermissionsManager()
    let inspector = InspectorModel()
    let devices = DeviceManager()
    private(set) var recents: [PickedWindow] = []
    /// True while an AI agent is driving Xamine; the menu bar icon turns into the blue AI pill.
    var isAgentActive = false

    @ObservationIgnored private let picker = WindowPickerController()
    @ObservationIgnored private var hotKeys: [HotKey] = []
    @ObservationIgnored private var inspectorWindow: NSWindow?
    @ObservationIgnored private var onboardingWindow: NSWindow?
    @ObservationIgnored private var devicesWindow: NSWindow?
    @ObservationIgnored private var windowCloseObserver: NSObjectProtocol?

    func didLaunch() {
        let shortcuts = ShortcutStore.shared
        hotKeys = [
            HotKey(keyCode: shortcuts.inspect.keyCode, modifiers: shortcuts.inspect.modifiers) { [weak self] in self?.startPicking() },
            HotKey(keyCode: shortcuts.handsOff.keyCode, modifiers: shortcuts.handsOff.modifiers) { [weak self] in self?.startHandsOff(delay: 0) },
        ]
        shortcuts.onChange = { [weak self] in self?.applyShortcuts() }
        // When a device scan can't reach the agent: reconnect, giving it a moment to relaunch, or start it again.
        inspector.recoverDevice = { [weak self] inspection in
            guard let self, devices.selectedDeviceID == inspection.deviceID else { return nil }
            if await devices.reconnect(wait: .seconds(8)) { return devices.client }
            inspectForeground(onDeviceID: inspection.deviceID, bundleID: inspection.bundleID)
            return nil
        }
        // So ⌘⇧X can offer a connected iPhone or iPad straight away, and drops it once it's gone.
        devices.devicesChanged = { [weak self] in
            guard let self else { return }
            picker.setDevices(pickerDevices)
        }
        devices.watchForDevices()
        if !permissions.allGranted {
            showOnboarding()
        } else if UserDefaults.standard.bool(forKey: "pickOnLaunch") {
            startPicking()
        }
    }

    var hotKeysRegistered: Bool { hotKeys.allSatisfy(\.isRegistered) }

    private func applyShortcuts() {
        let shortcuts = ShortcutStore.shared
        guard hotKeys.count == 2 else { return }
        hotKeys[0].update(keyCode: shortcuts.inspect.keyCode, modifiers: shortcuts.inspect.modifiers)
        hotKeys[1].update(keyCode: shortcuts.handsOff.keyCode, modifiers: shortcuts.handsOff.modifiers)
    }

    func startPicking() {
        permissions.refresh()
        guard permissions.allGranted else {
            showOnboarding()
            return
        }
        picker.start(devices: pickerDevices) { [weak self] deviceID in
            self?.inspectForeground(onDeviceID: deviceID)
        } completion: { [weak self] picked in
            guard let self else { return }
            if let picked { inspect(picked) }
        }
        // Devices are kept current by USB notifications; this catches anything they missed.
        Task { await devices.refreshDevices() }
    }

    private var pickerDevices: [WindowPickerController.Device] {
        devices.connectedDevices.map { .init(id: $0.id, name: $0.name, symbol: $0.symbol) }
    }

    /// Inspects the app in front on a device picked from the edge of the screen, starting its agent first if needed.
    /// `bundleID` keeps inspecting that app once the agent is up; `nil` follows the foreground app.
    func inspectForeground(onDeviceID id: String, bundleID: String? = nil) {
        devices.selectedDeviceID = id
        guard let device = devices.selectedDevice else { return }
        // The inspector shows a loading screen while the agent builds and launches, and what went wrong if it fails.
        if case .failed = devices.state { devices.stopAgent() } // clear an earlier failure
        inspector.beginDeviceLaunch(.init(deviceID: id, deviceName: device.name, symbol: device.symbol))
        showInspector()
        Task {
            if await !devices.reconnect() { await devices.startAgent() }
            // Picking something else or closing the inspector abandons the launch.
            guard inspector.deviceLaunch?.deviceID == id, devices.isAgentRunning, devices.selectedDeviceID == id else { return }
            inspectDevice(bundleID: bundleID)
        }
    }

    /// Inspects what's under the cursor without taking focus, so Spotlight, Control Center and open menus stay open.
    func startHandsOff(delay: Int) {
        permissions.refresh()
        guard permissions.allGranted else {
            showOnboarding()
            return
        }
        picker.startHandsOff(delay: delay) { [weak self] picked in
            guard let self else { return }
            if let picked { inspect(picked) }
        }
    }

    func inspect(_ target: PickedWindow) {
        if target.isAppWindow {
            recents.removeAll { $0.windowID == target.windowID }
            recents.insert(target, at: 0)
            recents = Array(recents.prefix(5))
            showInspector()
            Task { await inspector.load(target) }
        } else {
            // System UI closes as soon as Xamine takes focus, so read it before showing the inspector.
            Task {
                try? await Task.sleep(for: .milliseconds(60)) // let the picker overlay leave the screen
                await inspector.load(target)
                showInspector()
            }
        }
    }

    // MARK: - Windows

    func showInspector() {
        let window = inspectorWindow ?? makeWindow(
            title: "Xamine",
            size: NSSize(width: 1280, height: 800),
            content: InspectorView(
                model: inspector,
                devices: devices,
                pickAnother: { [weak self] in self?.startPicking() },
                startDevice: { [weak self] id in self?.inspectForeground(onDeviceID: id) },
                showDeviceSettings: { [weak self] in self?.showDevices() },
                cancelDeviceLaunch: { [weak self] in self?.inspectorWindow?.close() }
            )
        )
        window.setFrameAutosaveName("InspectorWindow")
        inspectorWindow = window
        present(window)
    }

    func showDevices() {
        let window = devicesWindow ?? makeWindow(
            title: "iOS Devices",
            size: NSSize(width: 560, height: 640),
            content: DeviceWindow(manager: devices) { [weak self] bundleID in self?.inspectDevice(bundleID: bundleID) }
        )
        devicesWindow = window
        present(window)
    }

    /// Opens the inspector on an app running on the device whose agent is up.
    func inspectDevice(bundleID: String?) {
        guard let client = devices.client, let device = devices.selectedDevice else { return }
        let inspection = DeviceInspection(
            client: client,
            deviceID: device.id,
            deviceName: device.name,
            symbol: device.symbol,
            bundleID: bundleID,
            candidates: devices.foregroundCandidates,
            appNames: Dictionary(devices.apps.map { ($0.bundleID, $0.name) }, uniquingKeysWith: { first, _ in first })
                .merging(["com.apple.springboard": "Home Screen"]) { current, _ in current }
        )
        showInspector()
        Task { await inspector.loadDevice(inspection) }
    }

    func showOnboarding() {
        let window = onboardingWindow ?? makeWindow(
            title: "Welcome to Xamine",
            size: NSSize(width: 480, height: 360),
            content: OnboardingView(permissions: permissions) { [weak self] in
                self?.onboardingWindow?.close()
                self?.startPicking()
            },
            resizable: false
        )
        onboardingWindow = window
        present(window)
    }

    private func makeWindow(title: String, size: NSSize, content: some View, resizable: Bool = true) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.formUnion([.resizable, .fullSizeContentView]) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: content)
        hosting.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = hosting
        window.setContentSize(size)
        window.center()
        return window
    }

    /// Shows a window and gives Xamine a Dock icon while any of its windows are open.
    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if windowCloseObserver == nil {
            windowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: nil, queue: .main
            ) { [weak self] notification in
                let closing = notification.object as? NSWindow
                MainActor.assumeIsolated { self?.windowWillClose(closing) }
            }
        }
    }

    private func windowWillClose(_ closing: NSWindow?) {
        if closing === inspectorWindow, inspector.deviceLaunch != nil {
            inspector.cancelDeviceLaunch()
            devices.stopAgent()
        }
        let others = [inspectorWindow, onboardingWindow, devicesWindow].compactMap { $0 }.filter { $0 !== closing && $0.isVisible }
        if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}

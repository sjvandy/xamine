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

    @ObservationIgnored private let picker = WindowPickerController()
    @ObservationIgnored private var hotKeys: [HotKey] = []
    @ObservationIgnored private var inspectorWindow: NSWindow?
    @ObservationIgnored private var onboardingWindow: NSWindow?
    @ObservationIgnored private var devicesWindow: NSWindow?
    @ObservationIgnored private var windowCloseObserver: NSObjectProtocol?

    func didLaunch() {
        hotKeys = [
            HotKey { [weak self] in self?.startPicking() },
            HotKey(modifiers: cmdKey | shiftKey | optionKey) { [weak self] in self?.startHandsOff(delay: 0) },
        ]
        if !permissions.allGranted {
            showOnboarding()
        } else if UserDefaults.standard.bool(forKey: "pickOnLaunch") {
            startPicking()
        }
    }

    func startPicking() {
        permissions.refresh()
        guard permissions.allGranted else {
            showOnboarding()
            return
        }
        picker.start { [weak self] picked in
            guard let self else { return }
            if let picked { inspect(picked) }
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
            // System UI closes as soon as xamine takes focus, so read it before showing the inspector.
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
            title: "xamine",
            size: NSSize(width: 1280, height: 800),
            content: InspectorView(model: inspector, pickAnother: { [weak self] in self?.startPicking() })
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
            deviceName: device.name,
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
            title: "Welcome to xamine",
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

    /// Shows a window and gives xamine a Dock icon while any of its windows are open.
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
        let others = [inspectorWindow, onboardingWindow, devicesWindow].compactMap { $0 }.filter { $0 !== closing && $0.isVisible }
        if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}

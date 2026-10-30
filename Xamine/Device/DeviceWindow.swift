import SwiftUI

/// Pick a device, start the on-device agent, then choose which app to inspect.
struct DeviceWindow: View {
    @Bindable var manager: DeviceManager
    /// Called with the chosen bundle ID, or `nil` to follow whatever app is in the foreground.
    var inspect: (String?) -> Void

    @State private var appSearch = ""
    @State private var selectedApp: String? = DeviceWindow.foregroundTag
    @State private var showLog = false

    static let foregroundTag = "__foreground__"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            deviceSection
            agentSection
            if manager.isAgentRunning { appSection }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 560)
        .task { await manager.refreshDevices() }
    }

    // MARK: - Device

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Device").font(.headline)
                Spacer()
                Button {
                    Task { await manager.refreshDevices() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(manager.isRefreshing)
            }

            if manager.devices.isEmpty {
                Text(manager.isRefreshing ? "Looking for devices…" : "No iOS devices found. Connect an iPhone with a cable, or boot a simulator.")
                    .foregroundStyle(.secondary)
            } else {
                // A list rather than a menu Picker: SwiftUI can build menu items off the main thread.
                List(manager.devices, selection: $manager.selectedDeviceID) { device in
                    HStack {
                        Image(systemName: device.isSimulator ? "macbook.and.iphone" : "iphone")
                            .frame(width: 20)
                        Text(device.name)
                        Spacer()
                        Text(device.summary)
                            .font(.callout)
                            .foregroundStyle(device.isConnected ? .secondary : .tertiary)
                    }
                    .tag(device.id)
                }
                .frame(height: min(CGFloat(manager.devices.count) * 28 + 12, 120))
            }

            if let device = manager.selectedDevice, !device.isSimulator {
                HStack {
                    Text("Team ID")
                    TextField("e.g. 2R8MRUP265", text: $manager.teamID)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .frame(width: 160)
                    Text("Signs the agent for your device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if device.developerModeEnabled == false {
                    Label("Developer Mode is off on this device (Settings ▸ Privacy & Security ▸ Developer Mode).", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Agent

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Agent").font(.headline)
                statusLabel
                Spacer()
                if manager.isAgentRunning {
                    Button("Stop Agent", role: .destructive) { manager.stopAgent() }
                } else {
                    Button(isStarting ? "Starting…" : "Start Agent") {
                        Task { await manager.startAgent() }
                    }
                    .disabled(manager.selectedDevice == nil || isStarting)
                    .keyboardShortcut(.defaultAction)
                }
            }

            if case .failed(let message) = manager.state {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            DisclosureGroup("Build log", isExpanded: $showLog) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(manager.log.suffix(300).joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id("end")
                    }
                    .frame(height: 160)
                    .background(.background.secondary, in: .rect(cornerRadius: 6))
                    .onChange(of: manager.log.count) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            .font(.callout)

            if manager.selectedDevice?.isSimulator == false && !manager.isAgentRunning {
                Text("The first time, the device needs Developer Mode and Settings ▸ Developer ▸ Enable UI Automation turned on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isStarting: Bool {
        if case .starting = manager.state { return true }
        return false
    }

    @ViewBuilder private var statusLabel: some View {
        switch manager.state {
        case .idle:
            Text("Not running").foregroundStyle(.secondary)
        case .starting(let message):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(message).foregroundStyle(.secondary)
            }
        case .running:
            Label(manager.isAgentRunning ? "Running" : "Running on another device", systemImage: "circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .failed:
            Label("Failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    // MARK: - App

    private var appSection: some View {
        let filtered = manager.apps.filter {
            appSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(appSearch) || $0.bundleID.localizedCaseInsensitiveContains(appSearch)
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("App").font(.headline)
                Spacer()
                TextField("Search apps", text: $appSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
            List(selection: $selectedApp) {
                Label("App in the foreground", systemImage: "sparkle.magnifyingglass")
                    .tag(Self.foregroundTag)
                Label("Home Screen", systemImage: "apps.iphone")
                    .tag("com.apple.springboard")
                Section("Installed") {
                    ForEach(filtered) { app in
                        HStack {
                            Text(app.name)
                            Spacer()
                            Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        .tag(app.bundleID)
                    }
                }
            }
            .frame(minHeight: 200)
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { _ in inspectSelection() }

            HStack {
                Text("“App in the foreground” follows whatever app is open on the device each time you re-scan (⌘R).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Inspect", action: inspectSelection)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedApp == nil)
            }
        }
    }

    private func inspectSelection() {
        guard let selectedApp else { return }
        inspect(selectedApp == Self.foregroundTag ? nil : selectedApp)
    }
}

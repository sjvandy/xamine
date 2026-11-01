import SwiftUI

/// Screenshot on the left; hierarchy (top) and queries (bottom) on the right.
struct InspectorView: View {
    @Bindable var model: InspectorModel
    var devices: DeviceManager
    var pickAnother: () -> Void
    /// Starts (or retries) the agent on a device and inspects its foreground app.
    var startDevice: (String) -> Void
    var showDeviceSettings: () -> Void
    var cancelDeviceLaunch: () -> Void

    var body: some View {
        Group {
            if let launch = model.deviceLaunch {
                DeviceLaunchView(launch: launch, state: devices.state,
                                 retry: { startDevice(launch.deviceID) },
                                 openSettings: showDeviceSettings,
                                 cancel: cancelDeviceLaunch)
            } else {
                HSplitView {
                    ScreenshotCanvas(model: model)
                        .frame(minWidth: 360, idealWidth: 640, maxWidth: .infinity, maxHeight: .infinity)

                    VSplitView {
                        HierarchyOutline(model: model)
                            .frame(minHeight: 200, idealHeight: 440, maxHeight: .infinity)
                        ElementDetail(model: model)
                            .frame(minHeight: 200, idealHeight: 340, maxHeight: .infinity)
                    }
                    .frame(minWidth: 380, idealWidth: 480, maxWidth: .infinity)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(message: toast.message, symbol: toast.symbol)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.toast)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Filter elements")
        .toolbar {
            ToolbarItem(placement: .navigation) { targetLabel }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await model.rescan() }
                } label: {
                    Label("Re-scan", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .disabled(model.isLoading || model.deviceLaunch != nil)
                .help("Re-capture the window and re-read its hierarchy (⌘R)")

                Button(action: pickAnother) {
                    Label("Pick Window", systemImage: "viewfinder")
                }
                .help("Pick another window (⌘⇧X)")
            }
        }
    }

    @ViewBuilder private var targetLabel: some View {
        if let summary = model.summary {
            Button {
                model.copy(summary.bundleID ?? summary.name, message: "Copied bundle ID")
            } label: {
                HStack(spacing: 8) {
                    if let icon = summary.icon {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 20, height: 20)
                    }
                    Text(summary.name).fontWeight(.semibold)
                        + Text(summary.bundleID.map { " - \($0)" } ?? "").foregroundStyle(.secondary)
                    if model.isLoading { ProgressView().controlSize(.small) }
                }
                .lineLimit(1)
                .padding(.horizontal, 4)
            }
            .help([summary.detail, "Click to copy the bundle ID"].compactMap { $0 }.joined(separator: " · "))
        }
    }
}

/// Shown in place of the inspector while the agent starts on a device picked from the edge of the screen.
private struct DeviceLaunchView: View {
    let launch: InspectorModel.DeviceLaunch
    let state: DeviceManager.AgentState
    var retry: () -> Void
    var openSettings: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if case .failed(let message) = state {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.orange)
                    .padding(.bottom, 6)
                Text("Couldn't Connect to \(launch.deviceName)")
                    .font(.title2.weight(.semibold))
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: 440)
                HStack {
                    Button("Device Settings…", action: openSettings)
                    Button("Try Again", action: retry)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 6)
            } else {
                Image(systemName: launch.symbol)
                    .font(.system(size: 72, weight: .thin))
                    .foregroundStyle(.tint)
                    .symbolEffect(.breathe.pulse.byLayer, options: .repeat(.continuous))
                    .frame(height: 100)
                    .padding(.bottom, 6)
                Text("Connecting to \(launch.deviceName)")
                    .font(.title2.weight(.semibold))
                Text(statusMessage)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.default, value: statusMessage)
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                    .padding(.top, 4)
                Button("Cancel", action: cancel)
                    .padding(.top, 10)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.secondary)
    }

    private var statusMessage: String {
        switch state {
        case .starting(let message): message
        case .running: "Connecting to the agent…"
        default: "Starting the agent…"
        }
    }
}

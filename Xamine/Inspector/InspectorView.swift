import SwiftUI

/// Screenshot on the left; hierarchy (top) and queries (bottom) on the right.
struct InspectorView: View {
    @Bindable var model: InspectorModel
    var pickAnother: () -> Void

    var body: some View {
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
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(message: toast)
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
                .disabled(model.isLoading)
                .help("Re-capture the window and re-read its hierarchy (⌘R)")

                Button(action: pickAnother) {
                    Label("Pick Window", systemImage: "viewfinder")
                }
                .help("Pick another window (⌘⇧X)")
            }
        }
    }

    @ViewBuilder private var targetLabel: some View {
        if let target = model.target {
            HStack(spacing: 8) {
                if let icon = NSRunningApplication(processIdentifier: target.pid)?.icon {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(target.appName).font(.headline)
                    Text(subtitle(for: target)).font(.caption).foregroundStyle(.secondary)
                }
                if model.isLoading { ProgressView().controlSize(.small) }
            }
        }
    }

    private func subtitle(for target: PickedWindow) -> String {
        let platform = target.isSimulator ? "iOS Simulator" : (target.bundleID ?? "")
        return [target.title.nonEmpty, platform].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
    }
}

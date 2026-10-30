import SwiftUI

/// The captured window, with hover and selection highlights. Clicking an element selects it and copies its query.
struct ScreenshotCanvas: View {
    @Bindable var model: InspectorModel
    @FocusState private var isFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            if let image = model.image, let tree = model.tree {
                let windowSize = tree.windowFrame.size
                let scale = min(proxy.size.width / windowSize.width, proxy.size.height / windowSize.height, 2)
                let displaySize = CGSize(width: windowSize.width * scale, height: windowSize.height * scale)

                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: displaySize.width, height: displaySize.height)

                    Canvas { context, _ in
                        if let hovered = model.hoveredID, hovered != model.selectedID {
                            draw(tree, hovered, scale, in: &context, color: .accentColor, fill: 0.12, dash: [5, 3])
                        }
                        if let selected = model.selectedID {
                            draw(tree, selected, scale, in: &context, color: .orange, fill: 0.18, dash: [])
                        }
                    }
                    .allowsHitTesting(false)
                }
                .frame(width: displaySize.width, height: displaySize.height)
                .clipShape(.rect(cornerRadius: 8))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .contentShape(.rect)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        isFocused = true
                        model.hoverScreenshot(at: globalPoint(location, tree, scale))
                    case .ended:
                        model.hoverScreenshot(at: nil)
                    }
                }
                .onTapGesture { location in
                    // Click picks the layer chosen with ↑/↓, or the deepest element under the cursor.
                    model.hoverScreenshot(at: globalPoint(location, tree, scale))
                    if let id = model.hoveredID { model.pickFromScreenshot(id) }
                }
                .focusable()
                .focusEffectDisabled()
                .focused($isFocused)
                .onKeyPress(keys: [.upArrow, "["]) { _ in
                    model.moveHoverLayer(-1)
                    return .handled
                }
                .onKeyPress(keys: [.downArrow, "]"]) { _ in
                    model.moveHoverLayer(1)
                    return .handled
                }
                .help("Click an element to select it and copy its query")
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            } else if model.isLoading {
                ProgressView("Scanning…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No Screenshot", systemImage: "photo",
                                       description: Text("Xamine couldn't capture this window. Check Screen Recording permission."))
            }
        }
        .padding(20)
        .background(.background.secondary)
        .overlay(alignment: .bottomLeading) { hoverBadge }
    }

    private func globalPoint(_ location: CGPoint, _ tree: UITree, _ scale: CGFloat) -> CGPoint {
        CGPoint(x: tree.windowFrame.minX + location.x / scale, y: tree.windowFrame.minY + location.y / scale)
    }

    private func draw(_ tree: UITree, _ id: Int, _ scale: CGFloat, in context: inout GraphicsContext,
                      color: Color, fill: Double, dash: [CGFloat]) {
        guard let frame = tree.node(id).frame else { return }
        let rect = CGRect(
            x: (frame.minX - tree.windowFrame.minX) * scale,
            y: (frame.minY - tree.windowFrame.minY) * scale,
            width: frame.width * scale,
            height: frame.height * scale
        )
        let path = Path(roundedRect: rect, cornerRadius: 3)
        context.fill(path, with: .color(color.opacity(fill)))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: dash))
    }

    @ViewBuilder private var hoverBadge: some View {
        if let id = model.hoveredID, let tree = model.tree {
            let node = tree.node(id)
            HStack(spacing: 6) {
                Image(systemName: node.kind.symbol).foregroundStyle(node.kind.category.tint)
                Text(node.kind.displayName).fontWeight(.semibold)
                if let text = node.displayText {
                    Text("“\(text)”").lineLimit(1)
                }
                if let identifier = node.identifier.nonEmpty {
                    Text(identifier).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if let layer = model.hoverLayerPosition {
                    Divider().frame(height: 12)
                    Text("Layer \(layer.index) of \(layer.count)")
                        .foregroundStyle(.secondary)
                    Text("↑↓").font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: .capsule)
            .padding(12)
            .allowsHitTesting(false)
        }
    }
}

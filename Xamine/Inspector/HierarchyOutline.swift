import SwiftUI

/// The UI dump: one row per element, indented by depth, with symbols, labels and identifier chips.
struct HierarchyOutline: View {
    @Bindable var model: InspectorModel

    var body: some View {
        if let tree = model.tree {
            ScrollViewReader { proxy in
                List(model.visibleRows, selection: $model.selectedID) { row in
                    HierarchyRow(
                        node: tree.node(row.id),
                        isExpanded: model.expandedIDs.contains(row.id) || !model.searchText.isEmpty,
                        isHovered: model.hoveredID == row.id,
                        toggle: { model.toggleExpanded(row.id) }
                    )
                    .padding(.leading, CGFloat(row.depth) * 14)
                    .tag(row.id)
                    .id(row.id)
                    .onHover { inside in
                        if inside { model.hoveredID = row.id } else if model.hoveredID == row.id { model.hoveredID = nil }
                    }
                    .contextMenu { contextMenu(for: tree.node(row.id)) }
                }
                .listStyle(.inset)
                .environment(\.defaultMinListRowHeight, 22)
                .onChange(of: model.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text("\(tree.nodes.count) elements")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(.regularMaterial, in: .capsule)
                    .padding(8)
            }
        } else if let error = model.errorMessage {
            ContentUnavailableView("Couldn't Read UI", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func contextMenu(for node: UINode) -> some View {
        if let identifier = node.identifier.nonEmpty {
            Button("Copy Identifier") { model.copy(identifier, message: "Copied identifier") }
        }
        if let text = node.displayText {
            Button("Copy Label") { model.copy(text, message: "Copied label") }
        }
        if let queries = model.builder?.queries(for: node.id) {
            Divider()
            if let byIdentifier = queries.byIdentifier {
                Button("Copy Identifier Query") { model.copy(byIdentifier.code, message: "Copied identifier query") }
            }
            Button("Copy Container Query") { model.copy(queries.fromContainer.code, message: "Copied container query") }
            if let fromAnchor = queries.fromAnchor {
                Button("Copy Anchored Query") { model.copy(fromAnchor.code, message: "Copied anchored query") }
            }
            Button("Copy Full Path from Window") { model.copy(queries.byHierarchy.code, message: "Copied full path") }
        }
        Divider()
        Button("Expand All Below") { expandAll(below: node.id) }
    }

    private func expandAll(below id: Int) {
        guard let tree = model.tree else { return }
        var stack = [id]
        while let next = stack.popLast() {
            model.expandedIDs.insert(next)
            stack.append(contentsOf: tree.node(next).childIDs)
        }
    }
}

private struct HierarchyRow: View {
    let node: UINode
    let isExpanded: Bool
    let isHovered: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12, height: 12)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(node.childIDs.isEmpty ? 0 : 1)
            .disabled(node.childIDs.isEmpty)

            Image(systemName: node.kind.symbol)
                .foregroundStyle(node.kind.category.tint)
                .frame(width: 18)

            Text(node.kind.displayName)
                .foregroundStyle(node.hasSelector ? .primary : .secondary)
                .fontWeight(node.kind.category == .container ? .regular : .medium)

            if let text = node.displayText {
                Text("“\(text)”")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            if let identifier = node.identifier.nonEmpty {
                Text(identifier)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15), in: .rect(cornerRadius: 4))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .font(.callout)
        .padding(.vertical, 1)
        .background(isHovered ? Color.accentColor.opacity(0.08) : .clear, in: .rect(cornerRadius: 4))
    }
}

import SwiftUI

/// The UI dump: one row per element, indented by depth, with symbols, labels and identifier chips.
struct HierarchyOutline: View {
    @Bindable var model: InspectorModel

    var body: some View {
        if let tree = model.tree {
            // Context menus can be rendered off the main thread, so they get value copies, not the model.
            let builder = model.builder
            ScrollViewReader { proxy in
                List(model.visibleRows, selection: Binding(get: { model.selectedID }, set: { id in if id != model.selectedID { model.select(id) } })) { row in
                    HierarchyRow(
                        node: tree.node(row.id),
                        isExpanded: model.expandedIDs.contains(row.id) || !model.searchText.isEmpty,
                        toggle: { model.toggleExpanded(row.id) }
                    )
                    // Hover is read in its own view, so moving the mouse redraws one row instead of the whole list.
                    .background { HoverHighlight(model: model, id: row.id) }
                    .padding(.leading, CGFloat(row.depth) * 14)
                    .tag(row.id)
                    .id(row.id)
                    .onHover { inside in
                        if inside { model.hoveredID = row.id } else if model.hoveredID == row.id { model.hoveredID = nil }
                    }
                    .contextMenu {
                        HierarchyContextMenu(node: tree.node(row.id), builder: builder, copy: model.copy,
                                             expandAll: { expandAll(below: row.id) })
                    }
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
    }
}

private struct HoverHighlight: View {
    let model: InspectorModel
    let id: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(model.hoveredID == id ? Color.accentColor.opacity(0.08) : .clear)
    }
}

/// Builds its queries in `body`, which SwiftUI only evaluates when the menu opens; the `contextMenu` closure itself
/// runs on every redraw of the list.
private struct HierarchyContextMenu: View {
    let node: UINode
    let builder: QueryBuilder?
    let copy: (String, String) -> Void
    let expandAll: () -> Void

    var body: some View {
        if let identifier = node.identifier.nonEmpty {
            Button("Copy Identifier") { copy(identifier, "Copied identifier") }
        }
        if let text = node.displayText {
            Button("Copy Label") { copy(text, "Copied label") }
        }
        if let queries = builder?.queries(for: node.id) {
            Divider()
            if let byIdentifier = queries.byIdentifier {
                Button("Copy Identifier Query") { copy(byIdentifier.code, "Copied identifier query") }
            }
            Button("Copy Container Query") { copy(queries.fromContainer.code, "Copied container query") }
            if let fromAnchor = queries.fromAnchor {
                Button("Copy Anchored Query") { copy(fromAnchor.code, "Copied anchored query") }
            }
            Button("Copy Full Path from Window") { copy(queries.byHierarchy.code, "Copied full path") }
        }
        Divider()
        Button("Expand All Below", action: expandAll)
    }
}

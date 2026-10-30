import SwiftUI

/// Bottom-right pane: the two copyable XCUITest queries plus every attribute of the selected element.
struct ElementDetail: View {
    @Bindable var model: InspectorModel

    var body: some View {
        if let node = model.selectedNode, let queries = model.selectedQueries {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(node, queries)
                    options
                    CommandCard(
                        title: "By identifier",
                        symbol: "tag",
                        snippet: queries.byIdentifier,
                        emptyMessage: "This element has no identifier or label. Use the hierarchy query instead.",
                        copy: { model.copy($0, message: "Copied identifier query") }
                    )
                    CommandCard(
                        title: "From unique container",
                        symbol: "square.stack.3d.down.right",
                        snippet: queries.fromContainer,
                        emptyMessage: "",
                        copy: { model.copy($0, message: "Copied container query") }
                    )
                    .help("Hierarchy steps from the closest container whose type appears once in the window. Indexes count siblings of the same type; XCTest sometimes skips accessibility nodes the raw tree shows.")
                    CommandCard(
                        title: "From identified anchor",
                        symbol: "scope",
                        snippet: queries.fromAnchor,
                        emptyMessage: "No container above this element has, or directly holds, a uniquely identified element.",
                        copy: { model.copy($0, message: "Copied anchored query") }
                    )
                    .help("Hierarchy steps from the closest container that has a unique identifier or label, or that directly holds a child with a unique identifier.")
                    attributes(node)
                }
                .padding(14)
            }
        } else {
            ContentUnavailableView("Select an Element", systemImage: "cursorarrow.click.2",
                                   description: Text("Click an element in the screenshot or the hierarchy to see ways to query it."))
        }
    }

    private func header(_ node: UINode, _ queries: GeneratedQueries) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: node.kind.symbol)
                    .font(.title3)
                    .foregroundStyle(node.kind.category.tint)
                Text(node.kind.displayName).font(.headline)
                if let text = node.displayText {
                    Text("“\(text)”").foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Text(queries.breadcrumb)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var options: some View {
        let platform = model.tree?.platform ?? .macOS
        return HStack {
            // Plain items rather than a ForEach: SwiftUI can build menu items later off the main thread, and a
            // main-actor ForEach closure then traps (Swift 6 isolation check).
            Picker("Action", selection: $model.snippetAction) {
                Text(SnippetAction.none.title(for: platform)).tag(SnippetAction.none)
                Text(SnippetAction.interact.title(for: platform)).tag(SnippetAction.interact)
                Text(SnippetAction.waitForExistence.title(for: platform)).tag(SnippetAction.waitForExistence)
                Text(SnippetAction.exists.title(for: platform)).tag(SnippetAction.exists)
            }
            .pickerStyle(.menu)
            .fixedSize()
            Spacer()
            Toggle("Include `let app`", isOn: $model.includeAppDeclaration)
                .toggleStyle(.checkbox)
        }
        .font(.callout)
    }

    private func attributes(_ node: UINode) -> some View {
        let rows: [(String, String?)] = [
            ("Identifier", node.identifier.nonEmpty),
            ("Title", node.title.nonEmpty),
            ("Label", node.label.nonEmpty),
            ("Value", node.value.nonEmpty),
            ("Placeholder", node.placeholder.nonEmpty),
            ("Help", node.help.nonEmpty),
            ("Role", [node.role, node.subrole].compactMap { $0 }.joined(separator: " · ")),
            ("Role Description", node.roleDescription.nonEmpty),
            ("XCUI Type", ".\(node.kind.typeName)"),
            ("Frame", node.frame.map { "x \(Int($0.minX))  y \(Int($0.minY))  w \(Int($0.width))  h \(Int($0.height))" }),
            ("Enabled", node.isEnabled.map { $0 ? "Yes" : "No" }),
        ]
        return VStack(alignment: .leading, spacing: 6) {
            Text("Attributes").font(.subheadline.weight(.semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(rows.filter { $0.1 != nil }, id: \.0) { name, value in
                    GridRow {
                        Text(name).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Button {
                            model.copy(value!, message: "Copied \(name.lowercased())")
                        } label: {
                            Text(value!)
                                .font(.callout.monospaced())
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help("Click to copy")
                    }
                }
            }
            .font(.callout)
        }
    }
}

/// A code block that copies itself when clicked.
private struct CommandCard: View {
    let title: String
    let symbol: String
    let snippet: Snippet?
    let emptyMessage: String
    let copy: (String) -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                Spacer()
                if snippet != nil {
                    Label("Click to copy", systemImage: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .opacity(isHovered ? 1 : 0.6)
                }
            }

            if let snippet {
                Button { copy(snippet.code) } label: {
                    Text(snippet.code)
                        .font(.system(.callout, design: .monospaced))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.background.secondary, in: .rect(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(isHovered ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isHovered ? 1.5 : 1)
                        )
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }

                if let note = snippet.note {
                    Label(note, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.background.secondary, in: .rect(cornerRadius: 8))
            }
        }
    }
}

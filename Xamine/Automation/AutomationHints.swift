import Foundation

/// Explanations and decisions that the automation tools make from a scanned tree, kept apart from the services so they
/// can be tested without a running app or device.
enum AutomationHints {
    /// On iPad (iOS 18+) tabs sit in a floating bar that isn't a `tabBar`: `app.tabBars.buttons["Cart"]` matches nothing,
    /// while buttons with the same labels exist. Says so, and suggests the query that works. `nil` when it doesn't apply.
    static func tabBarHint(steps: [QueryResolver.Step], tree: UITree) -> String? {
        let usesTabBar = steps.contains { step in
            switch step.operation {
            case .descendants(let type?), .children(let type?), .typedKey(let type, _): type == "tabBar"
            default: false
            }
        }
        guard usesTabBar, !tree.nodes.contains(where: { $0.kind.typeName == "tabBar" }),
              let key = steps.compactMap(\.operation.key).last else { return nil }
        let wanted = key.lowercased()
        guard let button = tree.nodes.first(where: { node in
            node.kind.typeName == "button" && [node.label, node.identifier, node.title].contains { $0?.lowercased() == wanted }
        }) else { return nil }
        let name = button.label.nonEmpty ?? button.identifier.nonEmpty ?? key
        return "Tabs on iPad (iOS 18 and later) aren't in a `tabBar`, so no tab bar matches. The button “\(name)” exists outside one; use app.buttons[\(QueryBuilder.literal(name))].firstMatch, which also works on iPhone."
    }

    /// What to add when `find_elements` finds nothing.
    static func noMatchHint(device: String?) -> String {
        if let device {
            return "Nothing matched. Lists on iOS load rows lazily, so the element may be off-screen: `scroll` (with device “\(device)”) and search again."
        }
        return "Nothing matched. If the element is inside a scroll view or a lazy list it may be off-screen; `scroll` and search again."
    }

    /// How a scan's window is named in headers: its title, else what it is (an alert or sheet has no title).
    static func windowDescription(title: String?, kind: String?) -> String {
        if let title = title.nonEmpty { return "window “\(title)”" }
        switch kind {
        case "sheet", "alert", "dialog", "popover": return "\(kind!) (untitled)"
        default: return "window (untitled)"
        }
    }

    enum StaleRefOutcome: Equatable {
        /// The element is in the new tree as this node.
        case found(Int)
        /// It no longer matches exactly one element; carries the query that was tried.
        case changed(query: String)
    }

    /// Re-finds the element `id` of `oldTree` in `newTree` by its query, so a ref from an older snapshot acts on where the
    /// element is now, or fails instead of clicking where it used to be.
    static func resolveStaleRef(id: Int, oldTree: UITree, newTree: UITree) -> StaleRefOutcome {
        let query = QueryBuilder(tree: oldTree, includeAppDeclaration: false).bestQuery(for: id)
        guard let steps = try? QueryResolver.parse(query) else { return .changed(query: query) }
        let matches = QueryResolver(tree: newTree).resolve(steps).matches
        return matches.count == 1 ? .found(matches[0]) : .changed(query: query)
    }
}

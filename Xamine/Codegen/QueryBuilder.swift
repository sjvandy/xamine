import Foundation

/// What to append to a generated element query.
enum SnippetAction: String, CaseIterable, Identifiable, Sendable {
    case none, interact, waitForExistence, exists

    var id: Self { self }

    func title(for platform: TargetPlatform) -> String {
        switch self {
        case .none: "Element only"
        case .interact: platform == .macOS ? ".click()" : ".tap()"
        case .waitForExistence: ".waitForExistence"
        case .exists: "XCTAssert exists"
        }
    }
}

struct Snippet: Equatable, Sendable {
    var code: String
    var note: String?
}

struct GeneratedQueries: Equatable, Sendable {
    /// `nil` when the element has no identifier, label, or other matchable text.
    var byIdentifier: Snippet?
    /// Starts at the closest container whose element type occurs once in the window.
    var fromContainer: Snippet
    /// Starts at the closest container that has, or directly holds, a uniquely identified element.
    var fromAnchor: Snippet?
    /// The full path from the window.
    var byHierarchy: Snippet
    /// e.g. "Window ▸ Group 1 ▸ Button 2"
    var breadcrumb: String
}

/// Turns a node in a `UITree` into XCUITest queries.
struct QueryBuilder {
    let tree: UITree
    var action: SnippetAction = .none
    var includeAppDeclaration: Bool = true

    func queries(for id: Int) -> GeneratedQueries {
        GeneratedQueries(
            byIdentifier: identifierSnippet(for: tree.node(id)),
            fromContainer: containerSnippet(for: id),
            fromAnchor: anchoredSnippet(for: id),
            byHierarchy: hierarchySnippet(for: id),
            breadcrumb: breadcrumb(for: id)
        )
    }

    // MARK: - App declaration

    var appDeclaration: String {
        if tree.platform == .iOSSimulator || tree.bundleID == nil {
            return "let app = XCUIApplication()"
        }
        return "let app = XCUIApplication(bundleIdentifier: \(Self.literal(tree.bundleID!)))"
    }

    // MARK: - By identifier

    func identifierSnippet(for node: UINode) -> Snippet? {
        let query = "app.\(node.kind.queryName)"

        if let key = node.bestKey {
            let matches = keyMatches(kind: node.kind, key: key)
            var note: String?
            if node.identifier.nonEmpty == nil {
                note = "No accessibility identifier — matched by \(node.title.nonEmpty != nil ? "title" : "label")."
            }
            let expression: String
            if matches.count <= 1 {
                expression = "\(query)[\(Self.literal(key))]"
            } else {
                let index = matches.firstIndex(of: node.id) ?? 0
                expression = "\(query).matching(identifier: \(Self.literal(key))).element(boundBy: \(index))"
                note = [note, "\(matches.count) \(node.kind.displayName.lowercased())s share this key; using match \(index + 1)."]
                    .compactMap { $0 }.joined(separator: " ")
            }
            return Snippet(code: wrap(expression), note: note)
        }

        for (attribute, text) in [("value", node.value), ("placeholderValue", node.placeholder)] {
            guard let text = text.nonEmpty else { continue }
            let matches = matchingNodes(kind: node.kind) { attribute == "value" ? $0.value == text : $0.placeholder == text }
            let index = matches.firstIndex(of: node.id) ?? 0
            let predicate = "NSPredicate(format: \(Self.literal("\(attribute) == %@")), \(Self.literal(text)))"
            let tail = matches.count <= 1 ? ".firstMatch" : ".element(boundBy: \(index))"
            return Snippet(
                code: wrap("\(query).matching(\(predicate))\(tail)"),
                note: "No identifier or label — matched by \(attribute)."
            )
        }
        return nil
    }

    /// Nodes of `kind` (in document order, below the query root) that satisfy `predicate`.
    private func matchingNodes(kind: ElementKind, where predicate: (UINode) -> Bool) -> [Int] {
        tree.nodes.filter { tree.isInQueryScope($0.id) && $0.kind.typeName == kind.typeName && predicate($0) }.map(\.id)
    }

    // MARK: - By hierarchy

    func hierarchySnippet(for id: Int) -> Snippet {
        Snippet(code: wrap(expression(from: rootExpression, steps: chain(to: id))), note: nil)
    }

    /// `app.scrollViews.firstMatch.children(...)…` from the deepest container (or the element itself)
    /// whose type is unique in the window. Falls back to the full path.
    func containerSnippet(for id: Int) -> Snippet {
        let path = chain(to: id)
        for (position, candidate) in path.enumerated().reversed() {
            guard nodesInScope(where: { $0.kind.typeName == candidate.kind.typeName }).count == 1 else { continue }
            let start = "app.\(candidate.kind.queryName).firstMatch"
            let note = "Starts at the only \(candidate.kind.displayName.lowercased()) in this window."
            return Snippet(code: wrap(expression(from: start, steps: Array(path.suffix(from: position + 1)))), note: note)
        }
        return Snippet(code: wrap(expression(from: rootExpression, steps: path)),
                       note: "No container type is unique in this window, so this is the full path.")
    }

    /// Starts from the closest container that is itself uniquely identified, or that directly holds a child with a
    /// unique accessibility identifier (via `containing(_:identifier:)`). `nil` if no such container exists.
    func anchoredSnippet(for id: Int) -> Snippet? {
        let path = chain(to: id)
        // Walk up from the element's parent; the element's own key is already covered by the identifier query.
        for position in stride(from: path.count - 2, through: -1, by: -1) {
            let container = position >= 0 ? path[position] : tree.node(tree.queryRootID)
            let steps = Array(path.suffix(from: position + 1))

            if position >= 0, let key = container.bestKey,
               keyMatches(kind: container.kind, key: key).count == 1 {
                let start = "app.\(container.kind.queryName)[\(Self.literal(key))]"
                let source = container.identifier.nonEmpty != nil ? "identifier" : "label"
                return Snippet(code: wrap(expression(from: start, steps: steps)),
                               note: "Anchored to the \(container.kind.displayName.lowercased()) with \(source) “\(key)”.")
            }

            let onPath = steps.first?.id
            for sibling in tree.children(of: container.id) where sibling.id != onPath {
                guard let key = sibling.identifier.nonEmpty,
                      nodesInScope(where: { $0.kind.typeName == sibling.kind.typeName && $0.identifier == key }).count == 1
                else { continue }
                // Every container of this type that holds that element somewhere below it, in document order.
                let holders = nodesInScope { $0.kind.typeName == container.kind.typeName && contains($0.id, kind: sibling.kind, identifier: key) }
                let index = holders.firstIndex(of: container.id) ?? 0
                let tail = holders.count <= 1 ? ".firstMatch" : ".element(boundBy: \(index))"
                let start = "app.\(container.kind.queryName).containing(.\(sibling.kind.typeName), identifier: \(Self.literal(key)))\(tail)"
                return Snippet(code: wrap(expression(from: start, steps: steps)),
                               note: "Anchored to the \(container.kind.displayName.lowercased()) holding \(sibling.kind.displayName.lowercased()) “\(key)”.")
            }
        }
        return nil
    }

    private func expression(from start: String, steps: [UINode]) -> String {
        var lines = [start]
        for node in steps {
            lines.append("    .children(matching: .\(node.kind.typeName)).element(boundBy: \(siblingIndex(of: node)))")
        }
        return lines.joined(separator: "\n")
    }

    private func nodesInScope(where predicate: (UINode) -> Bool) -> [Int] {
        tree.nodes.filter { tree.isInQueryScope($0.id) && predicate($0) }.map(\.id)
    }

    /// Nodes of `kind` whose identifier, title or label equals `key` — what XCUITest's subscript matches.
    private func keyMatches(kind: ElementKind, key: String) -> [Int] {
        nodesInScope { $0.kind.typeName == kind.typeName && ($0.identifier == key || $0.title == key || $0.label == key) }
    }

    /// Whether a descendant of `id` has the given type and accessibility identifier.
    private func contains(_ id: Int, kind: ElementKind, identifier: String) -> Bool {
        var stack = tree.node(id).childIDs
        while let next = stack.popLast() {
            let node = tree.node(next)
            if node.kind.typeName == kind.typeName && node.identifier == identifier { return true }
            stack.append(contentsOf: node.childIDs)
        }
        return false
    }

    /// The query that the first hierarchy step hangs off.
    private var rootExpression: String {
        // System UI roots (menu bar, desktop, Control Center) aren't always windows.
        guard tree.platform == .macOS else { return "app" }
        return "app.\(tree.root?.kind.queryName ?? "windows").firstMatch"
    }

    /// Nodes from just below the query root down to `id`, inclusive.
    private func chain(to id: Int) -> [UINode] {
        let path = tree.ancestors(of: id) + [tree.node(id)]
        guard let rootPosition = path.firstIndex(where: { $0.id == tree.queryRootID }) else {
            return Array(path.dropFirst())
        }
        return Array(path.suffix(from: rootPosition + 1))
    }

    /// Index of `node` among its parent's children of the same element type.
    func siblingIndex(of node: UINode) -> Int {
        guard let parentID = node.parentID else { return 0 }
        let sameType = tree.node(parentID).childIDs.filter { tree.node($0).kind.typeName == node.kind.typeName }
        return sameType.firstIndex(of: node.id) ?? 0
    }

    func breadcrumb(for id: Int) -> String {
        let rootName = tree.platform == .macOS ? tree.root?.kind.displayName ?? "Window" : "App"
        let parts = [rootName] + chain(to: id).map { "\($0.kind.displayName) \(siblingIndex(of: $0) + 1)" }
        return parts.joined(separator: " ▸ ")
    }

    // MARK: - Formatting

    private func wrap(_ expression: String) -> String {
        let body: String
        switch action {
        case .none:
            body = expression
        case .interact:
            body = expression + (tree.platform == .macOS ? ".click()" : ".tap()")
        case .waitForExistence:
            body = "XCTAssertTrue(\(expression)\n    .waitForExistence(timeout: 5))"
        case .exists:
            body = "XCTAssertTrue(\(expression).exists)"
        }
        return includeAppDeclaration ? "\(appDeclaration)\n\(body)" : body
    }

    /// A Swift string literal for `string`, with quotes, backslashes and control characters escaped.
    static func literal(_ string: String) -> String {
        var escaped = ""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case _ where scalar.value < 0x20: escaped += "\\u{\(String(scalar.value, radix: 16))}"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }
}

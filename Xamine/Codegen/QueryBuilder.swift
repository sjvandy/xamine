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
            let matches = matchingNodes(kind: node.kind) { $0.identifier == key || $0.title == key || $0.label == key }
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
        let steps = chain(to: id)
        var lines = [rootExpression]
        for node in steps {
            lines.append("    .children(matching: .\(node.kind.typeName)).element(boundBy: \(siblingIndex(of: node)))")
        }
        let expression = lines.count == 1 ? lines[0] : lines.joined(separator: "\n")
        return Snippet(code: wrap(expression), note: nil)
    }

    /// The query that the first hierarchy step hangs off.
    private var rootExpression: String {
        tree.platform == .macOS ? "app.windows.firstMatch" : "app"
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
        let rootName = tree.platform == .macOS ? "Window" : "App"
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

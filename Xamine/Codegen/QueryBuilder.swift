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
    /// `nil` when the element has no identifier, title, label, value or placeholder to match.
    var byIdentifier: Snippet?
    /// Starts at the closest container whose element type occurs once in the window.
    var fromContainer: Snippet
    /// False when no container type is unique and `fromContainer` is just the full path.
    var hasUniqueContainer: Bool
    /// True when `fromContainer` is the query for the item holding the element (a numbered cell, say) rather than a path
    /// to the element itself, so it matches a different element than the one selected.
    var containerIsEnclosing = false
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
    var action: SnippetAction
    var includeAppDeclaration: Bool
    /// The query root and its descendants, in document order; worked out once instead of on every lookup.
    private let scopedIDs: [Int]

    init(tree: UITree, action: SnippetAction = .none, includeAppDeclaration: Bool = true) {
        self.tree = tree
        self.action = action
        self.includeAppDeclaration = includeAppDeclaration
        scopedIDs = tree.nodes.map(\.id).filter(tree.isInQueryScope)
    }

    func queries(for id: Int) -> GeneratedQueries {
        let enclosing = enclosingItemSnippet(for: id)
        let container = enclosing ?? containerSnippet(for: id)
        let hierarchy = hierarchySnippet(for: id)
        return GeneratedQueries(
            byIdentifier: identifierSnippet(for: tree.node(id)),
            fromContainer: container,
            // The container query falls back to exactly the full path when nothing is unique.
            hasUniqueContainer: enclosing != nil || container.code != hierarchy.code,
            containerIsEnclosing: enclosing != nil,
            fromAnchor: anchoredSnippet(for: id),
            byHierarchy: hierarchy,
            breadcrumb: breadcrumb(for: id)
        )
    }

    /// The query to put in a generated test: by identifier, else anchored, else from a unique container, else the full
    /// path. Each is checked with `QueryResolver`, and the first that finds exactly this element wins.
    func bestQuery(for id: Int) -> String {
        let plain = QueryBuilder(tree: tree, includeAppDeclaration: false)
        let generated = plain.queries(for: id)
        let options = [generated.byIdentifier, generated.fromAnchor, generated.hasUniqueContainer ? generated.fromContainer : nil, generated.byHierarchy]
            .compactMap { $0?.code }
        let resolver = QueryResolver(tree: tree)
        return options.first { code in
            guard let steps = try? QueryResolver.parse(code) else { return false }
            return resolver.resolve(steps).matches == [id]
        } ?? generated.byHierarchy.code
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

        guard let key = node.bestKey, let source = node.bestKeySource else { return nil }
        let matches = keyMatches(kind: node.kind, key: key)
        var note: String?
        if source != "identifier" {
            note = "No accessibility identifier — matched by \(source)."
        }
        let expression: String
        if matches.count <= 1 {
            expression = "\(query)[\(Self.literal(key))]"
        } else {
            // The subscript returns a single element, so duplicates need a query to index into.
            let index = matches.firstIndex(of: node.id) ?? 0
            // The first match reads better as `["Cart"].firstMatch` than as `.matching(identifier:).element(boundBy: 0)`.
            expression = index == 0
                ? "\(query)[\(Self.literal(key))].firstMatch"
                : "\(query).matching(identifier: \(Self.literal(key))).element(boundBy: \(index))"
            note = [note, "\(matches.count) \(node.kind.displayName.lowercased())s share this key; using match \(index + 1)."]
                .compactMap { $0 }.joined(separator: " ")
        }
        // The same key on elements of other types: harmless to this query, but a sign the identifier names a view type.
        let kinds = Set(nodesInScope { $0.matchesIdentifier(key) }.map { tree.node($0).kind.displayName })
        if kinds.count > 1 {
            note = [note, "The key “\(key)” is also used by \(kinds.subtracting([node.kind.displayName]).sorted().joined(separator: ", ")) elements; it isn't unique to this element."]
                .compactMap { $0 }.joined(separator: " ")
        }
        return Snippet(code: wrap(expression), note: note)
    }

    // MARK: - Enclosing item

    /// The query for the item that holds `id`, when there clearly is one: the nearest ancestor with its own identifier that
    /// is one of a numbered sequence (`Identifier:ResultCell,Section:0,Row:3`, `row-2`, `tile_7`) and has the same hit box
    /// as the element. Spotlight's result cells and a list's rows are like that; a one-off identified container isn't.
    func enclosingItemSnippet(for id: Int) -> Snippet? {
        guard let item = enclosingItem(for: id), let key = item.stableIdentifier else { return nil }
        let name = item.kind.displayName.lowercased()
        return Snippet(code: wrap("app.\(item.kind.queryName)[\(Self.literal(key))]"),
                       note: "The \(name) holding this element, one of a numbered sequence with the same bounds. It matches the whole item, not just this element.")
    }

    func enclosingItem(for id: Int) -> UINode? {
        guard let frame = tree.node(id).frame else { return nil }
        for ancestor in tree.ancestors(of: id).reversed() {
            // Wrappers between the element and its item are often a little smaller than either, so keep looking upward.
            guard let ancestorFrame = ancestor.frame, Self.overlap(ancestorFrame, frame) >= Self.sameHitBox,
                  tree.isInQueryScope(ancestor.id), let key = ancestor.stableIdentifier,
                  isSequence(key, kind: ancestor.kind), keyMatches(kind: ancestor.kind, key: key).count == 1 else { continue }
            return ancestor
        }
        return nil
    }

    /// How much two hit boxes must overlap (intersection over union) to count as the same.
    static let sameHitBox: CGFloat = 0.85

    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let overlap = intersection.width * intersection.height
        let union = a.width * a.height + b.width * b.height - overlap
        return union > 0 ? overlap / union : 0
    }

    /// Whether `identifier` has numbers in it and at least one other element of the same type has the same identifier with
    /// different numbers: `…Section:0,Row:3` with `…Section:0,Row:1`, or `…Section:1,Row:0`.
    private func isSequence(_ identifier: String, kind: ElementKind) -> Bool {
        let template = Self.numberTemplate(identifier)
        guard template != identifier else { return false }
        return nodesInScope { $0.kind.typeName == kind.typeName && $0.identifier != identifier
            && $0.stableIdentifier.map(Self.numberTemplate) == template }.count >= 1
    }

    /// `row-12` → `row-#`: every run of digits becomes `#`.
    static func numberTemplate(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
    }

    // MARK: - Alternatives to offer

    /// Longest text-free query worth offering; a SwiftUI screen's full path is 15 or more `.children` steps.
    static let maxTextFreeSteps = 6

    /// Element types whose text-free query proves nothing: `app.navigationBars.firstMatch` matches whichever screen is showing.
    private static let weakKinds: Set<String> = ["window", "navigationBar", "tabBar", "toolbar", "statusBar", "application", "keyboard"]

    /// How many `.children` or `containing` steps a query takes.
    static func stepCount(_ code: String) -> Int {
        code.components(separatedBy: ".children(matching:").count - 1 + code.components(separatedBy: ".containing(").count - 1
    }

    /// A query that finds the element by type and position only, so copy changes don't break it: from the closest
    /// unique container if there is one, otherwise the full path. `nil` when it would be longer than
    /// `maxTextFreeSteps`, or when the element is a bar or window that such a query can't tell apart.
    func textFreeAlternative(for id: Int) -> String? {
        guard !Self.weakKinds.contains(tree.node(id).kind.typeName) else { return nil }
        let plain = QueryBuilder(tree: tree, includeAppDeclaration: false)
        let generated = plain.queries(for: id)
        let code = (generated.hasUniqueContainer && !generated.containerIsEnclosing ? generated.fromContainer : generated.byHierarchy).code
        return Self.stepCount(code) <= Self.maxTextFreeSteps ? code : nil
    }

    /// The queries `get_queries` lists, in order, each with a title and note. Drops an anchored query that is no shorter
    /// than the container one, and marks a hierarchy path that is long enough to be fragile.
    func offeredQueries(for id: Int) -> [(title: String, snippet: Snippet)] {
        let generated = queries(for: id)
        var list: [(String, Snippet)] = []
        if let byIdentifier = generated.byIdentifier { list.append(("By identifier", byIdentifier)) }
        if let anchor = generated.fromAnchor, Self.stepCount(anchor.code) < Self.stepCount(generated.fromContainer.code) {
            list.append(("From anchor", anchor))
        }
        if generated.hasUniqueContainer {
            list.append((generated.containerIsEnclosing ? "Enclosing item (matches the whole item, not this element)" : "From container", generated.fromContainer))
        }
        let steps = Self.stepCount(generated.byHierarchy.code)
        let weak = Self.weakKinds.contains(tree.node(id).kind.typeName)
        let title = steps > Self.maxTextFreeSteps ? "By hierarchy (\(steps) steps, too fragile to recommend)" : (weak ? "By hierarchy" : "By hierarchy (text-free)")
        list.append((title, generated.byHierarchy))
        return list
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
                let source = container.bestKeySource ?? "label"
                return Snippet(code: wrap(expression(from: start, steps: steps)),
                               note: "Anchored to the \(container.kind.displayName.lowercased()) with \(source) “\(key)”.")
            }

            let onPath = steps.first?.id
            for sibling in tree.children(of: container.id) where sibling.id != onPath {
                guard let key = sibling.stableIdentifier, keyMatches(kind: sibling.kind, key: key).count == 1 else { continue }
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
        scopedIDs.filter { predicate(tree.node($0)) }
    }

    /// Nodes of `kind` that XCUITest's identifier matching would return for `key`.
    private func keyMatches(kind: ElementKind, key: String) -> [Int] {
        nodesInScope { $0.kind.typeName == kind.typeName && $0.matchesIdentifier(key) }
    }

    /// Whether a descendant of `id` has the given type and matches `identifier` the way `containing(_:identifier:)` does.
    private func contains(_ id: Int, kind: ElementKind, identifier: String) -> Bool {
        var stack = tree.node(id).childIDs
        while let next = stack.popLast() {
            let node = tree.node(next)
            if node.kind.typeName == kind.typeName && node.matchesIdentifier(identifier) { return true }
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

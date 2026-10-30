import AppKit
import Observation

/// State for one inspector window: the captured screenshot, the scanned tree, and the current selection.
@Observable @MainActor
final class InspectorModel {
    struct Row: Identifiable, Hashable {
        let id: Int
        let depth: Int
    }

    private(set) var target: PickedWindow?
    private(set) var image: CGImage?
    private(set) var tree: UITree?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var toast: String?

    var selectedID: Int? {
        didSet {
            guard let selectedID, selectedID != oldValue else { return }
            reveal(selectedID)
        }
    }
    var hoveredID: Int?
    var expandedIDs: Set<Int> = []
    var searchText = ""

    var snippetAction: SnippetAction = SnippetAction(rawValue: UserDefaults.standard.string(forKey: "snippetAction") ?? "") ?? .none {
        didSet { UserDefaults.standard.set(snippetAction.rawValue, forKey: "snippetAction") }
    }
    var includeAppDeclaration: Bool = UserDefaults.standard.object(forKey: "includeAppDeclaration") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includeAppDeclaration, forKey: "includeAppDeclaration") }
    }

    @ObservationIgnored private var toastTask: Task<Void, Never>?

    // MARK: - Loading

    func load(_ target: PickedWindow) async {
        self.target = target
        selectedID = nil
        hoveredID = nil
        searchText = ""
        await rescan(resetExpansion: true)
    }

    func rescan(resetExpansion: Bool = false) async {
        guard var target else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // The window may have moved since it was picked.
        if let bounds = Self.currentBounds(of: target.windowID) {
            target = PickedWindow(pid: target.pid, windowID: target.windowID, bounds: bounds,
                                  appName: target.appName, bundleID: target.bundleID, title: target.title)
            self.target = target
        }

        async let capture = try? WindowCapture.capture(windowID: target.windowID)
        do {
            let tree = try await HierarchyScanner.scan(target)
            self.image = await capture
            self.tree = tree
            if resetExpansion || expandedIDs.isEmpty {
                expandedIDs = Set(tree.nodes.filter { $0.depth < 5 && !$0.childIDs.isEmpty }.map(\.id))
            }
            if let selectedID, selectedID >= tree.nodes.count { self.selectedID = nil }
        } catch {
            self.image = await capture
            self.tree = nil
            errorMessage = error.localizedDescription
        }
    }

    private static func currentBounds(of windowID: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]])?.first,
              let dict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dict)
    }

    // MARK: - Outline rows

    /// Rows currently visible in the outline, honoring expansion and the search filter.
    var visibleRows: [Row] {
        guard let tree, let root = tree.root else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()

        if !query.isEmpty {
            // Show every match plus its ancestors, fully expanded.
            var included = Set<Int>()
            for node in tree.nodes where Self.matches(node, query) {
                included.insert(node.id)
                var parent = node.parentID
                while let id = parent, included.insert(id).inserted { parent = tree.node(id).parentID }
            }
            var rows: [Row] = []
            func walk(_ id: Int) {
                guard included.contains(id) else { return }
                rows.append(Row(id: id, depth: tree.node(id).depth))
                tree.node(id).childIDs.forEach(walk)
            }
            walk(root.id)
            return rows
        }

        var rows: [Row] = []
        func walk(_ id: Int) {
            let node = tree.node(id)
            rows.append(Row(id: id, depth: node.depth))
            if expandedIDs.contains(id) { node.childIDs.forEach(walk) }
        }
        walk(root.id)
        return rows
    }

    private static func matches(_ node: UINode, _ query: String) -> Bool {
        [node.identifier, node.title, node.label, node.value, node.placeholder, node.kind.displayName, node.role]
            .contains { $0?.lowercased().contains(query) == true }
    }

    func toggleExpanded(_ id: Int) {
        if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
    }

    /// Expands every ancestor of `id` so its row is visible.
    private func reveal(_ id: Int) {
        guard let tree, id < tree.nodes.count else { return }
        for ancestor in tree.ancestors(of: id) { expandedIDs.insert(ancestor.id) }
    }

    // MARK: - Queries

    var builder: QueryBuilder? {
        tree.map { QueryBuilder(tree: $0, action: snippetAction, includeAppDeclaration: includeAppDeclaration) }
    }

    var selectedNode: UINode? {
        guard let tree, let selectedID, selectedID < tree.nodes.count else { return nil }
        return tree.node(selectedID)
    }

    var selectedQueries: GeneratedQueries? {
        guard let selectedID, let builder, selectedID < builder.tree.nodes.count else { return nil }
        return builder.queries(for: selectedID)
    }

    /// Selects the element under a screenshot click and copies its best query.
    func pickFromScreenshot(_ id: Int) {
        selectedID = id
        guard let queries = selectedQueries else { return }
        if let byIdentifier = queries.byIdentifier {
            copy(byIdentifier.code, message: "Copied identifier query")
        } else {
            copy(queries.byHierarchy.code, message: "Copied hierarchy query")
        }
    }

    // MARK: - Clipboard

    func copy(_ text: String, message: String = "Copied") {
        Clipboard.copy(text)
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}

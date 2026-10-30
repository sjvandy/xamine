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
    struct Toast: Equatable {
        let message: String
        let symbol: String
    }

    private(set) var toast: Toast?

    var selectedID: Int? {
        didSet {
            guard let selectedID, selectedID != oldValue else { return }
            reveal(selectedID)
        }
    }
    var hoveredID: Int?
    /// Layers under the cursor on the screenshot, outermost first; `hoveredID` is one of them.
    private(set) var hoverStack: [Int] = []
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

        // An app window may have moved since it was picked.
        if target.isAppWindow, let bounds = Self.currentBounds(of: target.windowID) {
            target.bounds = bounds
            self.target = target
        }

        let picked = target
        async let capture = try? WindowCapture.capture(picked)
        do {
            var tree = try await HierarchyScanner.scan(picked)
            if let capture = await capture {
                self.image = capture.image
                // Map element frames onto the area really captured, so the screenshot isn't stretched.
                tree.windowFrame = capture.frame
            } else if let previous = self.tree {
                tree.windowFrame = previous.windowFrame
            }
            self.tree = tree
            // System UI picked by position may belong to another process than the window under it.
            target.pid = tree.pid
            target.appName = tree.appName
            target.bundleID = tree.bundleID
            self.target = target
            if resetExpansion || expandedIDs.isEmpty {
                expandedIDs = Set(tree.nodes.filter { $0.depth < 5 && !$0.childIDs.isEmpty }.map(\.id))
            }
            if let selectedID, selectedID >= tree.nodes.count { self.selectedID = nil }
        } catch {
            Log.scan.error("scan failed: \(error.localizedDescription, privacy: .public)")
            let capture = await capture
            if !resetExpansion, tree != nil {
                // Transient UI (menus, Spotlight, Control Center) is usually gone by the time of a re-scan;
                // keep what was captured rather than wiping it.
                showToast("Couldn't re-scan — it may have closed", symbol: "exclamationmark.triangle.fill")
                return
            }
            self.image = capture?.image
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

    // MARK: - Screenshot hover

    /// Updates the layers under the cursor. Keeps the chosen layer while the cursor stays over the same stack.
    func hoverScreenshot(at point: CGPoint?) {
        guard let point, let tree else {
            hoverStack = []
            hoveredID = nil
            return
        }
        let stack = tree.hitStack(point)
        if stack == hoverStack, let hoveredID, stack.contains(hoveredID) { return }
        hoverStack = stack
        hoveredID = stack.last
    }

    /// Moves the hover one layer out (`-1`, toward the window) or in (`+1`, toward the deepest element).
    func moveHoverLayer(_ delta: Int) {
        guard let hoveredID, let index = hoverStack.firstIndex(of: hoveredID) else { return }
        let next = min(max(index + delta, 0), hoverStack.count - 1)
        self.hoveredID = hoverStack[next]
    }

    var hoverLayerPosition: (index: Int, count: Int)? {
        guard let hoveredID, let index = hoverStack.firstIndex(of: hoveredID), hoverStack.count > 1 else { return nil }
        return (hoverStack.count - index, hoverStack.count)
    }

    /// Selects the element under a screenshot click and copies its best query.
    func pickFromScreenshot(_ id: Int) {
        selectedID = id
        guard let queries = selectedQueries else { return }
        if let byIdentifier = queries.byIdentifier {
            copy(byIdentifier.code, message: "Copied identifier query")
        } else if let fromAnchor = queries.fromAnchor {
            copy(fromAnchor.code, message: "Copied anchored query")
        } else {
            copy(queries.fromContainer.code, message: "Copied container query")
        }
    }

    // MARK: - Clipboard

    func copy(_ text: String, message: String = "Copied") {
        Clipboard.copy(text)
        showToast(message)
    }

    func showToast(_ message: String, symbol: String = "checkmark.circle.fill") {
        toast = Toast(message: message, symbol: symbol)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}

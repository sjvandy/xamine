import AppKit
import Observation

/// State for one inspector window: the captured screenshot, the scanned tree, and the current selection.
@Observable @MainActor
final class InspectorModel {
    struct Row: Identifiable, Hashable {
        let id: Int
        let depth: Int
    }

    /// What's being inspected: a Mac window (`target`) or an app on an iOS device (`device`).
    private(set) var target: PickedWindow?
    private(set) var device: DeviceInspection?
    /// The app currently shown from the device (resolved when following the foreground app).
    private(set) var deviceBundleID: String?
    private(set) var image: CGImage?
    private(set) var tree: UITree?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// A device picked from the edge of the screen whose agent is still starting; the inspector shows a loading screen.
    struct DeviceLaunch: Equatable {
        let deviceID: String
        let deviceName: String
        let symbol: String
    }

    private(set) var deviceLaunch: DeviceLaunch?
    /// Returns a working client when a device scan can't reach the agent, or `nil` after starting it over.
    @ObservationIgnored var recoverDevice: ((DeviceInspection) async -> AgentClient?)?

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

    /// Clears what's shown and waits for a device's agent; `loadDevice` (or picking a window) ends the wait.
    func beginDeviceLaunch(_ launch: DeviceLaunch) {
        deviceLaunch = launch
        target = nil
        device = nil
        deviceBundleID = nil
        image = nil
        tree = nil
        errorMessage = nil
        selectedID = nil
        hoveredID = nil
        searchText = ""
    }

    func cancelDeviceLaunch() {
        deviceLaunch = nil
    }

    func load(_ target: PickedWindow) async {
        deviceLaunch = nil
        self.target = target
        device = nil
        selectedID = nil
        hoveredID = nil
        searchText = ""
        await rescan(resetExpansion: true)
    }

    func loadDevice(_ device: DeviceInspection) async {
        deviceLaunch = nil
        self.device = device
        target = nil
        deviceBundleID = nil
        selectedID = nil
        hoveredID = nil
        searchText = ""
        await rescan(resetExpansion: true)
    }

    func rescan(resetExpansion: Bool = false) async {
        if let device {
            await rescanDevice(device, resetExpansion: resetExpansion)
            return
        }
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

    private func rescanDevice(_ device: DeviceInspection, resetExpansion: Bool, isRetry: Bool = false) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let bundleID: String
            if let chosen = device.bundleID {
                bundleID = chosen
            } else {
                bundleID = try await device.client.foregroundApp(candidates: device.candidates)
            }
            async let screenshot = try? device.client.screenshot()
            let root = try await device.client.tree(bundleID: bundleID)
            let tree = root.makeTree(appName: device.appNames[bundleID] ?? bundleID, bundleID: bundleID)
            let switchedApps = bundleID != deviceBundleID
            if let image = await screenshot { self.image = image }
            self.tree = tree
            deviceBundleID = bundleID
            if resetExpansion || switchedApps || expandedIDs.isEmpty {
                expandedIDs = Set(tree.nodes.filter { $0.depth < 6 && !$0.childIDs.isEmpty }.map(\.id))
            }
            if switchedApps { selectedID = nil }
            if let selectedID, selectedID >= tree.nodes.count { self.selectedID = nil }
        } catch {
            Log.scan.error("device scan failed: \(error.localizedDescription, privacy: .public)")
            if !isRetry, Self.isUnreachable(error) {
                isLoading = false
                if let client = await recoverDevice?(device) {
                    var device = device
                    device.client = client
                    self.device = device
                    await rescanDevice(device, resetExpansion: resetExpansion, isRetry: true)
                }
                // Otherwise the agent is starting over behind the loading screen.
                return
            }
            if !resetExpansion, tree != nil {
                showToast("Couldn't reach the agent — is it still running?", symbol: "exclamationmark.triangle.fill")
                return
            }
            tree = nil
            errorMessage = error.localizedDescription
        }
    }

    private static func isUnreachable(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut, .notConnectedToInternet].contains(error.code)
    }

    /// Name, bundle ID and icon for the title chip.
    struct Summary {
        let name: String
        let bundleID: String?
        let icon: NSImage?
        let detail: String?
    }

    var summary: Summary? {
        if let device {
            return Summary(name: tree?.appName ?? device.deviceName, bundleID: deviceBundleID,
                           icon: NSImage(systemSymbolName: device.symbol, accessibilityDescription: nil), detail: device.deviceName)
        }
        if let target {
            return Summary(name: target.appName, bundleID: target.bundleID,
                           icon: NSRunningApplication(processIdentifier: target.pid)?.icon,
                           detail: Optional([target.title.nonEmpty, target.isSimulator ? "iOS Simulator" : nil].compactMap { $0 }.joined(separator: " · ")).nonEmpty)
        }
        return nil
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
        hoveredID = tree.preferredLayer(in: stack)
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

    /// Selects an element (from the screenshot or the outline) and copies its best query: by identifier, then from a
    /// unique container, then from an identified anchor, then the full path.
    func select(_ id: Int?) {
        selectedID = id
        guard id != nil, let queries = selectedQueries else { return }
        if let byIdentifier = queries.byIdentifier {
            copy(byIdentifier.code, message: "Copied identifier query")
        } else if queries.hasUniqueContainer {
            copy(queries.fromContainer.code, message: "Copied container query")
        } else if let fromAnchor = queries.fromAnchor {
            copy(fromAnchor.code, message: "Copied anchored query")
        } else {
            copy(queries.byHierarchy.code, message: "Copied full path")
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

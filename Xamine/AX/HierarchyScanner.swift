import ApplicationServices
import AppKit

/// A window chosen in the picker.
struct PickedWindow: Hashable, Sendable {
    static let desktopLayer = Int(CGWindowLevelForKey(.desktopIconWindow))

    var pid: pid_t
    /// 0 for the desktop, which has no single window.
    var windowID: CGWindowID
    /// Global coordinates, top-left origin.
    var bounds: CGRect
    var appName: String
    var bundleID: String?
    var title: String?
    /// CoreGraphics window layer: 0 for normal app windows, higher for system UI (menu bar, Dock, Spotlight…).
    var layer: Int = 0
    /// Where the cursor was when this was picked; used to find system UI that isn't listed as an app window.
    var anchor: CGPoint?

    var isSimulator: Bool { bundleID == "com.apple.iphonesimulator" }
    var isDesktop: Bool { windowID == 0 }
    /// A regular app window, which can be found through the app's window list and captured on its own.
    var isAppWindow: Bool { layer == 0 && windowID != 0 }

    func anchored(at point: CGPoint) -> PickedWindow {
        var copy = self
        copy.anchor = point
        return copy
    }
}

enum ScanError: LocalizedError {
    case notTrusted
    case windowNotFound
    case nothingUnderCursor

    var errorDescription: String? {
        switch self {
        case .notTrusted: "xamine needs Accessibility permission to read other apps' UI."
        case .windowNotFound: "Couldn't find that window in the app's accessibility tree. The app may not expose accessibility information."
        case .nothingUnderCursor: "Nothing under the cursor exposes accessibility information. If it was a menu or panel, it may have closed."
        }
    }
}

/// Walks an app window's accessibility tree into a `UITree`.
enum HierarchyScanner {
    static let maxDepth = 80
    static let maxNodes = 15_000

    static func scan(_ target: PickedWindow) async throws -> UITree {
        var result = try await pass(target, enhanced: false)

        // Web views (WebKit, Chromium, Electron) build their accessibility tree lazily, the first time an
        // assistive app asks. The first pass then sees large empty placeholder groups, so re-read a few times.
        var retries = 0
        while retries < 4, hasUnpopulatedContainers(result.nodes) {
            retries += 1
            try await Task.sleep(for: .milliseconds(350))
            let previousCount = result.nodes.count
            result = try await pass(target, enhanced: true)
            if retries > 1, result.nodes.count == previousCount { break }
        }
        return makeTree(result.nodes, pid: result.pid, for: target)
    }

    /// One walk of the window, off the main actor. Returns the nodes and the pid that actually owns them.
    private static func pass(_ target: PickedWindow, enhanced: Bool) async throws -> (nodes: [UINode], pid: pid_t) {
        try await Task.detached(priority: .userInitiated) {
            guard AXIsProcessTrusted() else { throw ScanError.notTrusted }
            let (root, pid) = try findRoot(for: target)
            let app = AXElement.application(pid: pid)
            // Chromium and Electron only expose web content once this is set; WebKit ignores it.
            app.set("AXManualAccessibility", true)
            // Asks apps (and WebKit) to build their full tree, as VoiceOver does. Some apps change behavior
            // while it is on (e.g. window animations), so it is restored after the walk.
            let previousEnhanced = enhanced ? app.attribute("AXEnhancedUserInterface") as? Bool : nil
            if enhanced { app.set("AXEnhancedUserInterface", true) }
            defer { if enhanced { app.set("AXEnhancedUserInterface", previousEnhanced ?? false) } }

            var nodes: [UINode] = []
            nodes.reserveCapacity(1024)
            visit(root, parentID: nil, depth: 0, into: &nodes)
            return (nodes, pid)
        }.value
    }

    /// The element to walk from. App windows come from the app's window list; system UI (menu bar extras,
    /// Control Center, Spotlight, the desktop) often isn't listed there, so it is found from the element
    /// under the cursor by climbing to its top-level container.
    private static func findRoot(for target: PickedWindow) throws -> (AXElement, pid_t) {
        if target.isAppWindow, let window = findWindow(in: AXElement.application(pid: target.pid), matching: target) {
            return (window, target.pid)
        }
        if let anchor = target.anchor, let hit = AXElement.at(anchor) {
            return (hit.topLevelContainer, hit.pid ?? target.pid)
        }
        if let window = findWindow(in: AXElement.application(pid: target.pid), matching: target) {
            return (window, target.pid)
        }
        throw target.isAppWindow ? ScanError.windowNotFound : ScanError.nothingUnderCursor
    }

    /// Whether the tree has big containers with no children — the signature of web content not yet loaded.
    private static func hasUnpopulatedContainers(_ nodes: [UINode]) -> Bool {
        nodes.contains { node in
            guard node.depth > 0, node.childIDs.isEmpty, let frame = node.frame,
                  frame.width >= 150, frame.height >= 150 else { return false }
            return ["AXWebArea", "AXGroup", "AXScrollArea"].contains(node.role)
        }
    }

    private static func makeTree(_ nodes: [UINode], pid: pid_t, for target: PickedWindow) -> UITree {
        // System UI picked by position may belong to a different process than the window under it
        // (e.g. the menu bar is drawn by the Window Server but its items belong to apps).
        let owner = pid == target.pid ? nil : NSRunningApplication(processIdentifier: pid)
        var tree = UITree(
            nodes: nodes,
            appName: owner?.localizedName ?? target.appName,
            bundleID: owner?.bundleIdentifier ?? target.bundleID,
            pid: pid,
            platform: target.isSimulator ? .iOSSimulator : .macOS,
            windowFrame: target.bounds
        )
        if target.isSimulator { tree.queryRootID = simulatorContentRoot(in: tree) ?? 0 }
        return tree
    }

    private static func findWindow(in app: AXElement, matching target: PickedWindow) -> AXElement? {
        let windows = app.windows
        if let exact = windows.first(where: { $0.windowID == target.windowID }) { return exact }
        // Fall back to the window whose frame is closest to the picked bounds.
        return windows.min { a, b in
            distance(a.frame, target.bounds) < distance(b.frame, target.bounds)
        }
    }

    private static func distance(_ frame: CGRect?, _ bounds: CGRect) -> CGFloat {
        guard let frame else { return .infinity }
        return abs(frame.minX - bounds.minX) + abs(frame.minY - bounds.minY)
            + abs(frame.width - bounds.width) + abs(frame.height - bounds.height)
    }

    private static func visit(_ element: AXElement, parentID: Int?, depth: Int, into nodes: inout [UINode]) {
        guard nodes.count < maxNodes else { return }
        let attrs = element.values(AXElement.scanAttributes)
        let role = attrs[kAXRoleAttribute] as? String ?? "AXUnknown"
        let subrole = attrs[kAXSubroleAttribute] as? String

        let id = nodes.count
        nodes.append(UINode(
            id: id,
            parentID: parentID,
            depth: depth,
            kind: ElementKind.forRole(role, subrole: subrole),
            role: role,
            subrole: subrole,
            roleDescription: attrs[kAXRoleDescriptionAttribute] as? String,
            identifier: attrs[kAXIdentifierAttribute] as? String,
            title: AXElement.describe(attrs[kAXTitleAttribute]),
            label: AXElement.describe(attrs[kAXDescriptionAttribute]),
            value: AXElement.describe(attrs[kAXValueAttribute]).map { String($0.prefix(500)) },
            placeholder: AXElement.describe(attrs[kAXPlaceholderValueAttribute]),
            help: AXElement.describe(attrs[kAXHelpAttribute]),
            frame: AXElement.frame(from: attrs),
            isEnabled: (attrs[kAXEnabledAttribute] as? NSNumber)?.boolValue
        ))
        if let parentID { nodes[parentID].childIDs.append(id) }

        guard depth < maxDepth, let children = attrs[kAXChildrenAttribute] as? [AXUIElement] else { return }
        for child in children {
            AXUIElementSetMessagingTimeout(child, 1.0)
            visit(AXElement(raw: child), parentID: id, depth: depth + 1, into: &nodes)
        }
    }

    /// In a Simulator window, the iOS app's elements live under the largest group inside the window.
    /// Queries are generated relative to that group so they read like iOS XCUITest code.
    private static func simulatorContentRoot(in tree: UITree) -> Int? {
        tree.nodes
            .filter { $0.id != 0 && $0.role == "AXGroup" && $0.frame != nil && !$0.childIDs.isEmpty }
            .max { ($0.frame!.width * $0.frame!.height) < ($1.frame!.width * $1.frame!.height) }?
            .id
    }
}

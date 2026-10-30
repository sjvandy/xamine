import ApplicationServices
import AppKit

/// A window chosen in the picker.
struct PickedWindow: Hashable, Sendable {
    let pid: pid_t
    let windowID: CGWindowID
    /// Global coordinates, top-left origin.
    let bounds: CGRect
    let appName: String
    let bundleID: String?
    let title: String?

    var isSimulator: Bool { bundleID == "com.apple.iphonesimulator" }
}

enum ScanError: LocalizedError {
    case notTrusted
    case windowNotFound

    var errorDescription: String? {
        switch self {
        case .notTrusted: "xamine needs Accessibility permission to read other apps' UI."
        case .windowNotFound: "Couldn't find that window in the app's accessibility tree. The app may not expose accessibility information."
        }
    }
}

/// Walks an app window's accessibility tree into a `UITree`.
enum HierarchyScanner {
    static let maxDepth = 80
    static let maxNodes = 15_000

    static func scan(_ target: PickedWindow) async throws -> UITree {
        try await Task.detached(priority: .userInitiated) {
            try scanSync(target)
        }.value
    }

    private static func scanSync(_ target: PickedWindow) throws -> UITree {
        guard AXIsProcessTrusted() else { throw ScanError.notTrusted }
        let app = AXElement.application(pid: target.pid)
        guard let window = findWindow(in: app, matching: target) else { throw ScanError.windowNotFound }

        var nodes: [UINode] = []
        nodes.reserveCapacity(1024)
        visit(window, parentID: nil, depth: 0, into: &nodes)

        var tree = UITree(
            nodes: nodes,
            appName: target.appName,
            bundleID: target.bundleID,
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

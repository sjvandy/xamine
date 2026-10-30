import CoreGraphics
import Foundation

/// One element of a scanned UI hierarchy. Nodes live in a flat array inside `UITree` and refer to each other by index.
struct UINode: Identifiable, Hashable, Sendable {
    let id: Int
    let parentID: Int?
    var childIDs: [Int] = []
    let depth: Int
    let kind: ElementKind

    var role: String?
    var subrole: String?
    var roleDescription: String?
    var identifier: String?
    var title: String?
    /// `AXDescription` on macOS, `label` on iOS.
    var label: String?
    var value: String?
    var placeholder: String?
    var help: String?
    /// Global screen coordinates, top-left origin.
    var frame: CGRect?
    var isEnabled: Bool?

    /// The most stable string to look this element up by with XCUITest's subscript or `matching(identifier:)`:
    /// identifier, then title, label, value and placeholder. Long, multi-line or numeric values are skipped, since
    /// they're content or state rather than something to find an element by.
    var bestKey: String? {
        identifier.nonEmpty ?? title.nonEmpty ?? label.nonEmpty ?? keyableValue ?? placeholder.nonEmpty
    }

    /// Which identifying property `bestKey` came from, for notes in the UI.
    var bestKeySource: String? {
        if identifier.nonEmpty != nil { return "identifier" }
        if title.nonEmpty != nil { return "title" }
        if label.nonEmpty != nil { return "label" }
        if keyableValue != nil { return "value" }
        if placeholder.nonEmpty != nil { return "placeholder" }
        return nil
    }

    private var keyableValue: String? {
        guard let value = value.nonEmpty, value.count <= 100, !value.contains(where: \.isNewline), Double(value) == nil else { return nil }
        return value
    }

    /// Whether `key` equals any of the properties XCUITest's identifier matching compares against
    /// (`identifier`, `title`, `label`, `value`, `placeholderValue`), as used by the subscript,
    /// `matching(identifier:)` and `containing(_:identifier:)`.
    func matchesIdentifier(_ key: String) -> Bool {
        identifier == key || title == key || label == key || value == key || placeholder == key
    }

    /// The most descriptive text for display: title, label, value, or placeholder.
    var displayText: String? {
        title.nonEmpty ?? label.nonEmpty ?? value.nonEmpty ?? placeholder.nonEmpty
    }

    var hasSelector: Bool { bestKey != nil }
}

enum TargetPlatform: String, Sendable {
    case macOS
    case iOSSimulator
    case iOSDevice
}

/// A scanned element tree for one window. Node 0 is the root.
struct UITree: Sendable {
    var nodes: [UINode]
    var appName: String
    var bundleID: String?
    var pid: pid_t = 0
    var platform: TargetPlatform
    /// Frame of the captured window in global coordinates; screenshot pixel (0,0) corresponds to its origin.
    var windowFrame: CGRect
    /// Nodes above the window that should not appear in generated queries (e.g. Simulator chrome).
    var queryRootID: Int = 0

    var root: UINode? { nodes.first }

    func node(_ id: Int) -> UINode { nodes[id] }

    func children(of id: Int) -> [UINode] { nodes[id].childIDs.map { nodes[$0] } }

    /// Ancestors from the root down to (but excluding) `id`.
    func ancestors(of id: Int) -> [UINode] {
        var chain: [UINode] = []
        var current = nodes[id].parentID
        while let parent = current {
            chain.append(nodes[parent])
            current = nodes[parent].parentID
        }
        return chain.reversed()
    }

    /// Whether `id` is the query root or one of its descendants.
    func isInQueryScope(_ id: Int) -> Bool {
        var current: Int? = id
        while let node = current {
            if node == queryRootID { return true }
            current = nodes[node].parentID
        }
        return false
    }

    /// Every layer under `point`, outermost first: the deepest hit plus each ancestor whose frame also contains the point.
    func hitStack(_ point: CGPoint) -> [Int] {
        guard let hit = hitTest(point) else { return [] }
        return (ancestors(of: hit.id) + [hit])
            .filter { $0.frame?.contains(point) == true }
            .map(\.id)
    }

    /// The deepest node whose frame contains `point` (global coordinates), preferring the smallest area on ties.
    func hitTest(_ point: CGPoint) -> UINode? {
        var best: UINode?
        var bestArea = CGFloat.infinity
        for node in nodes {
            guard let frame = node.frame, frame.width > 0, frame.height > 0, frame.contains(point) else { continue }
            let area = frame.width * frame.height
            if area < bestArea || (area == bestArea && node.depth > (best?.depth ?? -1)) {
                best = node
                bestArea = area
            }
        }
        return best
    }
}

extension Optional where Wrapped == String {
    /// The wrapped string if it is non-nil and not just whitespace.
    var nonEmpty: String? {
        guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return self
    }
}

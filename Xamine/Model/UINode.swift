import AppKit
import CoreGraphics
import Foundation
import Synchronization

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
    /// Selected state from XCUITest (iOS): a chosen segment, tab or row.
    var isSelected: Bool? = nil

    /// The most stable string to look this element up by with XCUITest's subscript or `matching(identifier:)`:
    /// identifier, then title, label, value and placeholder. Long, multi-line or numeric values are skipped, since
    /// they're content or state rather than something to find an element by.
    var bestKey: String? {
        stableIdentifier ?? title.nonEmpty ?? label.nonEmpty ?? keyableValue ?? placeholder.nonEmpty
    }

    /// The identifier, unless the framework made it up: AppKit's `_NS:74` and SwiftUI's
    /// `SwiftUI.WindowGroup<…>-1-AppWindow-1` change between builds, so they make poor keys for a test.
    var stableIdentifier: String? {
        guard let identifier = identifier.nonEmpty else { return nil }
        if identifier.hasPrefix("_NS:") || identifier.hasPrefix("SwiftUI.") || identifier.contains("-AppWindow-") { return nil }
        // An SF Symbol name (`bag`, `cup.and.saucer`) is the icon an element shows, not an identifier anyone set; it
        // changes with state (`bag.fill`), so the label is the better key.
        if Self.isSymbolName(identifier) { return nil }
        return identifier
    }

    private static let symbolNames = Mutex<[String: Bool]>([:])

    /// Whether `name` is an SF Symbol, checked against the system's symbol catalog and remembered.
    static func isSymbolName(_ name: String) -> Bool {
        if let known = symbolNames.withLock({ $0[name] }) { return known }
        let isSymbol = !name.contains(where: \.isUppercase) && !name.contains("-")
            && NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        symbolNames.withLock { $0[name] = isSymbol }
        return isSymbol
    }

    /// Which identifying property `bestKey` came from, for notes in the UI.
    var bestKeySource: String? {
        if stableIdentifier != nil { return "identifier" }
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

    /// The layer to pick by default from a `hitStack`: the deepest one, unless layers just above it share its exact
    /// frame and one of those has an identifier or label (a cell wrapping an unlabeled view, say), which queries better.
    func preferredLayer(in stack: [Int]) -> Int? {
        guard let deepest = stack.last else { return nil }
        let frame = nodes[deepest].frame
        let sameFrame = stack.reversed().prefix { nodes[$0].frame == frame }
        return sameFrame.first { nodes[$0].hasSelector } ?? deepest
    }

    /// The element at `point` (global coordinates): the smallest node whose frame contains it, preferring the deeper
    /// one on ties. Where the tree is an iOS app's, windows are stacked in order and later ones draw on top, so the
    /// topmost window with something at the point wins. That's what keeps Spotlight, Siri, the keyboard or an alert
    /// from losing to the Home Screen icons beneath them.
    func hitTest(_ point: CGPoint) -> UINode? {
        let windows = root?.kind.typeName == "application" ? nodes.first?.childIDs.filter { nodes[$0].kind.typeName == "window" } ?? [] : []
        guard windows.count > 1 else { return smallestNode(containing: point, in: nodes.map(\.id)) }

        for (position, windowID) in windows.enumerated().reversed() {
            let window = nodes[windowID]
            var ids = descendants(of: windowID)
            // Overlay windows are mostly full-screen transparent wrappers; only what's drawn in them counts. The
            // bottom window is the app itself, where a large view (a scroll view, say) is a fine target.
            if position > 0, let frame = window.frame {
                let area = frame.width * frame.height
                let screen = frame.insetBy(dx: -1, dy: -1)
                // Not wrappers, and not effects: a shadow or glow that spills past the screen edge isn't a target.
                ids = ids.filter { id in nodes[id].frame.map { $0.width * $0.height < area * 0.9 && screen.contains($0) } ?? false }
            }
            if let hit = smallestNode(containing: point, in: ids) { return hit }
        }
        return nil
    }

    private func descendants(of id: Int) -> [Int] {
        var result: [Int] = []
        var stack = nodes[id].childIDs
        while let next = stack.popLast() {
            result.append(next)
            stack.append(contentsOf: nodes[next].childIDs)
        }
        return result.sorted()
    }

    private func smallestNode(containing point: CGPoint, in ids: [Int]) -> UINode? {
        var best: UINode?
        var bestArea = CGFloat.infinity
        for id in ids {
            let node = nodes[id]
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

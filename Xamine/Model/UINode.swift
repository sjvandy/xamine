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

    /// A scroll indicator on iOS ("Vertical scroll bar, 1 page"): an `other` the system draws over scrolling content.
    /// It overlaps the real elements, so it's never what someone is pointing at.
    var isScrollIndicator: Bool {
        kind.typeName == "other" && label?.localizedCaseInsensitiveContains("scroll bar") == true
    }
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

    /// Some home screen widgets report the frames of what they draw relative to the widget itself, not the screen, so
    /// their buttons and text come out far from where they are (a DOOR widget's buttons landed 90pt up and 27pt left).
    /// For each `icon` (that's what SpringBoard calls a widget or app) whose contents mostly lie outside its frame yet
    /// all fit once shifted by its origin, shift the ones outside. Scrolling content that merely overhangs a container
    /// never qualifies, since most of it must be outside and every outsider must land inside.
    mutating func moveWidgetContentsOntoTheScreen() {
        for container in nodes where container.kind.typeName == "icon" {
            guard let frame = nodes[container.id].frame, frame.width >= 40, frame.height >= 40,
                  frame.minX != 0 || frame.minY != 0 else { continue }
            let inner = descendantIDs(of: container.id).filter { id in
                guard let f = nodes[id].frame, f.width > 0, f.height > 0 else { return false }
                return !nodes[id].isScrollIndicator
            }
            guard inner.count >= 3 else { continue }
            let loose = frame.insetBy(dx: -2, dy: -2)
            let outside = inner.filter { !loose.contains(nodes[$0].frame!) }
            guard outside.count * 2 >= inner.count else { continue }
            let shifted = outside.filter { loose.contains(nodes[$0].frame!.offsetBy(dx: frame.minX, dy: frame.minY)) }
            guard shifted.count == outside.count else { continue }
            // Only the nodes that were outside: a widget can mix both kinds (the Lock Screen's Calendar widget has a
            // wrapper in screen coordinates around text measured from the widget), and shifting the others
            // would send them off the screen.
            for id in outside {
                nodes[id].frame = nodes[id].frame?.offsetBy(dx: frame.minX, dy: frame.minY)
            }
        }
    }

    private func descendantIDs(of id: Int) -> [Int] {
        var result: [Int] = []
        var stack = nodes[id].childIDs
        while let next = stack.popLast() {
            result.append(next)
            stack.append(contentsOf: nodes[next].childIDs)
        }
        return result
    }

    /// Every layer under `point`, outermost first: the deepest hit plus each ancestor whose frame also contains the point.
    func hitStack(_ point: CGPoint) -> [Int] {
        guard let deepest = hitTest(point) else { return [] }
        let hit = namedAlternative(to: deepest, at: point) ?? deepest
        return (ancestors(of: hit.id) + [hit])
            .filter { $0.frame?.contains(point) == true }
            .map(\.id)
    }

    /// The layer to pick by default from a `hitStack`. When the deepest layer has nothing to query by (no identifier,
    /// label, title or value), the nearest labeled layer above it wins if it isn't much bigger: an icon's artwork or a
    /// cell's inner view is hard to grab, and the labeled icon or cell around it is what a test would use. A labeled
    /// layer more than `maxEnclosureRatio` times the area is a container, and the deep pick stays. The other layers
    /// remain reachable in the stack.
    func preferredLayer(in stack: [Int]) -> Int? {
        guard let deepest = stack.last else { return nil }
        guard !nodes[deepest].hasSelector, let frame = nodes[deepest].frame, frame.width * frame.height > 0 else { return deepest }
        let area = frame.width * frame.height
        for id in stack.dropLast().reversed() {
            guard let outer = nodes[id].frame else { continue }
            if outer.width * outer.height > area * Self.maxEnclosureRatio { break }
            if nodes[id].hasSelector && !nodes[id].isScrollIndicator { return id }
        }
        return deepest
    }

    /// How much bigger than the deepest element a labeled layer above it can be and still be picked in its place.
    static let maxEnclosureRatio: CGFloat = 2.5

    /// The deepest node whose frame contains `point` (global coordinates), preferring the smallest area on ties.
    func hitTest(_ point: CGPoint) -> UINode? {
        var best: UINode?
        var bestArea = CGFloat.infinity
        for node in nodes {
            guard let frame = node.frame, frame.width > 0, frame.height > 0, frame.contains(point), !node.isScrollIndicator else { continue }
            let area = frame.width * frame.height
            if area < bestArea || (area == bestArea && node.depth > (best?.depth ?? -1)) {
                best = node
                bestArea = area
            }
        }
        return best
    }

    /// A named node on another branch whose area is within 5% of `hit`'s, if `hit` itself has nothing to query by.
    /// Overlays often put an unnamed effect or wrapper a point smaller than the named element it covers (Spotlight's
    /// prompt does); the named one makes the better query. Ancestors of `hit` are left alone, so a view stacked on a
    /// labeled cell stays reachable in the stack as before.
    private func namedAlternative(to hit: UINode, at point: CGPoint) -> UINode? {
        guard !hit.hasSelector, let hitFrame = hit.frame else { return nil }
        let limit = hitFrame.width * hitFrame.height * 1.05
        let ancestorIDs = Set(ancestors(of: hit.id).map(\.id))
        return nodes.filter { node in
            guard node.id != hit.id, node.hasSelector, !node.isScrollIndicator, !ancestorIDs.contains(node.id),
                  let frame = node.frame, frame.width > 0, frame.height > 0, frame.contains(point) else { return false }
            return frame.width * frame.height <= limit
        }
        .min { ($0.frame!.width * $0.frame!.height, -$0.depth) < ($1.frame!.width * $1.frame!.height, -$1.depth) }
    }
}

extension Optional where Wrapped == String {
    /// The wrapped string if it is non-nil and not just whitespace.
    var nonEmpty: String? {
        guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return self
    }
}

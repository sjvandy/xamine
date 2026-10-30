import Testing
import CoreGraphics
@testable import Xamine

/// Builds a tree from (parent, role, identifier, title) tuples; node 0 must have parent `nil`.
private func makeTree(
    _ specs: [(parent: Int?, role: String, identifier: String?, title: String?)],
    platform: TargetPlatform = .macOS
) -> UITree {
    var nodes: [UINode] = []
    for (index, spec) in specs.enumerated() {
        let depth = spec.parent.map { nodes[$0].depth + 1 } ?? 0
        nodes.append(UINode(
            id: index, parentID: spec.parent, depth: depth,
            kind: .forRole(spec.role), role: spec.role,
            identifier: spec.identifier, title: spec.title,
            frame: CGRect(x: 0, y: 0, width: 100 - depth, height: 100 - depth)
        ))
        if let parent = spec.parent { nodes[parent].childIDs.append(index) }
    }
    return UITree(nodes: nodes, appName: "Test", bundleID: "com.example.test", platform: platform, windowFrame: .zero)
}

private let sample = makeTree([
    (nil, "AXWindow", nil, "Main"),          // 0
    (0, "AXGroup", nil, nil),                // 1
    (1, "AXButton", "saveButton", "Save"),   // 2
    (1, "AXStaticText", nil, nil),           // 3
    (1, "AXButton", nil, "Cancel"),          // 4
    (0, "AXGroup", nil, nil),                // 5
    (5, "AXButton", nil, "Cancel"),          // 6
    (5, "AXButton", nil, nil),               // 7
])

/// Mirrors the Tips search results: a single scroll view inside an identified split group.
private let tips = makeTree([
    (nil, "AXWindow", "Tips", "Tips"),                    // 0
    (0, "AXGroup", nil, nil),                             // 1
    (1, "AXSplitGroup", "Tips, SplitView", nil),          // 2
    (2, "AXGroup", nil, nil),                             // 3
    (3, "AXScrollArea", nil, nil),                        // 4
    (4, "AXStaticText", nil, nil),                        // 5
    (4, "AXStaticText", nil, nil),                        // 6
    (4, "AXStaticText", nil, nil),                        // 7
    (1, "AXGroup", nil, nil),                             // 8
])

@Suite struct QueryBuilderTests {
    let builder = QueryBuilder(tree: sample, includeAppDeclaration: false)

    @Test func prefersAccessibilityIdentifier() {
        let snippet = builder.identifierSnippet(for: sample.node(2))
        #expect(snippet?.code == #"app.buttons["saveButton"]"#)
        #expect(snippet?.note == nil)
    }

    @Test func disambiguatesDuplicateLabels() {
        let first = builder.identifierSnippet(for: sample.node(4))
        let second = builder.identifierSnippet(for: sample.node(6))
        #expect(first?.code == #"app.buttons.matching(identifier: "Cancel").element(boundBy: 0)"#)
        #expect(second?.code == #"app.buttons.matching(identifier: "Cancel").element(boundBy: 1)"#)
        #expect(second?.note?.contains("2 buttons") == true)
    }

    @Test func noIdentifierReturnsNil() {
        #expect(builder.identifierSnippet(for: sample.node(7)) == nil)
    }

    @Test func hierarchyIndexesAmongSameTypeSiblings() {
        // Node 4 is the second button in the first group (the static text between them doesn't count).
        let code = builder.hierarchySnippet(for: 4).code
        #expect(code == """
        app.windows.firstMatch
            .children(matching: .group).element(boundBy: 0)
            .children(matching: .button).element(boundBy: 1)
        """)
        #expect(builder.breadcrumb(for: 4) == "Window ▸ Group 1 ▸ Button 2")
    }

    @Test func hierarchyForRootIsWindow() {
        #expect(builder.hierarchySnippet(for: 0).code == "app.windows.firstMatch")
    }

    @Test func appDeclarationAndAction() {
        var builder = QueryBuilder(tree: sample, action: .interact)
        let code = builder.identifierSnippet(for: sample.node(2))?.code
        #expect(code == """
        let app = XCUIApplication(bundleIdentifier: "com.example.test")
        app.buttons["saveButton"].click()
        """)
        builder.action = .exists
        builder.includeAppDeclaration = false
        #expect(builder.identifierSnippet(for: sample.node(2))?.code == #"XCTAssertTrue(app.buttons["saveButton"].exists)"#)
    }

    @Test func simulatorQueriesStartAtContentRoot() {
        var tree = makeTree([
            (nil, "AXWindow", nil, "iPhone"),   // 0
            (0, "AXGroup", nil, nil),           // 1 — iOS content
            (1, "AXButton", nil, "Log In"),     // 2
            (0, "AXButton", nil, "Log In"),     // 3 — Simulator chrome, out of scope
        ], platform: .iOSSimulator)
        tree.queryRootID = 1
        let builder = QueryBuilder(tree: tree, action: .interact)
        #expect(builder.identifierSnippet(for: tree.node(2))?.code == "let app = XCUIApplication()\napp.buttons[\"Log In\"].tap()")
        #expect(builder.hierarchySnippet(for: 2).code.hasSuffix("app\n    .children(matching: .button).element(boundBy: 0).tap()"))
        #expect(builder.breadcrumb(for: 2) == "App ▸ Button 1")
    }

    @Test func containerQueryStartsAtUniqueType() {
        let builder = QueryBuilder(tree: tips, includeAppDeclaration: false)
        #expect(builder.containerSnippet(for: 7).code == """
        app.scrollViews.firstMatch
            .children(matching: .staticText).element(boundBy: 2)
        """)
        // The scroll view itself needs no steps.
        #expect(builder.containerSnippet(for: 4).code == "app.scrollViews.firstMatch")
    }

    @Test func containerQueryFallsBackToFullPath() {
        let snippet = builder.containerSnippet(for: 4)
        #expect(snippet.code == builder.hierarchySnippet(for: 4).code)
        #expect(snippet.note?.contains("full path") == true)
    }

    @Test func anchoredQueryUsesIdentifiedAncestor() {
        let builder = QueryBuilder(tree: tips, includeAppDeclaration: false)
        #expect(builder.anchoredSnippet(for: 6)?.code == """
        app.splitGroups["Tips, SplitView"]
            .children(matching: .group).element(boundBy: 0)
            .children(matching: .scrollView).element(boundBy: 0)
            .children(matching: .staticText).element(boundBy: 1)
        """)
    }

    @Test func anchoredQueryUsesIdentifiedSibling() {
        // The "Cancel" button sits next to "saveButton" in the first group.
        #expect(builder.anchoredSnippet(for: 4)?.code == """
        app.groups.containing(.button, identifier: "saveButton").firstMatch
            .children(matching: .button).element(boundBy: 1)
        """)
    }

    @Test func anchoredQueryIsNilWithoutAnchors() {
        #expect(builder.anchoredSnippet(for: 7) == nil)
    }

    @Test func escapesStringLiterals() {
        #expect(QueryBuilder.literal("Say \"hi\"\n\\") == #""Say \"hi\"\n\\""#)
    }

    @Test func roleMapping() {
        #expect(ElementKind.forRole("AXButton").queryName == "buttons")
        #expect(ElementKind.forRole("AXTextField", subrole: "AXSecureTextField").typeName == "secureTextField")
        #expect(ElementKind.forRole("AXSomethingNew").typeName == "other")
        #expect(ElementKind.forRole("AXRow", subrole: "AXOutlineRow").queryName == "outlineRows")
    }

    @Test func hitTestPicksSmallestContainingFrame() {
        #expect(sample.hitTest(CGPoint(x: 10, y: 10))?.depth == 2)
    }
}

/// Elements found only by value or placeholder, per Apple's docs: the subscript and `matching(identifier:)` match
/// identifier, title, label, value or placeholderValue.
@Suite struct IdentifyingPropertyTests {
    private static func tree() -> UITree {
        var nodes = [
            UINode(id: 0, parentID: nil, depth: 0, kind: .forRole("AXWindow"), role: "AXWindow"),
            UINode(id: 1, parentID: 0, depth: 1, kind: .forRole("AXTextField"), role: "AXTextField", subrole: "AXSearchField", placeholder: "Search"),
            UINode(id: 2, parentID: 0, depth: 1, kind: .forRole("AXStaticText"), role: "AXStaticText", value: "Steven’s Pro iPhone"),
            UINode(id: 3, parentID: 0, depth: 1, kind: .forRole("AXStaticText"), role: "AXStaticText", value: "Steven’s Pro iPhone"),
            UINode(id: 4, parentID: 0, depth: 1, kind: .forRole("AXStaticText"), role: "AXStaticText", value: "42"),
        ]
        nodes[0].childIDs = [1, 2, 3, 4]
        return UITree(nodes: nodes, appName: "Test", bundleID: "com.example.test", platform: .macOS, windowFrame: .zero)
    }

    let builder = QueryBuilder(tree: tree(), includeAppDeclaration: false)

    @Test func placeholderUsesSubscript() {
        let kind = builder.tree.node(1).kind.queryName
        #expect(builder.identifierSnippet(for: builder.tree.node(1))?.code == "app.\(kind)[\"Search\"]")
    }

    @Test func duplicateValuesUseMatchingIdentifier() {
        #expect(builder.identifierSnippet(for: builder.tree.node(3))?.code == #"app.staticTexts.matching(identifier: "Steven’s Pro iPhone").element(boundBy: 1)"#)
    }

    @Test func numericValuesAreNotKeys() {
        #expect(builder.identifierSnippet(for: builder.tree.node(4)) == nil)
    }

    @Test func noPredicatesGenerated() {
        for id in builder.tree.nodes.indices {
            #expect(builder.identifierSnippet(for: builder.tree.node(id))?.code.contains("NSPredicate") != true)
        }
    }
}

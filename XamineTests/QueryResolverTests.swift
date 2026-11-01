import Testing
import CoreGraphics
@testable import Xamine

/// Builds a tree from (parent, role, identifier, title) tuples; node 0 must have parent `nil`.
private func makeTree(_ specs: [(parent: Int?, role: String, identifier: String?, title: String?)]) -> UITree {
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
    return UITree(nodes: nodes, appName: "Test", bundleID: "com.example.test", platform: .macOS, windowFrame: .zero)
}

private let cart = makeTree([
    (nil, "AXWindow", nil, "Cart"),                       // 0
    (0, "AXGroup", nil, nil),                             // 1
    (1, "AXButton", "place-order-button", "Place Order"), // 2
    (1, "AXStaticText", "cart-total", "$9.50"),           // 3
    (1, "AXButton", nil, "Remove"),                       // 4
    (0, "AXGroup", nil, nil),                             // 5
    (5, "AXButton", nil, "Remove"),                       // 6
    (5, "AXStaticText", nil, "Cold Brew"),                // 7
])

@Suite struct QueryResolverTests {
    let resolver = QueryResolver(tree: cart)

    private func matches(_ query: String) throws -> [Int] {
        try resolver.resolve(QueryResolver.parse(query)).matches
    }

    @Test func subscriptMatchesAnyIdentifyingProperty() throws {
        #expect(try matches(#"app.buttons["place-order-button"]"#) == [2])
        #expect(try matches(#"app.buttons["Place Order"]"#) == [2])
        #expect(try matches(#"app.windows["Cart"]"#) == [0])
    }

    @Test func reportsWhereAQueryStopsMatching() throws {
        let steps = try QueryResolver.parse(#"app.windows["Shopping Cart"].buttons.firstMatch"#)
        let resolution = resolver.resolve(steps)
        #expect(resolution.matches.isEmpty)
        #expect(resolution.failedStep == 1)
        #expect(resolution.counts == [1, 0, 0, 0])
        #expect(resolver.candidates(before: 1, in: steps) == [0])
    }

    @Test func indexesAndFirstMatch() throws {
        #expect(try matches(#"app.buttons.matching(identifier: "Remove").element(boundBy: 1)"#) == [6])
        #expect(try matches("app.buttons.firstMatch") == [2])
        #expect(try matches("app.buttons.element(boundBy: 5)") == [])
    }

    @Test func childrenAndDescendants() throws {
        #expect(try matches("app.windows.firstMatch.children(matching: .group).element(boundBy: 1).children(matching: .button).element(boundBy: 0)") == [6])
        #expect(try matches("app.descendants(matching: .staticText)") == [3, 7])
        #expect(try matches("app.groups.element(boundBy: 0).descendants(matching: .any)") == [2, 3, 4])
    }

    @Test func containingAndTypedMatching() throws {
        #expect(try matches(#"app.groups.containing(.staticText, identifier: "Cold Brew").buttons["Remove"]"#) == [6])
        #expect(try matches(#"app.descendants(matching: .any).matching(.button, identifier: "Remove")"#) == [4, 6])
    }

    @Test func predicates() throws {
        #expect(try matches(#"app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'brew'"))"#) == [7])
        #expect(try matches(#"app.buttons.matching(NSPredicate(format: "label BEGINSWITH \"Place\""))"#) == [2])
        #expect(try matches(#"app.windows.matching(NSPredicate(format: "title LIKE 'C*t'"))"#) == [0])
    }

    @Test func ignoresAssertionWrappersAndTrailingMembers() throws {
        #expect(try matches(#"XCTAssertTrue(app.windows["Cart"].waitForExistence(timeout: 5))"#) == [0])
        #expect(try matches(#"app.buttons["place-order-button"].click()"#) == [2])
        #expect(try matches(#"XCUIApplication(bundleIdentifier: "com.example.test").staticTexts["cart-total"].exists"#) == [3])
        #expect(try matches(##"app.buttons[#"Place Order"#]"##) == [2])
    }

    @Test func rejectsUnsupportedSyntax() {
        #expect(throws: QueryResolver.ParseError.self) { try QueryResolver.parse("button.click()") }
        #expect(throws: QueryResolver.ParseError.self) {
            try QueryResolver.parse(#"app.buttons.matching(NSPredicate(format: "label == 'a' OR label == 'b'"))"#)
        }
    }

    @Test func everyGeneratedQueryResolvesToItsElement() throws {
        let builder = QueryBuilder(tree: cart, includeAppDeclaration: false)
        for node in cart.nodes where node.id != 0 {
            let queries = builder.queries(for: node.id)
            for code in [queries.byIdentifier?.code, queries.fromAnchor?.code, queries.byHierarchy.code].compactMap({ $0 }) {
                #expect(try matches(code) == [node.id], "\(code)")
            }
            #expect(try matches(builder.bestQuery(for: node.id)) == [node.id])
        }
    }

    @Test func similarityFavorsRelatedText() {
        #expect(QueryResolver.similarity("Shopping Cart", "Cart") > QueryResolver.similarity("Shopping Cart", "Profile"))
        #expect(QueryResolver.similarity("Cart", "cart") == 1)
    }
}

@Suite struct TestComposerTests {
    @Test func namesTestsAndVariables() {
        #expect(TestComposer.typeName(from: "order cold brew") == "OrderColdBrew")
        #expect(TestComposer.typeName(from: "OrderColdBrewTests") == "OrderColdBrew")
        #expect(TestComposer.variableName(for: #"app.buttons["add-to-cart-button"]"#) == "addToCartButton")
        #expect(TestComposer.variableName(for: #"app.outlineRows["sidebar-cold"]"#) == "sidebarColdOutlineRow")
        #expect(TestComposer.variableName(for: "app.searchFields.firstMatch") == "searchField")
    }

    @Test func lines() {
        #expect(TestComposer.line(for: .init(query: #"app.buttons["OK"]"#, action: .click)) == #"app.buttons["OK"].click()"#)
        #expect(TestComposer.line(for: .init(query: nil, action: .typeKey(key: ".return", modifiers: []))) == "app.typeKey(.return, modifierFlags: [])")
        #expect(TestComposer.line(for: .init(query: nil, action: .typeKey(key: "\"a\"", modifiers: ["command", "shift"])))
            == #"app.typeKey("a", modifierFlags: [.command, .shift])"#)
        #expect(TestComposer.line(for: .init(query: "app.staticTexts[\"Done\"]", action: .assertExists(timeout: 5)))
            == #"XCTAssertTrue(app.staticTexts["Done"].waitForExistence(timeout: 5))"#)
    }

    @Test func composesAFile() {
        var composer = TestComposer(name: "search reminders", bundleID: "com.apple.tips")
        composer.steps = [
            .init(query: #"app.searchFields["Search"]"#, action: .click),
            .init(query: #"app.searchFields["Search"]"#, action: .typeText("reminders")),
            .init(query: nil, action: .typeKey(key: ".return", modifiers: [])),
            .init(query: #"app.staticTexts["Results"]"#, action: .assertExists(timeout: 5)),
        ]
        let source = composer.source()
        #expect(source.contains("final class SearchRemindersTests: XCTestCase"))
        #expect(source.contains("func testSearchReminders() throws"))
        #expect(source.contains(#"let app = XCUIApplication(bundleIdentifier: "com.apple.tips")"#))
        #expect(source.contains(#"        let searchField = app.searchFields["Search"]"#))
        #expect(source.components(separatedBy: "let searchField").count == 2) // declared once, reused
        #expect(source.contains(#"searchField.typeText("reminders")"#))
        #expect(source.contains(#"XCTAssertTrue(app.staticTexts["Results"].waitForExistence(timeout: 5))"#))
    }
}

@Suite struct JSONValueTests {
    @Test func roundTrips() throws {
        let value: JSONValue = ["id": 3, "method": "click", "params": ["element": "e12", "clear": true, "timeout": .number(2.5)]]
        let decoded = try JSONValue.decode(value.encoded())
        #expect(decoded == value)
        #expect(decoded["params"]?["element"]?.string == "e12")
        #expect(String(decoding: JSONValue.number(3).encoded(), as: UTF8.self) == "3")
    }
}

@Suite struct ElementTypeFidelityTests {
    @Test func roleLessElementsUseTheirAutomationType() {
        // SwiftUI NavigationLink rows: no AXRole, AXAutomationType 9 (button), as XCUITest reports them.
        #expect(HierarchyScanner.kind(role: "AXUnknown", subrole: nil, automationType: 9).typeName == "button")
        #expect(HierarchyScanner.kind(role: "AXUnknown", subrole: nil, automationType: 48).typeName == "staticText")
        // A known role wins, and unknown or out-of-range types fall back to other.
        #expect(HierarchyScanner.kind(role: "AXWindow", subrole: nil, automationType: 2).typeName == "window")
        #expect(HierarchyScanner.kind(role: "AXUnknown", subrole: nil, automationType: 1).typeName == "other")
        #expect(HierarchyScanner.kind(role: "AXUnknown", subrole: nil, automationType: 999).typeName == "other")
        #expect(HierarchyScanner.kind(role: "AXUnknown", subrole: nil, automationType: nil).typeName == "other")
    }

    @Test func generatedIdentifiersAreNotKeys() {
        let window = UINode(id: 0, parentID: nil, depth: 0, kind: .window, role: "AXWindow",
                            identifier: "SwiftUI.WindowGroup<Brewline.RootView>-1-AppWindow-1", title: "Cart")
        let alertText = UINode(id: 1, parentID: 0, depth: 1, kind: .forRole("AXStaticText"), role: "AXStaticText",
                               identifier: "_NS:74", value: "Added to cart")
        #expect(window.bestKey == "Cart")
        #expect(window.bestKeySource == "title")
        #expect(alertText.bestKey == "Added to cart")
        // They still count when matching, since XCUITest compares against them.
        #expect(alertText.matchesIdentifier("_NS:74"))

        var tree = UITree(nodes: [window, alertText], appName: "Brewline", bundleID: "com.sjvandy.Brewline", platform: .macOS, windowFrame: .zero)
        tree.nodes[0].childIDs = [1]
        let builder = QueryBuilder(tree: tree, includeAppDeclaration: false)
        #expect(builder.bestQuery(for: 0) == #"app.windows["Cart"]"#)
        #expect(builder.bestQuery(for: 1) == #"app.staticTexts["Added to cart"]"#)
    }
}

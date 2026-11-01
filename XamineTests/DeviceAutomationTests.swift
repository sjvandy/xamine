import Foundation
import Testing
@testable import Xamine

/// iOS trees come from the agent's XCUITest snapshot, rooted at the application element itself.
@Suite struct DeviceAutomationTests {
    let json = """
    {"type":"application","frame":[0,0,402,874],"label":"Brewline","children":[
      {"type":"window","frame":[0,0,402,874],"children":[
        {"type":"navigationBar","frame":[0,62,402,54],"identifier":"Cart","children":[]},
        {"type":"button","frame":[16,130,370,44],"identifier":"place-order-button","label":"Place Order","children":[]},
        {"type":"tabBar","frame":[0,790,402,84],"children":[
          {"type":"button","frame":[0,790,134,84],"label":"Menu","children":[]},
          {"type":"button","frame":[134,790,134,84],"label":"Cart","children":[]}
        ]}
      ]}
    ]}
    """

    func tree() throws -> UITree {
        try JSONDecoder().decode(AgentNode.self, from: Data(json.utf8)).makeTree(appName: "Brewline", bundleID: "com.sjvandy.Brewline")
    }

    private func matches(_ query: String, in tree: UITree) throws -> [Int] {
        try QueryResolver(tree: tree).resolve(QueryResolver.parse(query)).matches
    }

    @Test func appIsTheSnapshotRoot() throws {
        let tree = try tree()
        #expect(try matches("app.children(matching: .window).element(boundBy: 0)", in: tree) == [1])
        #expect(try matches(#"app.navigationBars["Cart"]"#, in: tree) == [2])
        #expect(try matches(#"app.tabBars.buttons["Cart"]"#, in: tree) == [6])
        // The application itself isn't one of its own descendants.
        #expect(try matches("app.descendants(matching: .any)", in: tree).contains(0) == false)
    }

    @Test func everyGeneratedQueryResolvesOnIOS() throws {
        let tree = try tree()
        let builder = QueryBuilder(tree: tree, includeAppDeclaration: false)
        for node in tree.nodes where node.id != 0 {
            let queries = builder.queries(for: node.id)
            for code in [queries.byIdentifier?.code, queries.fromAnchor?.code, queries.byHierarchy.code].compactMap({ $0 }) {
                #expect(try matches(code, in: tree) == [node.id], "\(code)")
            }
        }
    }

    @Test func encodesStepsForTheAgent() throws {
        let steps = try QueryResolver.parse(#"app.tabBars.firstMatch.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'cart'")).element(boundBy: 0)"#)
        let json = QueryResolver.json(steps)
        #expect(json == [
            ["op": "descendants", "type": "tabBar"],
            ["op": "firstMatch"],
            ["op": "descendants", "type": "button"],
            ["op": "predicate", "key": "label", "operator": "CONTAINS", "value": "cart", "caseInsensitive": true],
            ["op": "boundBy", "index": 0],
        ])
        let keyed = QueryResolver.json(try QueryResolver.parse(#"app.otherElements.containing(.button, identifier: "x")"#))
        #expect(keyed == [["op": "descendants", "type": "other"], ["op": "containing", "type": "button", "key": "x"]])
    }

    @Test func composesIOSTests() {
        var composer = TestComposer(name: "search drinks", bundleID: "com.sjvandy.Brewline", platform: .iOSDevice)
        composer.steps = [
            .init(query: #"app.buttons["Menu"]"#, action: .click),
            .init(query: #"app.searchFields["Search drinks"]"#, action: .typeText("latte")),
            .init(query: nil, action: .typeText("\n")),
            .init(query: #"app.collectionViews.firstMatch"#, action: .swipe("up")),
            .init(query: nil, action: .deviceButton("home")),
        ]
        let source = composer.source()
        #expect(source.contains("menuButton.tap()"))
        // A field gets a tap for keyboard focus before typing.
        #expect(source.contains("searchDrinksSearchField.tap()\n        searchDrinksSearchField.typeText(\"latte\")"))
        #expect(source.contains(#"app.typeText("\n")"#))
        #expect(source.contains("collection.swipeUp()"))
        #expect(source.contains("XCUIDevice.shared.press(.home)"))
        #expect(!source.contains(".click()"))
    }

    @Test func noExtraTapAfterTappingTheSameField() {
        var composer = TestComposer(name: "x", bundleID: "b", platform: .iOSDevice)
        composer.steps = [
            .init(query: #"app.textFields["name-field"]"#, action: .click),
            .init(query: #"app.textFields["name-field"]"#, action: .typeText("Sam")),
        ]
        #expect(composer.source().components(separatedBy: "nameFieldTextField.tap()").count == 2) // exactly one tap
    }

    @Test func symbolNamesAreNotKeysAndSelectionComesThrough() throws {
        let json = """
        {"type":"application","frame":[0,0,1133,744],"children":[
          {"type":"button","frame":[400,20,100,40],"identifier":"bag","label":"Cart","selected":true,"children":[]},
          {"type":"button","frame":[520,20,100,40],"identifier":"cup.and.saucer","label":"Menu","selected":false,"children":[]},
          {"type":"image","frame":[0,100,40,40],"identifier":"empty-cart","children":[]}
        ]}
        """
        let tree = try JSONDecoder().decode(AgentNode.self, from: Data(json.utf8)).makeTree(appName: "Brewline", bundleID: "b")
        let builder = QueryBuilder(tree: tree, includeAppDeclaration: false)
        #expect(builder.bestQuery(for: 1) == #"app.buttons["Cart"]"#)
        #expect(builder.bestQuery(for: 2) == #"app.buttons["Menu"]"#)
        #expect(builder.bestQuery(for: 3) == #"app.images["empty-cart"]"#)
        #expect(tree.node(1).isSelected == true)
        #expect(UINode.isSymbolName("chevron.forward"))
        #expect(!UINode.isSymbolName("sidebar"))
        #expect(!UINode.isSymbolName("drink-latte"))
    }
}

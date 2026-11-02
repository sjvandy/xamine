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
        #expect(composer.source().components(separatedBy: "nameField.tap()").count == 2) // exactly one tap
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

@MainActor @Suite struct ForegroundCandidateTests {
    @Test func spotlightIsCheckedBeforeAppsAndSpringBoardFallsBack() {
        let candidates = DeviceManager().foregroundCandidates
        #expect(candidates.first == "com.apple.campo")
        #expect(candidates.firstIndex(of: "com.apple.campo")! < candidates.firstIndex(of: "com.apple.mobilesafari")!)
        #expect(!candidates.contains("com.apple.CarPlayApp"))
        #expect(Set(candidates).count == candidates.count)
    }
}

/// Spotlight draws an unnamed effect view a point smaller than its named prompt container.
@Suite struct NamedElementPreferenceTests {
    let tree: UITree = {
        let json = """
        {"type":"application","frame":[0,0,402,874],"children":[
          {"type":"window","frame":[0,0,402,874],"children":[
            {"type":"other","frame":[14,14,375,101],"identifier":"SpotlightPromptContainer","children":[
              {"type":"textView","frame":[52,52,299,25],"identifier":"SpotlightSearchField","placeholder":"Search or Ask","children":[]}]}]},
          {"type":"window","frame":[0,0,402,874],"children":[
            {"type":"other","frame":[13,13,374,100],"children":[]},
            {"type":"other","frame":[0,300,402,200],"children":[
              {"type":"other","frame":[10,310,80,60],"children":[]}]}]}
        ]}
        """
        let root = try! JSONDecoder().decode(AgentNode.self, from: Data(json.utf8))
        return root.makeTree(appName: "Spotlight", bundleID: "com.apple.campo")
    }()

    @Test func namedElementBeatsANearlyIdenticalUnnamedOne() {
        func picked(_ x: Double, _ y: Double) -> UINode? {
            let stack = tree.hitStack(CGPoint(x: x, y: y))
            return tree.preferredLayer(in: stack).map { tree.node($0) }
        }
        #expect(picked(200, 100)?.identifier == "SpotlightPromptContainer")
        // A clearly smaller named element still wins over both.
        #expect(picked(100, 64)?.identifier == "SpotlightSearchField")
    }

    @Test func unnamedElementsStillGetPickedWhenNothingNamedIsNearlyAsSmall() {
        let stack = tree.hitStack(CGPoint(x: 20, y: 320))
        let hit = tree.preferredLayer(in: stack).map { tree.node($0) }
        #expect(hit?.frame == CGRect(x: 10, y: 310, width: 80, height: 60))
        #expect(hit?.hasSelector == false)
    }

    @Test func scrollIndicatorsAreNeverPicked() throws {
        let json = """
        {"type":"application","frame":[0,0,402,874],"children":[
          {"type":"window","frame":[0,0,402,874],"children":[
            {"type":"textView","frame":[52,52,299,25],"identifier":"SpotlightSearchField","children":[
              {"type":"other","frame":[52,61,299,13],"label":"Horizontal scroll bar, 1 page","children":[]}]}]}]}
        """
        let root = try JSONDecoder().decode(AgentNode.self, from: Data(json.utf8))
        let tree = root.makeTree(appName: "Spotlight", bundleID: "com.apple.campo")
        let id = tree.preferredLayer(in: tree.hitStack(CGPoint(x: 150, y: 66)))
        #expect(id.map { tree.node($0).identifier } == "SpotlightSearchField")
    }
}

/// Spotlight's result tiles: a labeled icon wraps unlabeled artwork, inside a labeled cell inside a big container.
@Suite struct EnclosingLabelPreferenceTests {
    let tree: UITree = {
        let json = """
        {"type":"application","frame":[0,0,402,874],"children":[
          {"type":"window","frame":[0,0,402,874],"children":[
            {"type":"collectionView","frame":[14,128,375,404],"children":[
              {"type":"cell","frame":[204,154,78,91],"label":"Instagram","children":[
                {"type":"icon","frame":[204,154,78,91],"identifier":"Instagram","label":"Instagram","children":[
                  {"type":"other","frame":[211,156,64,78],"children":[
                    {"type":"other","frame":[211,156,64,64],"children":[
                      {"type":"other","frame":[211,156,64,64],"children":[]}]}]}]}]}]}]}]}
        """
        let root = try! JSONDecoder().decode(AgentNode.self, from: Data(json.utf8))
        return root.makeTree(appName: "Spotlight", bundleID: "com.apple.campo")
    }()

    @Test func unlabeledArtworkYieldsToTheLabeledIcon() {
        let stack = tree.hitStack(CGPoint(x: 240, y: 190))
        let picked = tree.preferredLayer(in: stack).map { tree.node($0) }
        #expect(picked?.kind.typeName == "icon")
        #expect(picked?.identifier == "Instagram")
        // The artwork underneath is still in the stack, for stepping down to it.
        #expect(stack.count > stack.firstIndex { tree.node($0).kind.typeName == "icon" }! + 1)
    }

    @Test func aBigLabeledContainerIsNotWorthJumpingTo() {
        let json = """
        {"type":"application","frame":[0,0,402,874],"children":[
          {"type":"window","frame":[0,0,402,874],"children":[
            {"type":"cell","frame":[0,0,402,400],"label":"Big cell","children":[
              {"type":"other","frame":[20,20,50,50],"children":[]}]}]}]}
        """
        let root = try! JSONDecoder().decode(AgentNode.self, from: Data(json.utf8))
        let tree = root.makeTree(appName: "App", bundleID: "x")
        let id = tree.preferredLayer(in: tree.hitStack(CGPoint(x: 30, y: 30)))
        #expect(id.map { tree.node($0).frame } == CGRect(x: 20, y: 20, width: 50, height: 50))
    }

    @Test func aLabeledDeepestElementIsLeftAlone() {
        let json = """
        {"type":"application","frame":[0,0,402,874],"children":[
          {"type":"window","frame":[0,0,402,874],"children":[
            {"type":"cell","frame":[0,0,200,60],"label":"Row","children":[
              {"type":"button","frame":[150,10,40,40],"label":"Info","children":[]}]}]}]}
        """
        let root = try! JSONDecoder().decode(AgentNode.self, from: Data(json.utf8))
        let tree = root.makeTree(appName: "App", bundleID: "x")
        #expect(tree.preferredLayer(in: tree.hitStack(CGPoint(x: 170, y: 30))).map { tree.node($0).label } == "Info")
    }
}

/// Some widgets (DOOR's) report what they draw relative to the widget, not the screen.
@Suite struct WidgetFrameTests {
    private func tree(_ json: String) -> UITree {
        let root = try! JSONDecoder().decode(AgentNode.self, from: Data(json.utf8))
        return root.makeTree(appName: "SpringBoard", bundleID: "com.apple.springboard")
    }

    @Test func widgetContentsInLocalCoordinatesMoveOntoTheScreen() {
        // The widget is at (28, 91), 347x165. Its two buttons and image carry frames measured from the widget's corner.
        let tree = tree("""
        {"type":"application","frame":[0,0,402,874],"children":[{"type":"window","frame":[0,0,402,874],"children":[
          {"type":"icon","frame":[28,91,347,165],"label":"DOOR","children":[
            {"type":"other","frame":[0,0,347,165],"children":[
              {"type":"image","frame":[10,10,40,40],"label":"LatchIcon","children":[]},
              {"type":"button","frame":[12,34,162,122],"label":"2176","children":[]},
              {"type":"button","frame":[178,34,163,122],"label":"1265- Lower Elevator Lobby","children":[]}]}]}]}]}
        """)
        let button = tree.nodes.first { $0.label == "1265- Lower Elevator Lobby" }!
        #expect(button.frame == CGRect(x: 206, y: 125, width: 163, height: 122))
        #expect(tree.nodes.first { $0.label == "2176" }!.frame == CGRect(x: 40, y: 125, width: 162, height: 122))
        // Clicking where the button is drawn now finds it.
        #expect(tree.hitTest(CGPoint(x: 280, y: 190))?.label == "1265- Lower Elevator Lobby")
    }

    @Test func contentAlreadyOnTheScreenIsLeftAlone() {
        let tree = tree("""
        {"type":"application","frame":[0,0,402,874],"children":[{"type":"window","frame":[0,0,402,874],"children":[
          {"type":"icon","frame":[210,88,168,191],"label":"Calendar","children":[
            {"type":"other","frame":[212,90,164,178],"children":[
              {"type":"staticText","frame":[224,100,60,20],"label":"SUNDAY","children":[]},
              {"type":"staticText","frame":[224,200,120,40],"label":"Weekly Check-In","children":[]},
              {"type":"image","frame":[227,222,134,88],"children":[]}]}]}]}]}
        """)
        #expect(tree.nodes.first { $0.label == "SUNDAY" }!.frame == CGRect(x: 224, y: 100, width: 60, height: 20))
        #expect(tree.nodes.first { $0.kind.typeName == "image" }!.frame == CGRect(x: 227, y: 222, width: 134, height: 88))
    }

    @Test func scrollingContentThatOverhangsIsNotMoved() {
        // A widget stack whose pages sit side by side: one page is on the widget, the others are beside it.
        let tree = tree("""
        {"type":"application","frame":[0,0,402,874],"children":[{"type":"window","frame":[0,0,402,874],"children":[
          {"type":"icon","frame":[28,91,330,165],"label":"Stack","children":[
            {"type":"button","frame":[28,91,330,165],"label":"Page 1","children":[]},
            {"type":"button","frame":[358,91,330,165],"label":"Page 2","children":[]},
            {"type":"button","frame":[688,91,330,165],"label":"Page 3","children":[]}]}]}]}
        """)
        #expect(tree.nodes.first { $0.label == "Page 2" }!.frame == CGRect(x: 358, y: 91, width: 330, height: 165))
    }

    @Test func otherAppsAreNeverTouched() {
        let root = try! JSONDecoder().decode(AgentNode.self, from: Data("""
        {"type":"application","frame":[0,0,402,874],"children":[{"type":"window","frame":[0,0,402,874],"children":[
          {"type":"icon","frame":[28,91,330,165],"label":"X","children":[
            {"type":"button","frame":[5,5,50,50],"label":"a","children":[]},
            {"type":"button","frame":[60,5,50,50],"label":"b","children":[]},
            {"type":"button","frame":[115,5,50,50],"label":"c","children":[]}]}]}]}
        """.utf8))
        let tree = root.makeTree(appName: "Other", bundleID: "com.example.other")
        #expect(tree.nodes.first { $0.label == "a" }!.frame == CGRect(x: 5, y: 5, width: 50, height: 50))
    }

    @Test func aWidgetMixingBothKindsOfFramesOnlyMovesTheLocalOnes() {
        // The Lock Screen's Calendar widget: a wrapper already in screen coordinates around text measured from the widget.
        let tree = tree("""
        {"type":"application","frame":[0,0,402,874],"children":[{"type":"window","frame":[0,0,402,874],"children":[
          {"type":"icon","frame":[28,679,166,90],"label":"Calendar","children":[
            {"type":"other","frame":[30,681,162,72],"children":[
              {"type":"staticText","frame":[7,5,80,20],"label":"Tomorrow","children":[]},
              {"type":"staticText","frame":[15,26,95,20],"label":"11 – 11:30AM","children":[]},
              {"type":"staticText","frame":[15,46,128,20],"label":"Weekly Check-In","children":[]}]}]}]}]}
        """)
        #expect(tree.nodes.first { $0.kind.typeName == "other" }!.frame == CGRect(x: 30, y: 681, width: 162, height: 72))
        #expect(tree.nodes.first { $0.label == "Tomorrow" }!.frame == CGRect(x: 35, y: 684, width: 80, height: 20))
        #expect(tree.nodes.first { $0.label == "Weekly Check-In" }!.frame == CGRect(x: 43, y: 725, width: 128, height: 20))
    }
}

/// Spotlight's result cells: numbered identifiers whose hit box is the same as the icon's inside them.
@Suite struct EnclosingItemTests {
    private func tree(_ cellFrame: String = "[204,154,78,91]") -> UITree {
        let root = try! JSONDecoder().decode(AgentNode.self, from: Data("""
        {"type":"application","frame":[0,0,402,874],"children":[{"type":"window","frame":[0,0,402,874],"children":[
          {"type":"collectionView","frame":[14,128,375,404],"children":[
            {"type":"cell","frame":[40,154,78,91],"identifier":"Identifier:ResultCell,Section:0,Row:0","label":"Mail","children":[
              {"type":"icon","frame":[40,154,78,91],"identifier":"Mail","label":"Mail","children":[]}]},
            {"type":"cell","frame":\(cellFrame),"identifier":"Identifier:ResultCell,Section:0,Row:3","label":"Instagram","children":[
              {"type":"other","frame":[211,156,64,78],"children":[
                {"type":"icon","frame":[204,154,78,91],"identifier":"Instagram","label":"Instagram","children":[]}]}]},
            {"type":"cell","frame":[14,283,375,56],"identifier":"Identifier:ResultCell,Section:1,Row:0","label":"Chiefs vs Broncos","children":[]}]}]}]}
        """.utf8))
        return root.makeTree(appName: "Spotlight", bundleID: "com.apple.campo")
    }

    @Test func theContainerQueryIsTheNumberedCellWithTheSameHitBox() {
        let tree = tree()
        let icon = tree.nodes.first { $0.identifier == "Instagram" }!
        let builder = QueryBuilder(tree: tree, includeAppDeclaration: false)
        let queries = builder.queries(for: icon.id)
        #expect(queries.byIdentifier?.code == #"app.icons["Instagram"]"#)
        #expect(queries.fromContainer.code == #"app.cells["Identifier:ResultCell,Section:0,Row:3"]"#)
        #expect(queries.hasUniqueContainer)
        #expect(queries.containerIsEnclosing)
        // It names a different element, so it is never offered as the way to find this one.
        #expect(builder.bestQuery(for: icon.id) == #"app.icons["Instagram"]"#)
    }

    @Test func aCellMuchBiggerThanTheElementIsNotItsItem() {
        // The cell is a full-width row; the icon in it is a small part of it, not the same hit box.
        let tree = tree("[14,150,375,100]")
        let icon = tree.nodes.first { $0.identifier == "Instagram" }!
        #expect(!QueryBuilder(tree: tree, includeAppDeclaration: false).queries(for: icon.id).containerIsEnclosing)
    }

    @Test func anIdentifierWithoutASequenceIsNotAnItem() {
        let root = try! JSONDecoder().decode(AgentNode.self, from: Data("""
        {"type":"application","frame":[0,0,402,874],"children":[{"type":"window","frame":[0,0,402,874],"children":[
          {"type":"cell","frame":[0,0,100,100],"identifier":"SpotlightPromptContainer","children":[
            {"type":"button","frame":[0,0,100,100],"label":"Go","children":[]}]}]}]}
        """.utf8))
        let tree = root.makeTree(appName: "x", bundleID: "x")
        let button = tree.nodes.first { $0.label == "Go" }!
        #expect(!QueryBuilder(tree: tree, includeAppDeclaration: false).queries(for: button.id).containerIsEnclosing)
    }

    @Test func numberTemplatesFindSequencesAnywhereInTheIdentifier() {
        #expect(QueryBuilder.numberTemplate("Identifier:ResultCell,Section:0,Row:3") == "Identifier:ResultCell,Section:#,Row:#")
        #expect(QueryBuilder.numberTemplate("row-12") == "row-#")
        #expect(QueryBuilder.numberTemplate("tile_7_large") == "tile_#_large")
        #expect(QueryBuilder.numberTemplate("sidebar-cart") == "sidebar-cart")
        // A single numbered cell in its own section still matches its siblings in other sections.
        #expect(QueryBuilder.numberTemplate("…Section:1,Row:0") == QueryBuilder.numberTemplate("…Section:0,Row:3"))
    }

    @Test func overlapMeasuresTheSharedHitBox() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(QueryBuilder.overlap(a, a) == 1)
        #expect(QueryBuilder.overlap(a, CGRect(x: 0, y: 0, width: 50, height: 100)) == 0.5)
        #expect(QueryBuilder.overlap(a, CGRect(x: 200, y: 200, width: 10, height: 10)) == 0)
        #expect(QueryBuilder.overlap(a, CGRect(x: 1, y: 1, width: 98, height: 98)) > QueryBuilder.sameHitBox)
    }
}

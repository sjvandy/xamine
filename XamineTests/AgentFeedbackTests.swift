import Testing
import CoreGraphics
@testable import Xamine

/// Builds a tree of (parent, typeName, identifier, label) nodes; node 0 is the root.
private func makeTree(_ specs: [(parent: Int?, type: String, identifier: String?, label: String?)],
                      platform: TargetPlatform = .iOSDevice) -> UITree {
    var nodes: [UINode] = []
    for (index, spec) in specs.enumerated() {
        let depth = spec.parent.map { nodes[$0].depth + 1 } ?? 0
        nodes.append(UINode(id: index, parentID: spec.parent, depth: depth, kind: .forTypeName(spec.type), role: spec.type,
                            identifier: spec.identifier, label: spec.label,
                            frame: CGRect(x: 0, y: 0, width: 100 - depth, height: 100 - depth)))
        if let parent = spec.parent { nodes[parent].childIDs.append(index) }
    }
    return UITree(nodes: nodes, appName: "Test", bundleID: "com.example.test", platform: platform, windowFrame: .zero)
}

@Suite struct QueryReadabilityTests {
    @Test func firstDuplicateUsesFirstMatch() {
        let tree = makeTree([(nil, "window", nil, nil), (0, "button", nil, "Cart"), (0, "button", nil, "Cart")])
        let builder = QueryBuilder(tree: tree, includeAppDeclaration: false)
        #expect(builder.identifierSnippet(for: tree.node(1))?.code == #"app.buttons["Cart"].firstMatch"#)
        #expect(builder.identifierSnippet(for: tree.node(2))?.code == #"app.buttons.matching(identifier: "Cart").element(boundBy: 1)"#)
    }

    @Test func firstMatchFormResolvesToTheSameElement() throws {
        let tree = makeTree([(nil, "window", nil, nil), (0, "button", nil, "Cart"), (0, "button", nil, "Cart")])
        let steps = try QueryResolver.parse(#"app.buttons["Cart"].firstMatch"#)
        #expect(QueryResolver(tree: tree).resolve(steps).matches == [1])
    }

    @Test func keySharedAcrossTypesIsFlagged() {
        let tree = makeTree([(nil, "window", nil, nil), (0, "button", "cart-key", nil), (0, "image", "cart-key", nil)])
        let note = QueryBuilder(tree: tree, includeAppDeclaration: false).identifierSnippet(for: tree.node(1))?.note
        #expect(note?.contains("also used by Image") == true)
    }

    @Test func genericIdentifiersAreNotKeys() {
        var specs: [(parent: Int?, type: String, identifier: String?, label: String?)] = [(nil, "window", nil, nil)]
        for name in ["A", "B", "C", "D", "E"] { specs.append((0, "staticText", "label-view", name)) }
        var tree = makeTree(specs)
        #expect(tree.node(1).stableIdentifier == "label-view")
        tree.markGenericIdentifiers()
        #expect(tree.node(1).stableIdentifier == nil)
        #expect(tree.node(1).bestKey == "A")
    }

    @Test func uniqueIdentifiersStayKeys() {
        var tree = makeTree([(nil, "window", nil, nil), (0, "button", "add-to-cart", nil), (0, "button", "checkout", nil)])
        tree.markGenericIdentifiers()
        #expect(tree.node(1).stableIdentifier == "add-to-cart")
    }
}

@Suite struct TextFreeQueryTests {
    /// A window with `depth` nested groups (two at each level, so no type is unique) holding two buttons.
    private static func deepTree(depth: Int) -> UITree {
        var specs: [(parent: Int?, type: String, identifier: String?, label: String?)] = [(nil, "window", nil, nil)]
        var parent = 0
        for _ in 0..<depth {
            specs.append((parent, "other", nil, nil))
            specs.append((parent, "other", nil, nil))
            parent = specs.count - 2
        }
        specs.append((parent, "button", nil, nil))
        specs.append((parent, "button", nil, nil))
        return makeTree(specs)
    }

    @Test func longTextFreeQueryIsDropped() {
        let tree = Self.deepTree(depth: 10)
        let builder = QueryBuilder(tree: tree, includeAppDeclaration: false)
        let button = tree.nodes.count - 2
        #expect(builder.textFreeAlternative(for: button) == nil)
        let titles = builder.offeredQueries(for: button).map(\.title)
        #expect(titles.last?.contains("too fragile") == true)
    }

    @Test func shortTextFreeQueryIsOffered() {
        let tree = Self.deepTree(depth: 2)
        let builder = QueryBuilder(tree: tree, includeAppDeclaration: false)
        #expect(builder.textFreeAlternative(for: tree.nodes.count - 2) != nil)
    }

    @Test func barsAreNeverTextFree() {
        let tree = makeTree([(nil, "window", nil, nil), (0, "navigationBar", nil, nil), (0, "button", nil, nil)])
        let builder = QueryBuilder(tree: tree, includeAppDeclaration: false)
        #expect(builder.textFreeAlternative(for: 1) == nil)
        #expect(builder.offeredQueries(for: 1).last?.title == "By hierarchy")
    }

    @Test func stepCounting() {
        #expect(QueryBuilder.stepCount("app.a\n    .children(matching: .other).element(boundBy: 0)\n    .children(matching: .other).element(boundBy: 1)") == 2)
    }
}

@Suite struct InteractiveFilterTests {
    @Test func keepsControlsAndDropsNoise() {
        let tree = makeTree([
            (nil, "window", nil, nil),
            (0, "button", nil, "Add"),            // 1 labeled button
            (0, "button", nil, nil),              // 2 unlabeled chrome
            (0, "staticText", nil, "Hello"),      // 3 text
            (0, "image", "logo", nil),            // 4 image
            (0, "other", nil, "Vertical scroll bar, 1 page"), // 5 scroll indicator
            (0, "switch", nil, nil),              // 6 switch
            (0, "textField", nil, nil),           // 7 field
            (0, "cell", "row-1", nil),            // 8 identified cell
            (0, "cell", nil, nil),                // 9 anonymous cell
            (0, "slider", nil, nil),              // 10 slider
        ])
        let kept = tree.nodes.filter(\.isInteractive).map(\.id)
        #expect(kept == [1, 6, 7, 8, 10])
    }
}

@Suite struct WaitForAttributeTests {
    @Test func composerRecordsLabelAndValueAssertions() {
        let label = TestComposer.line(for: .init(query: #"app.staticTexts["Total"]"#, action: .assertAttribute(name: "label", expected: "$12.50", timeout: 5)), platform: .iOSDevice)
        #expect(label == "XCTAssertTrue(app.staticTexts[\"Total\"].waitForExistence(timeout: 5))\nXCTAssertEqual(app.staticTexts[\"Total\"].label, \"$12.50\")")
        let value = TestComposer.line(for: .init(query: #"app.switches["Extra shot"]"#, action: .assertAttribute(name: "value", expected: "1", timeout: 3)))
        #expect(value.hasSuffix(#"XCTAssertEqual(app.switches["Extra shot"].value, "1")"#))
    }

    @Test func sourceReusesTheVariableForAnAssertion() {
        var composer = TestComposer(name: "Cart", bundleID: "com.example", platform: .iOSDevice)
        composer.steps = [.init(query: #"app.buttons["Cart"]"#, action: .click),
                          .init(query: #"app.buttons["Cart"]"#, action: .assertAttribute(name: "label", expected: "Cart", timeout: 5))]
        let source = composer.source()
        #expect(source.contains(#"XCTAssertEqual(cartButton.label, "Cart")"#))
    }

    @Test func escapesTheExpectedText() {
        let line = TestComposer.line(for: .init(query: "app.staticTexts.firstMatch", action: .assertAttribute(name: "value", expected: #"say "hi""#, timeout: 5)))
        #expect(line.contains(#".value, "say \"hi\"")"#))
    }

    @Test func checksComeFromParams() {
        let checks = AutomationService.attributeChecks(["value": "1", "label": "Extra shot"])
        #expect(checks.map(\.name) == ["value", "label"])
        #expect(AutomationService.attributeChecks([:]).isEmpty)
    }

    @Test func toolDeclaresTheParams() {
        let names = Automation.tool(named: "wait-for")?.params.map(\.name) ?? []
        #expect(names.contains("value") && names.contains("label"))
    }
}

@Suite struct VariableNameTests {
    @Test func dropsClumsyTypeTails() {
        #expect(TestComposer.variableName(for: #"app.buttons["action-button-1"]"#) == "actionButton1")
        #expect(TestComposer.variableName(for: #"app.otherElements["drink-cold-brew"]"#) == "drinkColdBrew")
    }

    @Test func keepsTypeWhenTheKeyDoesNotSayIt() {
        #expect(TestComposer.variableName(for: #"app.buttons["drink-cold-brew"]"#) == "drinkColdBrewButton")
    }
}

@Suite struct RecordingToolTests {
    @Test func recordingLastIsDeclared() {
        #expect(Automation.tool(named: "recording-last") != nil)
    }

    @Test func cliTextUsesCommandNames() {
        #expect(Automation.cliText("Call recording_start first, or recording_last.") == "Call recording-start first, or recording-last.")
        #expect(Automation.cliText("Use resolve_query with device") == "Use resolve-query with device")
    }
}

@Suite struct AutomationHintTests {
    @Test func iPadTabsSuggestButtons() throws {
        let tree = makeTree([(nil, "window", nil, nil), (0, "button", nil, "Cart"), (0, "button", nil, "Menu")])
        let steps = try QueryResolver.parse(#"app.tabBars.buttons["Cart"]"#)
        let hint = AutomationHints.tabBarHint(steps: steps, tree: tree)
        #expect(hint?.contains(#"app.buttons["Cart"].firstMatch"#) == true)
    }

    @Test func noTabHintWhenATabBarExists() throws {
        let tree = makeTree([(nil, "window", nil, nil), (0, "tabBar", nil, nil), (1, "button", nil, "Cart")])
        let steps = try QueryResolver.parse(#"app.tabBars.buttons["Carts"]"#)
        #expect(AutomationHints.tabBarHint(steps: steps, tree: tree) == nil)
    }

    @Test func noTabHintForOtherQueries() throws {
        let tree = makeTree([(nil, "window", nil, nil), (0, "button", nil, "Cart")])
        #expect(AutomationHints.tabBarHint(steps: try QueryResolver.parse(#"app.buttons["Cart"]"#), tree: tree) == nil)
    }

    @Test func emptySearchSuggestsScrolling() {
        #expect(AutomationHints.noMatchHint(device: "iPad mini").contains("`scroll`"))
        #expect(AutomationHints.noMatchHint(device: nil).contains("scroll"))
    }

    @Test func windowDescriptions() {
        #expect(AutomationHints.windowDescription(title: "Cart", kind: "window") == "window “Cart”")
        #expect(AutomationHints.windowDescription(title: "", kind: "sheet") == "sheet (untitled)")
        #expect(AutomationHints.windowDescription(title: nil, kind: "window") == "window (untitled)")
    }

    @Test func staleRefFollowsTheElementOrFails() {
        let old = makeTree([(nil, "window", nil, nil), (0, "button", "add", nil), (0, "button", "remove", nil)])
        // The buttons swapped places and a new one appeared; "add" is still found by its identifier.
        let moved = makeTree([(nil, "window", nil, nil), (0, "button", "new", nil), (0, "button", "remove", nil), (0, "button", "add", nil)])
        #expect(AutomationHints.resolveStaleRef(id: 1, oldTree: old, newTree: moved) == .found(3))
        let gone = makeTree([(nil, "window", nil, nil), (0, "button", "remove", nil)])
        guard case .changed = AutomationHints.resolveStaleRef(id: 1, oldTree: old, newTree: gone) else {
            Issue.record("expected the ref to be reported as changed")
            return
        }
    }
}

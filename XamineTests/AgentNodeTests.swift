import Foundation
import Testing
@testable import Xamine

@Suite struct AgentNodeTests {
    /// The shape the agent sends for a small app: application ▸ window ▸ (navigation bar, scroll view ▸ buttons).
    let json = """
    {"type":"application","frame":[0,0,402,874],"label":"Settings","children":[
      {"type":"window","frame":[0,0,402,874],"children":[
        {"type":"navigationBar","frame":[0,62,402,54],"identifier":"Settings","children":[]},
        {"type":"scrollView","frame":[0,116,402,758],"children":[
          {"type":"button","frame":[16,130,370,44],"identifier":"com.apple.settings.wifi","label":"Wi-Fi","value":"Home","children":[]},
          {"type":"button","frame":[16,174,370,44],"label":"Bluetooth","children":[]}
        ]}
      ]}
    ]}
    """

    func tree() throws -> UITree {
        let root = try JSONDecoder().decode(AgentNode.self, from: Data(json.utf8))
        return root.makeTree(appName: "Settings", bundleID: "com.apple.Preferences")
    }

    @Test func convertsSnapshot() throws {
        let tree = try tree()
        #expect(tree.nodes.count == 6)
        #expect(tree.platform == .iOSDevice)
        #expect(tree.windowFrame == CGRect(x: 0, y: 0, width: 402, height: 874))
        #expect(tree.node(4).kind.queryName == "buttons")
        #expect(tree.node(4).value == "Home")
        #expect(tree.node(2).kind.typeName == "navigationBar")
    }

    @Test func generatesIOSQueries() throws {
        let tree = try tree()
        let builder = QueryBuilder(tree: tree, action: .interact)
        #expect(builder.identifierSnippet(for: tree.node(4))?.code == """
        let app = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        app.buttons["com.apple.settings.wifi"].tap()
        """)
        let plain = QueryBuilder(tree: tree, includeAppDeclaration: false)
        #expect(plain.containerSnippet(for: 5).code == """
        app.scrollViews.firstMatch
            .children(matching: .button).element(boundBy: 1)
        """)
        #expect(plain.breadcrumb(for: 5) == "App ▸ Window 1 ▸ Scroll View 1 ▸ Button 2")
    }
}

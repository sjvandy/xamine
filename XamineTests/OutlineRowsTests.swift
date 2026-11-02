import Foundation
import Testing
@testable import Xamine

@MainActor @Suite struct OutlineRowsTests {
    /// 0 application ▸ 1 window ▸ (2 group ▸ (3 button "Mail", 4 key "B"), 5 group ▸ 6 text "Other")
    let tree: UITree = {
        let json = """
        {"type":"application","frame":[0,0,402,874],"children":[
          {"type":"window","frame":[0,0,402,874],"children":[
            {"type":"group","frame":[0,0,402,400],"children":[
              {"type":"button","frame":[10,10,80,30],"label":"Mail","children":[]},
              {"type":"key","frame":[10,50,30,30],"label":"B","children":[]}]},
            {"type":"group","frame":[0,400,402,400],"children":[
              {"type":"staticText","frame":[10,410,80,30],"label":"Other","children":[]}]}]}]}
        """
        let root = try! JSONDecoder().decode(AgentNode.self, from: Data(json.utf8))
        return root.makeTree(appName: "T", bundleID: "t")
    }()

    private func ids(_ rows: [InspectorModel.Row]) -> [Int] { rows.map(\.id) }

    @Test func filterShowsMatchesAndTheirAncestors() {
        let rows = InspectorModel.rows(in: tree, query: "mail", expanded: [], collapsedInFilter: [], selected: nil)
        #expect(ids(rows) == [0, 1, 2, 3])
    }

    @Test func theSelectedElementStaysInTheFilteredList() {
        // Picking the "B" key in the screenshot while the filter says "mail": its row, and the way to it, still show.
        let rows = InspectorModel.rows(in: tree, query: "mail", expanded: [], collapsedInFilter: [], selected: 4)
        #expect(ids(rows) == [0, 1, 2, 3, 4])
        // Something in another branch brings its own ancestors.
        let other = InspectorModel.rows(in: tree, query: "mail", expanded: [], collapsedInFilter: [], selected: 6)
        #expect(ids(other) == [0, 1, 2, 3, 5, 6])
    }

    @Test func filterRowsCanBeCollapsedWithTheirTriangle() {
        let rows = InspectorModel.rows(in: tree, query: "mail", expanded: [], collapsedInFilter: [2], selected: nil)
        #expect(ids(rows) == [0, 1, 2])
    }

    @Test func withoutAFilterOnlyExpandedNodesShowTheirChildren() {
        #expect(ids(InspectorModel.rows(in: tree, query: "", expanded: [0, 1], collapsedInFilter: [], selected: 4)) == [0, 1, 2, 5])
        #expect(ids(InspectorModel.rows(in: tree, query: "  ", expanded: [0, 1, 2], collapsedInFilter: [], selected: nil)) == [0, 1, 2, 3, 4, 5])
    }

    @Test func triangleAndSelectionBehaveWhileFiltering() {
        let model = InspectorModel()
        model.searchText = "mail"
        #expect(model.isFiltering)
        #expect(model.isExpanded(2))
        model.toggleExpanded(2)
        #expect(!model.isExpanded(2))
        model.toggleExpanded(2)
        #expect(model.isExpanded(2))
        // Changing the filter starts over.
        model.toggleExpanded(2)
        model.searchText = "other"
        #expect(model.isExpanded(2))
        // Clearing it goes back to the normal expansion state.
        model.searchText = ""
        #expect(!model.isFiltering)
        #expect(!model.isExpanded(2))
        model.toggleExpanded(2)
        #expect(model.isExpanded(2))
    }
}

import SwiftUI
import TipKit

/// What the person has done, donated as they do it. Each tip appears only while its event has never happened,
/// after the inspector has been opened enough times that they've had a chance to find the feature themselves.
enum TipEvents {
    static let copiedBundleID = Tips.Event(id: "copiedBundleID")
    static let copiedQuery = Tips.Event(id: "copiedQuery")
    static let clickedScreenshot = Tips.Event(id: "clickedScreenshot")
    static let usedContextMenu = Tips.Event(id: "usedContextMenu")
    static let usedFilter = Tips.Event(id: "usedFilter")
    static let rescanned = Tips.Event(id: "rescanned")
    static let pickedWindow = Tips.Event(id: "pickedWindow")

    private static let opensKey = "inspectorOpenCount"

    @MainActor static func noteInspectorOpened() {
        let opens = UserDefaults.standard.integer(forKey: opensKey) + 1
        UserDefaults.standard.set(opens, forKey: opensKey)
        TipOrder.opens = opens
    }

    /// At most one tip a day, so people learn the app gradually. Debug builds show them as soon as they're eligible.
    @MainActor static func configure() {
        #if DEBUG
        let frequency = Tips.ConfigurationOption.DisplayFrequency.immediate
        #else
        let frequency = Tips.ConfigurationOption.DisplayFrequency.daily
        #endif
        try? Tips.configure([.displayFrequency(frequency)])
        TipOrder.opens = UserDefaults.standard.integer(forKey: opensKey)
    }
}

/// Values the tips' rules read.
enum TipOrder {
    /// How many times the inspector has been opened.
    @Parameter static var opens: Int = 0
}

// Thresholds on `opens` are staggered so tips arrive one at a time, not all in the first session.

struct CopyBundleIDTip: Tip {
    var title: Text { Text("Copy the Bundle ID") }
    var message: Text? { Text("Click the app's name in the toolbar to copy its bundle identifier.") }
    var image: Image? { Image(systemName: "doc.on.doc") }

    var rules: [Rule] {
        #Rule(TipOrder.$opens) { $0 >= 2 }
        #Rule(TipEvents.copiedBundleID) { $0.donations.count == 0 }
    }
}

struct CopyQueryTip: Tip {
    var title: Text { Text("Click a Query to Copy It") }
    var message: Text? { Text("Each card is a ready-to-paste XCUITest query for the selected element.") }
    var image: Image? { Image(systemName: "curlybraces") }

    var rules: [Rule] {
        #Rule(TipOrder.$opens) { $0 >= 3 }
        #Rule(TipEvents.copiedQuery) { $0.donations.count == 0 }
    }
}

struct ClickScreenshotTip: Tip {
    var title: Text { Text("Click the Screenshot") }
    var message: Text? { Text("Click any element in the screenshot to select it. Use ↑ and ↓ to pick a layer.") }
    var image: Image? { Image(systemName: "cursorarrow.click") }

    var rules: [Rule] {
        #Rule(TipOrder.$opens) { $0 >= 3 }
        #Rule(TipEvents.clickedScreenshot) { $0.donations.count == 0 }
    }
}

struct ContextMenuTip: Tip {
    var title: Text { Text("Right-Click a Row") }
    var message: Text? { Text("Copy an identifier, label or query, the full path from the window, or expand everything below it.") }
    var image: Image? { Image(systemName: "contextualmenu.and.cursorarrow") }

    var rules: [Rule] {
        #Rule(TipOrder.$opens) { $0 >= 4 }
        #Rule(TipEvents.usedContextMenu) { $0.donations.count == 0 }
    }
}

struct FilterElementsTip: Tip {
    var title: Text { Text("Filter the Hierarchy") }
    var message: Text? { Text("Type in the toolbar's search field to find elements by type, label or identifier.") }
    var image: Image? { Image(systemName: "magnifyingglass") }

    var rules: [Rule] {
        #Rule(TipOrder.$opens) { $0 >= 5 }
        #Rule(TipEvents.usedFilter) { $0.donations.count == 0 }
    }
}

struct RescanTip: Tip {
    var title: Text { Text("Re-scan After the UI Changes") }
    var message: Text? { Text("Press ⌘R to capture the window and read its hierarchy again.") }
    var image: Image? { Image(systemName: "arrow.clockwise") }

    var rules: [Rule] {
        #Rule(TipOrder.$opens) { $0 >= 6 }
        #Rule(TipEvents.rescanned) { $0.donations.count == 0 }
    }
}

struct PickWindowTip: Tip {
    var title: Text { Text("Pick Another Window") }
    var message: Text? { Text("Press ⌘⇧X from any app to pick a window to inspect, without coming back here first.") }
    var image: Image? { Image(systemName: "viewfinder") }

    var rules: [Rule] {
        #Rule(TipOrder.$opens) { $0 >= 7 }
        #Rule(TipEvents.pickedWindow) { $0.donations.count == 0 }
    }
}

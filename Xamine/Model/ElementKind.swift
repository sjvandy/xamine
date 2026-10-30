import SwiftUI

/// The XCUITest element type an accessibility role maps to, plus how it is drawn in the hierarchy.
struct ElementKind: Hashable, Sendable {
    /// Name used for `XCUIElement.ElementType`, e.g. `button` → `.button`.
    let typeName: String
    /// Query property on `XCUIElementTypeQueryProvider`, e.g. `buttons`.
    let queryName: String
    /// Human readable name shown in the outline, e.g. "Button".
    let displayName: String
    let symbol: String
    let category: Category

    enum Category: Sendable {
        case control, text, input, container, collection, media, link, window, other

        var tint: Color {
            switch self {
            case .control: .blue
            case .text: .secondary
            case .input: .teal
            case .container: .gray
            case .collection: .indigo
            case .media: .pink
            case .link: .purple
            case .window: .orange
            case .other: .gray
            }
        }
    }

    static let other = ElementKind(typeName: "other", queryName: "otherElements", displayName: "Other", symbol: "questionmark.square.dashed", category: .other)

    /// Maps a raw `AXRole` (and optional `AXSubrole`) to its XCUITest element kind.
    static func forRole(_ role: String, subrole: String? = nil) -> ElementKind {
        if let subrole, let kind = bySubrole[subrole] { return kind }
        return byRole[role] ?? .other
    }

    /// Maps an `XCUIElement.ElementType` name (as reported by an XCUITest snapshot) to its kind.
    static func forTypeName(_ typeName: String) -> ElementKind {
        all.first { $0.typeName == typeName } ?? .other
    }

    private static func k(_ type: String, _ query: String, _ display: String, _ symbol: String, _ category: Category) -> ElementKind {
        ElementKind(typeName: type, queryName: query, displayName: display, symbol: symbol, category: category)
    }

    static let application = k("application", "applications", "Application", "app.dashed", .window)
    static let window = k("window", "windows", "Window", "macwindow", .window)
    static let group = k("group", "groups", "Group", "square.dashed", .container)
    static let button = k("button", "buttons", "Button", "button.horizontal.top.press", .control)
    static let link = k("link", "links", "Link", "link", .link)

    private static let all: [ElementKind] = [
        application, window, group, button, link,
        k("sheet", "sheets", "Sheet", "rectangle.topthird.inset.filled", .window),
        k("dialog", "dialogs", "Dialog", "exclamationmark.bubble", .window),
        k("drawer", "drawers", "Drawer", "sidebar.left", .window),
        k("staticText", "staticTexts", "Text", "textformat", .text),
        k("textField", "textFields", "Text Field", "character.cursor.ibeam", .input),
        k("secureTextField", "secureTextFields", "Secure Field", "lock.rectangle", .input),
        k("searchField", "searchFields", "Search Field", "magnifyingglass", .input),
        k("textView", "textViews", "Text View", "text.alignleft", .input),
        k("checkBox", "checkBoxes", "Checkbox", "checkmark.square", .control),
        k("radioButton", "radioButtons", "Radio Button", "largecircle.fill.circle", .control),
        k("radioGroup", "radioGroups", "Radio Group", "circle.grid.2x1", .container),
        k("popUpButton", "popUpButtons", "Pop-Up Button", "chevron.up.chevron.down", .control),
        k("menuButton", "menuButtons", "Menu Button", "filemenu.and.selection", .control),
        k("comboBox", "comboBoxes", "Combo Box", "list.bullet.rectangle", .input),
        k("disclosureTriangle", "disclosureTriangles", "Disclosure", "chevron.right.square", .control),
        k("slider", "sliders", "Slider", "slider.horizontal.3", .control),
        k("stepper", "steppers", "Stepper", "plusminus", .control),
        k("switch", "switches", "Switch", "switch.2", .control),
        k("toggle", "toggles", "Toggle", "switch.2", .control),
        k("segmentedControl", "segmentedControls", "Segmented", "rectangle.split.3x1", .control),
        k("progressIndicator", "progressIndicators", "Progress", "progress.indicator", .media),
        k("activityIndicator", "activityIndicators", "Activity", "progress.indicator", .media),
        k("levelIndicator", "levelIndicators", "Level", "gauge.with.dots.needle.33percent", .media),
        k("image", "images", "Image", "photo", .media),
        k("icon", "icons", "Icon", "app", .media),
        k("scrollView", "scrollViews", "Scroll View", "scroll", .container),
        k("scrollBar", "scrollBars", "Scroll Bar", "arrow.up.and.down.square", .control),
        k("splitGroup", "splitGroups", "Split Group", "rectangle.split.2x1", .container),
        k("splitter", "splitters", "Splitter", "line.3.horizontal", .other),
        k("tabGroup", "tabGroups", "Tab Group", "rectangle.stack", .container),
        k("tab", "tabs", "Tab", "rectangle.topthird.inset.filled", .control),
        k("tabBar", "tabBars", "Tab Bar", "dock.rectangle", .container),
        k("toolbar", "toolbars", "Toolbar", "menubar.rectangle", .container),
        k("toolbarButton", "toolbarButtons", "Toolbar Button", "button.horizontal.top.press", .control),
        k("navigationBar", "navigationBars", "Navigation Bar", "menubar.rectangle", .container),
        k("statusBar", "statusBars", "Status Bar", "menubar.dock.rectangle", .container),
        k("table", "tables", "Table", "tablecells", .collection),
        k("tableRow", "tableRows", "Row", "list.bullet", .collection),
        k("tableColumn", "tableColumns", "Column", "rectangle.split.3x1", .collection),
        k("outline", "outlines", "Outline", "list.bullet.indent", .collection),
        k("outlineRow", "outlineRows", "Outline Row", "list.bullet.indent", .collection),
        k("browser", "browsers", "Browser", "rectangle.split.3x1", .collection),
        k("collectionView", "collectionViews", "Collection", "square.grid.2x2", .collection),
        k("cell", "cells", "Cell", "rectangle", .collection),
        k("menuBar", "menuBars", "Menu Bar", "menubar.rectangle", .container),
        k("menuBarItem", "menuBarItems", "Menu Bar Item", "filemenu.and.selection", .control),
        k("menu", "menus", "Menu", "list.bullet.rectangle.portrait", .container),
        k("menuItem", "menuItems", "Menu Item", "filemenu.and.selection", .control),
        k("webView", "webViews", "Web View", "globe", .container),
        k("map", "maps", "Map", "map", .media),
        k("valueIndicator", "valueIndicators", "Value", "number", .text),
        k("incrementArrow", "incrementArrows", "Increment", "arrowtriangle.up", .control),
        k("decrementArrow", "decrementArrows", "Decrement", "arrowtriangle.down", .control),
        k("colorWell", "colorWells", "Color Well", "paintpalette", .control),
        k("helpTag", "helpTags", "Help Tag", "questionmark.bubble", .text),
        k("matte", "mattes", "Matte", "rectangle.dashed", .other),
        k("dockItem", "dockItems", "Dock Item", "dock.rectangle", .control),
        k("ruler", "rulers", "Ruler", "ruler", .other),
        k("rulerMarker", "rulerMarkers", "Ruler Marker", "ruler", .other),
        k("grid", "grids", "Grid", "square.grid.3x3", .collection),
        k("layoutArea", "layoutAreas", "Layout Area", "square.dashed", .container),
        k("layoutItem", "layoutItems", "Layout Item", "square", .container),
        k("handle", "handles", "Handle", "line.3.horizontal", .control),
        k("picker", "pickers", "Picker", "chevron.up.chevron.down", .control),
        k("pickerWheel", "pickerWheels", "Picker Wheel", "dial.low", .control),
        k("pageIndicator", "pageIndicators", "Page Indicator", "ellipsis", .control),
        k("keyboard", "keyboards", "Keyboard", "keyboard", .container),
        k("key", "keys", "Key", "keyboard", .control),
        k("alert", "alerts", "Alert", "exclamationmark.triangle", .window),
        k("datePicker", "datePickers", "Date Picker", "calendar", .control),
        other,
    ]

    private static func named(_ type: String) -> ElementKind { all.first { $0.typeName == type } ?? .other }

    private static let byRole: [String: ElementKind] = [
        "AXApplication": application,
        "AXWindow": window,
        "AXSheet": named("sheet"),
        "AXDrawer": named("drawer"),
        "AXGroup": group,
        "AXButton": button,
        "AXLink": link,
        "AXStaticText": named("staticText"),
        "AXTextField": named("textField"),
        "AXTextArea": named("textView"),
        "AXCheckBox": named("checkBox"),
        "AXRadioButton": named("radioButton"),
        "AXRadioGroup": named("radioGroup"),
        "AXPopUpButton": named("popUpButton"),
        "AXMenuButton": named("menuButton"),
        "AXComboBox": named("comboBox"),
        "AXDisclosureTriangle": named("disclosureTriangle"),
        "AXSlider": named("slider"),
        "AXIncrementor": named("stepper"),
        "AXProgressIndicator": named("progressIndicator"),
        "AXBusyIndicator": named("activityIndicator"),
        "AXLevelIndicator": named("levelIndicator"),
        "AXRelevanceIndicator": named("levelIndicator"),
        "AXImage": named("image"),
        "AXScrollArea": named("scrollView"),
        "AXScrollBar": named("scrollBar"),
        "AXSplitGroup": named("splitGroup"),
        "AXSplitter": named("splitter"),
        "AXTabGroup": named("tabGroup"),
        "AXToolbar": named("toolbar"),
        "AXTable": named("table"),
        "AXRow": named("tableRow"),
        "AXColumn": named("tableColumn"),
        "AXOutline": named("outline"),
        "AXBrowser": named("browser"),
        "AXList": named("collectionView"),
        "AXCell": named("cell"),
        "AXMenuBar": named("menuBar"),
        "AXMenuBarItem": named("menuBarItem"),
        "AXMenu": named("menu"),
        "AXMenuItem": named("menuItem"),
        "AXWebArea": named("webView"),
        "AXValueIndicator": named("valueIndicator"),
        "AXColorWell": named("colorWell"),
        "AXHelpTag": named("helpTag"),
        "AXMatte": named("matte"),
        "AXDockItem": named("dockItem"),
        "AXRuler": named("ruler"),
        "AXRulerMarker": named("rulerMarker"),
        "AXGrid": named("grid"),
        "AXLayoutArea": named("layoutArea"),
        "AXLayoutItem": named("layoutItem"),
        "AXHandle": named("handle"),
        "AXDateField": named("datePicker"),
        "AXSegmentedControl": named("segmentedControl"),
    ]

    private static let bySubrole: [String: ElementKind] = [
        "AXSecureTextField": named("secureTextField"),
        "AXSearchField": named("searchField"),
        "AXSwitch": named("switch"),
        "AXToggle": named("toggle"),
        "AXTabButton": named("tab"),
        "AXOutlineRow": named("outlineRow"),
        "AXIncrementArrow": named("incrementArrow"),
        "AXDecrementArrow": named("decrementArrow"),
        "AXDialog": named("dialog"),
        "AXSystemDialog": named("dialog"),
        "AXTextLink": link,
    ]
}

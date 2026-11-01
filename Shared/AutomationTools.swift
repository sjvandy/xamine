import Foundation

/// The automation API that Xamine serves to AI agents and scripts, shared by the app (which implements it)
/// and the `xamine` helper (which exposes it as an MCP server and a command-line tool).
///
/// Wire format: newline-delimited JSON over a Unix socket. Requests are `{"id": 1, "method": "click", "params": {…}}`;
/// replies are `{"id": 1, "result": {…}}` or `{"id": 1, "error": {"code": "…", "message": "…"}}`. A result may carry
/// `text` (a readable summary, shown to agents first) and `png` (a base64 screenshot).
enum Automation {
    /// Only the current user can connect (the socket is created 0600 inside their Application Support).
    static var socketPath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "Xamine/agent.sock").path
    }

    static let appBundleID = "com.sjvandy.Xamine"

    struct Param: Sendable {
        enum Kind: String, Sendable { case string, integer, number, boolean }
        let name: String
        let kind: Kind
        let description: String
        var required = false
    }

    struct Tool: Sendable {
        let name: String
        let description: String
        let params: [Param]

        /// Tool names use underscores; the CLI also accepts dashes (`find-elements`).
        var cliName: String { name.replacingOccurrences(of: "_", with: "-") }
    }

    private static let app = Param(name: "app", kind: .string,
        description: "Bundle ID or name of the app (e.g. com.apple.tips). Defaults to the app used last.")
    private static let element = Param(name: "element", kind: .string,
        description: "Element ref from the latest snapshot or find_elements, e.g. e12.")
    private static let query = Param(name: "query", kind: .string,
        description: #"XCUITest query to resolve against the live UI instead of a ref, e.g. app.buttons["Save"]."#)

    static let tools: [Tool] = [
        Tool(name: "status", description: "Xamine's version, whether it has the Accessibility and Screen Recording permissions it needs, and the frontmost app.", params: []),
        Tool(name: "list_apps", description: "Running apps that have windows, with bundle IDs and window titles.", params: []),
        Tool(name: "launch_app", description: "Launch (or bring forward) a macOS app and wait for its window. Makes it the current app for later calls.", params: [
            Param(name: "app", kind: .string, description: "Bundle ID or name of the app, e.g. com.apple.tips or Tips.", required: true),
            Param(name: "wait", kind: .boolean, description: "Wait for a window to appear (default true)."),
        ]),
        Tool(name: "snapshot", description: "Scan the app's front window and return its accessibility hierarchy as an indented outline. Each line starts with an element ref (e12) to pass to other tools. Refs belong to this snapshot; take a new one after the UI changes.", params: [
            app,
            Param(name: "window", kind: .string, description: "Part of the title of the window to scan, if not the front one."),
            Param(name: "max_depth", kind: .integer, description: "Only include elements up to this depth."),
            Param(name: "frames", kind: .boolean, description: "Include each element's frame in screen points."),
            Param(name: "interactive_only", kind: .boolean, description: "Only list elements that have an identifier, title, label or value, plus controls."),
        ]),
        Tool(name: "find_elements", description: "Rescan the app and list elements whose identifier, title, label, value or placeholder contains the text, with the best XCUITest query for each.", params: [
            app,
            Param(name: "text", kind: .string, description: "Case-insensitive text to look for."),
            Param(name: "kind", kind: .string, description: "Element type, e.g. button, staticText, searchField, outlineRow."),
            Param(name: "identifier", kind: .string, description: "Exact accessibility identifier."),
            Param(name: "limit", kind: .integer, description: "Maximum number of results (default 25)."),
        ]),
        Tool(name: "screenshot", description: "PNG screenshot of the app's front window, or just one element.", params: [app, element]),
        Tool(name: "get_queries", description: "Every XCUITest query Xamine can generate for an element: by identifier, from an anchor, from a unique container, and by hierarchy (text-free).", params: [app, element, query]),
        Tool(name: "click", description: "Click an element (AXPress when the element supports it, otherwise a mouse click at its center). Returns the matching XCUITest line and records it while recording.", params: [
            app, element, query,
            Param(name: "method", kind: .string, description: "auto (default), press (accessibility action only) or mouse (synthesized click)."),
        ]),
        Tool(name: "type_text", description: "Focus an element (if given) and type text into it, like XCUIElement.typeText.", params: [
            app, element, query,
            Param(name: "text", kind: .string, description: "Text to type.", required: true),
            Param(name: "clear", kind: .boolean, description: "Select all and delete the existing text first."),
        ]),
        Tool(name: "press_key", description: "Press a key in the app, like XCUIElement.typeKey.", params: [
            app,
            Param(name: "key", kind: .string, description: "return, escape, tab, delete, space, up, down, left, right, home, end, pageUp, pageDown, or a single character.", required: true),
            Param(name: "modifiers", kind: .string, description: "Comma-separated: command, shift, option, control."),
        ]),
        Tool(name: "scroll", description: "Scroll inside an element (or the window).", params: [
            app, element, query,
            Param(name: "direction", kind: .string, description: "up, down, left or right (default down)."),
            Param(name: "amount", kind: .integer, description: "Lines to scroll (default 5)."),
        ]),
        Tool(name: "wait_for", description: "Wait until an XCUITest query (or any element containing text) exists, or is gone. Records an XCTAssert while recording.", params: [
            app, query,
            Param(name: "text", kind: .string, description: "Text to wait for instead of a query."),
            Param(name: "timeout", kind: .number, description: "Seconds to wait (default 5)."),
            Param(name: "gone", kind: .boolean, description: "Wait for it to disappear instead."),
        ]),
        Tool(name: "resolve_query", description: "Evaluate an XCUITest query against the live UI. Reports how many elements match and, when none do, at which step the query stopped matching, the closest elements that exist now, and a text-free alternative query. Use it to find out why a UI test can't find an element.", params: [
            app,
            Param(name: "query", kind: .string, description: #"The query, e.g. app.windows["Shopping Cart"] or app.buttons.matching(identifier: "save").firstMatch."#, required: true),
        ]),
        Tool(name: "recording_start", description: "Start recording: every click, type_text, press_key and wait_for from now on is added to an XCUITest.", params: [
            app,
            Param(name: "name", kind: .string, description: "Name for the test, e.g. OrderColdBrew."),
        ]),
        Tool(name: "recording_stop", description: "Stop recording and return the recorded steps as a complete XCTestCase source file.", params: []),
    ]

    static func tool(named name: String) -> Tool? {
        tools.first { $0.name == name || $0.cliName == name }
    }
}

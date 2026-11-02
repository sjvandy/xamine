import Network
import XCTest

/// Runs for as long as Xamine needs it: serves the UI hierarchy and screenshots of any app on this device over HTTP.
/// Xamine checks in every few seconds; if it goes quiet for `idleTimeout` (it quit, was force quit or crashed), the
/// agent ends its test, which ends the device's "Automation Running" session.
///
/// Endpoints (all GET):
/// - `/status` → `{"ok": true, "device": "...", "port": 8765}`
/// - `/tree?bundleId=com.example` → the app's element tree as JSON (see `encode`)
/// - `/foreground?candidates=a,b,c` → `{"bundleId": "..."}`, the first candidate running in the foreground,
///   or SpringBoard when none is
/// - `/screenshot` → PNG of the whole screen
/// - `/shutdown` → ends the test
///
/// Automation (for AI agents driving the device through Xamine). `steps` is a URL-encoded JSON array describing an
/// XCUITest query, which is rebuilt from real `XCUIElementQuery` calls (see `Query`):
/// - `/launch?bundleId=&mode=activate|launch|terminate`
/// - `/resolve?bundleId=&steps=` → match count after each step, plus the first matches
/// - `/tap?bundleId=&steps=&gesture=tap|doubleTap|longPress`, or `x`/`y` in points instead of `steps`
/// - `/type?bundleId=&text=[&steps=]` → taps the element first if given, then types
/// - `/swipe?bundleId=&direction=up|down|left|right[&steps=]`
/// - `/key?bundleId=&name=home|volumeUp|volumeDown|return|delete|tab|space|<character>`
/// - `/wait?bundleId=&steps=&timeout=&gone=0|1`
final class XamineAgentTests: XCTestCase {
    static let port: NWEndpoint.Port = 8765
    /// How long to keep running without hearing from Xamine, which sends `/status` every 10 seconds.
    static let idleTimeout: TimeInterval = 30

    private var listener: NWListener?
    private var shouldStop = false
    /// When the last request started or finished. Only touched on the main thread.
    private var lastContact = Date()
    /// Failures from XCUITest calls made for a request. They're reported back to Xamine rather than recorded against
    /// this test, which would end it (and the agent) at the next `/shutdown`.
    private var issues: [String] = []

    override func record(_ issue: XCTIssue) {
        issues.append(issue.compactDescription)
    }

    func testRunAgent() throws {
        continueAfterFailure = true
        let listener = try NWListener(using: .tcp, on: Self.port)
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.stateUpdateHandler = { state in
            if case .ready = state { print("XAMINE_AGENT_READY port=\(Self.port)") }
            if case .failed(let error) = state { print("XAMINE_AGENT_FAILED \(error)") }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener

        // XCUITest calls must run on the main thread, so keep the main run loop serving requests.
        while !shouldStop {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            if Date().timeIntervalSince(lastContact) > Self.idleTimeout {
                print("XAMINE_AGENT_IDLE no request from Xamine for \(Int(Self.idleTimeout))s; stopping")
                shouldStop = true
            }
        }
        listener.cancel()
    }

    // MARK: - HTTP

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let target = head.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                DispatchQueue.main.async {
                    // Counted at both ends, so a long request (a wait, a big snapshot) doesn't look like silence.
                    self.lastContact = Date()
                    let response = self.respond(to: target)
                    self.lastContact = Date()
                    self.send(response, on: connection)
                }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffer: buffer)
            }
        }
    }

    private struct Response {
        var status = "200 OK"
        var contentType = "application/json"
        var body: Data
    }

    private func send(_ response: Response, on connection: NWConnection) {
        var data = Data("HTTP/1.1 \(response.status)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n".utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func json(_ object: Any, status: String = "200 OK") -> Response {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return Response(status: status, body: body)
    }

    // MARK: - Routes

    private func respond(to target: String) -> Response {
        let components = URLComponents(string: target)
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        switch components?.path ?? target {
        case "/status":
            return json(["ok": true, "device": UIDevice.current.name, "system": UIDevice.current.systemVersion, "port": Int(Self.port.rawValue)])

        case "/tree":
            let bundleID = query["bundleId"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.apple.springboard"
            let app = XCUIApplication(bundleIdentifier: bundleID)
            do {
                let snapshot = try app.snapshot()
                var root = encode(snapshot)
                Self.rotatePortraitWindows(&root, appFrame: snapshot.frame)
                return json(["bundleId": bundleID, "root": root])
            } catch {
                return json(["error": "Couldn't read \(bundleID): \(error.localizedDescription)"], status: "500 Internal Server Error")
            }

        case "/foreground":
            let candidates = (query["candidates"] ?? "").split(separator: ",").map(String.init)
            // Some apps report .runningForeground without being on screen (CarPlay does on the Home Screen), so a
            // candidate also needs a window to count.
            let foreground = candidates.first {
                let app = XCUIApplication(bundleIdentifier: $0)
                return app.state == .runningForeground && app.windows.firstMatch.exists
            }
            return json(["bundleId": foreground ?? "com.apple.springboard"])

        case "/screenshot":
            return Response(contentType: "image/png", body: Self.uprightPNG(XCUIScreen.main.screenshot().image))

        case "/shutdown":
            shouldStop = true
            return json(["ok": true])

        case "/launch", "/resolve", "/tap", "/type", "/swipe", "/key", "/wait":
            issues = []
            let app = XCUIApplication(bundleIdentifier: query["bundleId"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.apple.springboard")
            do {
                var result = try automate(components?.path ?? target, app: app, query: query)
                if !issues.isEmpty {
                    return json(["error": issues.joined(separator: "\n")], status: "500 Internal Server Error")
                }
                result["ok"] = true
                return json(result)
            } catch {
                let message = ([error.localizedDescription] + issues).joined(separator: "\n")
                return json(["error": message], status: "500 Internal Server Error")
            }

        default:
            return json(["error": "Unknown path \(target)"], status: "404 Not Found")
        }
    }

    // MARK: - Automation

    private struct AgentFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func automate(_ path: String, app: XCUIApplication, query: [String: String]) throws -> [String: Any] {
        let steps = try query["steps"].map(Query.parse)
        switch path {
        case "/launch":
            switch query["mode"] ?? "activate" {
            case "launch": app.launch()
            case "terminate": app.terminate()
            default: app.activate()
            }
            return ["state": Int(app.state.rawValue)]

        case "/resolve":
            guard let steps else { throw AgentFailure(message: "resolve needs steps.") }
            let (counts, result) = Query.evaluate(steps, from: app)
            let elements = Query.elements(result, limit: 10)
            return ["counts": counts, "matches": elements.compactMap(Self.describe)]

        case "/tap":
            if let x = query["x"].flatMap(Double.init), let y = query["y"].flatMap(Double.init) {
                let point = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
                switch query["gesture"] {
                case "doubleTap": point.doubleTap()
                case "longPress": point.press(forDuration: 1)
                default: point.tap()
                }
                return [:]
            }
            let element = try target(steps, in: app)
            switch query["gesture"] {
            case "doubleTap": element.doubleTap()
            case "longPress": element.press(forDuration: 1)
            default: element.tap()
            }
            return [:]

        case "/type":
            let text = query["text"] ?? ""
            if steps != nil {
                let element = try target(steps, in: app)
                // typeText needs keyboard focus, which a tap gives a field.
                if (element.value(forKey: "hasKeyboardFocus") as? Bool) != true { element.tap() }
                element.typeText(text)
            } else {
                app.typeText(text)
            }
            return [:]

        case "/swipe":
            let element: XCUIElement = steps == nil ? app : try target(steps, in: app)
            switch query["direction"] ?? "up" {
            case "down": element.swipeDown()
            case "left": element.swipeLeft()
            case "right": element.swipeRight()
            default: element.swipeUp()
            }
            return [:]

        case "/key":
            switch query["name"] ?? "" {
            case "home": XCUIDevice.shared.press(.home)
            #if !targetEnvironment(simulator)
            case "volumeUp": XCUIDevice.shared.press(.volumeUp)
            case "volumeDown": XCUIDevice.shared.press(.volumeDown)
            #endif
            case "return": app.typeText("\n")
            case "delete": app.typeText(XCUIKeyboardKey.delete.rawValue)
            case "tab": app.typeText("\t")
            case "space": app.typeText(" ")
            case let character where character.count == 1: app.typeText(character)
            case let other: throw AgentFailure(message: "Unknown key \(other).")
            }
            return [:]

        case "/wait":
            guard let steps else { throw AgentFailure(message: "wait needs steps.") }
            let timeout = query["timeout"].flatMap(Double.init) ?? 5
            let element = Query.element(Query.evaluate(steps, from: app).result)
            let met = query["gone"] == "1" ? element.waitForNonExistence(timeout: timeout) : element.waitForExistence(timeout: timeout)
            return ["met": met]

        default:
            throw AgentFailure(message: "Unknown path \(path)")
        }
    }

    /// The element `steps` finds, waiting briefly for it as XCUITest does before interacting.
    private func target(_ steps: [Query.Step]?, in app: XCUIApplication) throws -> XCUIElement {
        guard let steps else { throw AgentFailure(message: "Pass steps (a query) or x and y.") }
        let element = Query.element(Query.evaluate(steps, from: app).result)
        guard element.waitForExistence(timeout: 5) else { throw AgentFailure(message: "No element matches the query.") }
        return element
    }

    /// Type, identifier, label, value and frame of an element, read from a snapshot so nothing fails if it's gone.
    private static func describe(_ element: XCUIElement) -> [String: Any]? {
        guard let snapshot = try? element.snapshot() else { return nil }
        var node: [String: Any] = [
            "type": typeName(snapshot.elementType),
            "frame": [snapshot.frame.minX, snapshot.frame.minY, snapshot.frame.width, snapshot.frame.height],
        ]
        if !snapshot.identifier.isEmpty { node["identifier"] = snapshot.identifier }
        if !snapshot.label.isEmpty { node["label"] = snapshot.label }
        if let value = snapshot.value { node["value"] = String(describing: value) }
        return node
    }

    // MARK: - Screenshot

    /// The screenshot as PNG in interface orientation. In landscape the screenshot holds the screen's portrait pixels
    /// plus an orientation flag, which `pngRepresentation` drops, so redraw it upright to match the snapshot's frames.
    private static func uprightPNG(_ image: UIImage) -> Data {
        guard image.imageOrientation != .up else { return image.pngData() ?? Data() }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).pngData { _ in image.draw(at: .zero) }
    }

    // MARK: - Orientation

    /// In landscape, SpringBoard's windows report frames in the screen's portrait space while the app itself reports
    /// landscape. Rotates those windows into the app's space so they line up with the upright screenshot.
    private static func rotatePortraitWindows(_ root: inout [String: Any], appFrame: CGRect) {
        guard appFrame.width > appFrame.height, var windows = root["children"] as? [[String: Any]] else { return }
        let portrait = CGSize(width: appFrame.height, height: appFrame.width)
        let isPortrait: ([String: Any]) -> Bool = { frame(of: $0)?.size == portrait }
        guard windows.contains(where: isPortrait) else { return }
        // The screenshot's orientation says which way the screen is turned; the device's own orientation can be face up.
        let clockwise = XCUIScreen.main.screenshot().image.imageOrientation == .right
        for index in windows.indices where isPortrait(windows[index]) {
            rotate(&windows[index], portrait: portrait, clockwise: clockwise)
        }
        root["children"] = windows
    }

    private static func rotate(_ node: inout [String: Any], portrait: CGSize, clockwise: Bool) {
        if let rect = frame(of: node) {
            let rotated = clockwise
                ? CGRect(x: portrait.height - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
                : CGRect(x: rect.minY, y: portrait.width - rect.maxX, width: rect.height, height: rect.width)
            node["frame"] = [rotated.minX, rotated.minY, rotated.width, rotated.height]
        }
        if var children = node["children"] as? [[String: Any]] {
            for index in children.indices { rotate(&children[index], portrait: portrait, clockwise: clockwise) }
            node["children"] = children
        }
    }

    private static func frame(of node: [String: Any]) -> CGRect? {
        guard let values = node["frame"] as? [CGFloat], values.count == 4 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    // MARK: - Snapshot encoding

    private func encode(_ snapshot: XCUIElementSnapshot) -> [String: Any] {
        var node: [String: Any] = [
            "type": Self.typeName(snapshot.elementType),
            "frame": [snapshot.frame.minX, snapshot.frame.minY, snapshot.frame.width, snapshot.frame.height],
            "enabled": snapshot.isEnabled,
            "selected": snapshot.isSelected,
            "children": snapshot.children.map(encode),
        ]
        if !snapshot.identifier.isEmpty { node["identifier"] = snapshot.identifier }
        if !snapshot.label.isEmpty { node["label"] = snapshot.label }
        if !snapshot.title.isEmpty { node["title"] = snapshot.title }
        if let value = snapshot.value { node["value"] = String(describing: value) }
        if let placeholder = snapshot.placeholderValue, !placeholder.isEmpty { node["placeholder"] = placeholder }
        return node
    }

    /// The Swift case name of an element type, e.g. `.button` → "button", matching what Xamine generates.
    static func typeName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .any: return "any"
        case .other: return "other"
        case .application: return "application"
        case .group: return "group"
        case .window: return "window"
        case .sheet: return "sheet"
        case .drawer: return "drawer"
        case .alert: return "alert"
        case .dialog: return "dialog"
        case .button: return "button"
        case .radioButton: return "radioButton"
        case .radioGroup: return "radioGroup"
        case .checkBox: return "checkBox"
        case .disclosureTriangle: return "disclosureTriangle"
        case .popUpButton: return "popUpButton"
        case .comboBox: return "comboBox"
        case .menuButton: return "menuButton"
        case .toolbarButton: return "toolbarButton"
        case .popover: return "popover"
        case .keyboard: return "keyboard"
        case .key: return "key"
        case .navigationBar: return "navigationBar"
        case .tabBar: return "tabBar"
        case .tabGroup: return "tabGroup"
        case .toolbar: return "toolbar"
        case .statusBar: return "statusBar"
        case .table: return "table"
        case .tableRow: return "tableRow"
        case .tableColumn: return "tableColumn"
        case .outline: return "outline"
        case .outlineRow: return "outlineRow"
        case .browser: return "browser"
        case .collectionView: return "collectionView"
        case .slider: return "slider"
        case .pageIndicator: return "pageIndicator"
        case .progressIndicator: return "progressIndicator"
        case .activityIndicator: return "activityIndicator"
        case .segmentedControl: return "segmentedControl"
        case .picker: return "picker"
        case .pickerWheel: return "pickerWheel"
        case .switch: return "switch"
        case .toggle: return "toggle"
        case .link: return "link"
        case .image: return "image"
        case .icon: return "icon"
        case .searchField: return "searchField"
        case .scrollView: return "scrollView"
        case .scrollBar: return "scrollBar"
        case .staticText: return "staticText"
        case .textField: return "textField"
        case .secureTextField: return "secureTextField"
        case .datePicker: return "datePicker"
        case .textView: return "textView"
        case .menu: return "menu"
        case .menuItem: return "menuItem"
        case .menuBar: return "menuBar"
        case .menuBarItem: return "menuBarItem"
        case .map: return "map"
        case .webView: return "webView"
        case .incrementArrow: return "incrementArrow"
        case .decrementArrow: return "decrementArrow"
        case .timeline: return "timeline"
        case .ratingIndicator: return "ratingIndicator"
        case .valueIndicator: return "valueIndicator"
        case .splitGroup: return "splitGroup"
        case .splitter: return "splitter"
        case .relevanceIndicator: return "relevanceIndicator"
        case .colorWell: return "colorWell"
        case .helpTag: return "helpTag"
        case .matte: return "matte"
        case .dockItem: return "dockItem"
        case .ruler: return "ruler"
        case .rulerMarker: return "rulerMarker"
        case .grid: return "grid"
        case .levelIndicator: return "levelIndicator"
        case .cell: return "cell"
        case .layoutArea: return "layoutArea"
        case .layoutItem: return "layoutItem"
        case .handle: return "handle"
        case .stepper: return "stepper"
        case .tab: return "tab"
        case .touchBar: return "touchBar"
        case .statusItem: return "statusItem"
        @unknown default: return "other"
        }
    }

    // MARK: - Query

    /// An XCUITest query sent by Xamine as JSON steps, evaluated with XCUITest's own query API so matching is exact.
    enum Query {
        enum Step {
            case descendants(XCUIElement.ElementType)
            case children(XCUIElement.ElementType)
            case key(String)
            case typedKey(XCUIElement.ElementType, String)
            case predicate(NSPredicate)
            case containing(XCUIElement.ElementType, String)
            case boundBy(Int)
            case firstMatch
            case element
        }

        enum Node {
            case query(XCUIElementQuery)
            case element(XCUIElement)
        }

        static func parse(_ text: String) throws -> [Step] {
            guard let data = text.data(using: .utf8),
                  let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw AgentFailure(message: "steps must be a JSON array.")
            }
            return try list.map { item in
                let type = elementType(item["type"] as? String)
                switch item["op"] as? String {
                case "descendants": return .descendants(type)
                case "children": return .children(type)
                case "key": return .key(item["key"] as? String ?? "")
                case "typedKey": return .typedKey(type, item["key"] as? String ?? "")
                case "containing": return .containing(type, item["key"] as? String ?? "")
                case "boundBy": return .boundBy(item["index"] as? Int ?? 0)
                case "firstMatch": return .firstMatch
                case "element": return .element
                case "predicate":
                    // Built with %@ so the value needs no escaping.
                    let key = item["key"] as? String ?? "label"
                    let op = item["operator"] as? String ?? "=="
                    let modifier = (item["caseInsensitive"] as? Bool) == true ? "[c]" : ""
                    return .predicate(NSPredicate(format: "\(key) \(op)\(modifier) %@", item["value"] as? String ?? ""))
                case let other:
                    throw AgentFailure(message: "Unknown query step \(other ?? "nil").")
                }
            }
        }

        /// The query after each step, with how many elements it matched.
        static func evaluate(_ steps: [Step], from app: XCUIApplication) -> (counts: [Int], result: Node) {
            var node = Node.element(app)
            var counts: [Int] = []
            for step in steps {
                node = apply(step, to: node)
                switch node {
                case .query(let query): counts.append(query.count)
                case .element(let element): counts.append(element.exists ? 1 : 0)
                }
            }
            return (counts, node)
        }

        private static func apply(_ step: Step, to node: Node) -> Node {
            switch step {
            case .descendants(let type):
                switch node {
                case .query(let query): return .query(query.descendants(matching: type))
                case .element(let element): return .query(element.descendants(matching: type))
                }
            case .children(let type):
                switch node {
                case .query(let query): return .query(query.children(matching: type))
                case .element(let element): return .query(element.children(matching: type))
                }
            case .key(let key): return .query(asQuery(node).matching(identifier: key))
            case .typedKey(let type, let key): return .query(asQuery(node).matching(type, identifier: key))
            case .predicate(let predicate): return .query(asQuery(node).matching(predicate))
            case .containing(let type, let key): return .query(asQuery(node).containing(type, identifier: key))
            case .boundBy(let index): return .element(asQuery(node).element(boundBy: index))
            case .firstMatch: return .element(element(node))
            case .element: return .element(element(node))
            }
        }

        /// Filters apply to queries; an element (after firstMatch, say) is treated as a query for itself and below.
        private static func asQuery(_ node: Node) -> XCUIElementQuery {
            switch node {
            case .query(let query): return query
            case .element(let element): return element.descendants(matching: .any)
            }
        }

        static func element(_ node: Node) -> XCUIElement {
            switch node {
            case .query(let query): return query.firstMatch
            case .element(let element): return element
            }
        }

        static func elements(_ node: Node, limit: Int) -> [XCUIElement] {
            switch node {
            case .query(let query): return (0..<min(query.count, limit)).map { query.element(boundBy: $0) }
            case .element(let element): return element.exists ? [element] : []
            }
        }

        static func elementType(_ name: String?) -> XCUIElement.ElementType {
            guard let name, name != "any" else { return .any }
            return allTypes.first { XamineAgentTests.typeName($0) == name } ?? .any
        }

        private static let allTypes: [XCUIElement.ElementType] = (0...90).compactMap { XCUIElement.ElementType(rawValue: UInt($0)) }
    }
}

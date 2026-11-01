import Network
import XCTest

/// Runs for as long as Xamine needs it: serves the UI hierarchy and screenshots of any app on this device over HTTP.
///
/// Endpoints (all GET):
/// - `/status` → `{"ok": true, "device": "...", "port": 8765}`
/// - `/tree?bundleId=com.example` → the app's element tree as JSON (see `encode`)
/// - `/foreground?candidates=a,b,c` → `{"bundleId": "..."}`, the first candidate running in the foreground,
///   or SpringBoard when none is
/// - `/screenshot` → PNG of the whole screen
/// - `/shutdown` → ends the test
final class XamineAgentTests: XCTestCase {
    static let port: NWEndpoint.Port = 8765

    private var listener: NWListener?
    private var shouldStop = false

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
                    let response = self.respond(to: target)
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
            let foreground = candidates.first { XCUIApplication(bundleIdentifier: $0).state == .runningForeground }
            return json(["bundleId": foreground ?? "com.apple.springboard"])

        case "/screenshot":
            return Response(contentType: "image/png", body: Self.uprightPNG(XCUIScreen.main.screenshot().image))

        case "/shutdown":
            shouldStop = true
            return json(["ok": true])

        default:
            return json(["error": "Unknown path \(target)"], status: "404 Not Found")
        }
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
}

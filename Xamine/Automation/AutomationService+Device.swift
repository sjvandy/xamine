import AppKit

/// A scan of an app on an iPhone, iPad or Simulator, taken through the on-device agent. Element refs (`e12`) are
/// node ids in it.
struct DeviceSnapshot {
    let id: Int
    let tree: UITree
    let device: IOSDevice
}

/// The automation tools for iOS and iPadOS, used when a call names a `device`. Everything goes through Xamine's
/// XCUITest agent on the device (see `Agent/UITests/XamineAgentTests.swift`): snapshots come from
/// `XCUIApplication.snapshot()`, and actions are real XCUITest calls on queries the agent rebuilds from
/// `QueryResolver.json`, so they behave exactly like the generated test will.
extension AutomationService {
    private var deviceManager: DeviceManager { AppState.shared.devices }

    func handleDevice(_ method: String, device name: String, params: [String: JSONValue]) async throws -> JSONValue {
        let device = try await findDevice(name)
        switch method {
        case "status": return try await deviceStatus(device)
        case "list_apps": return try await deviceApps(device)
        case "recording_stop":
            var rest = params
            rest["device"] = nil
            return try await handle(method, params: rest)
        default: break
        }

        let client = try await agent(for: device)
        let bundleID = try await deviceApp(params, device: device)
        switch method {
        case "launch_app": return try await deviceLaunch(device, bundleID: bundleID, client: client, params: params)
        case "snapshot": return try await deviceSnapshotTool(device, bundleID: bundleID, client: client, params: params)
        case "find_elements": return try await deviceFind(device, bundleID: bundleID, client: client, params: params)
        case "screenshot": return try await deviceScreenshot(device, bundleID: bundleID, client: client, params: params)
        case "get_queries": return try await deviceQueries(device, bundleID: bundleID, client: client, params: params)
        case "click": return try await deviceTap(device, bundleID: bundleID, client: client, params: params)
        case "type_text": return try await deviceType(device, bundleID: bundleID, client: client, params: params)
        case "press_key": return try await deviceKey(device, bundleID: bundleID, client: client, params: params)
        case "scroll": return try await deviceSwipe(device, bundleID: bundleID, client: client, params: params)
        case "wait_for": return try await deviceWait(device, bundleID: bundleID, client: client, params: params)
        case "resolve_query": return try await deviceResolve(device, bundleID: bundleID, client: client, params: params)
        case "recording_start":
            let composer = TestComposer(name: params["name"]?.string ?? deviceManager.appName(for: bundleID), bundleID: bundleID, platform: .iOSDevice)
            recording = composer
            recordingDeviceID = device.id
            return ["text": .string("Recording \(composer.name)Tests for \(bundleID) on \(device.name). Taps, typing, keys, swipes and wait_for are added until recording_stop.")]
        default:
            throw Failure(code: "unsupported", message: "\(method) isn't available for iOS devices.")
        }
    }

    // MARK: - Devices

    func listDevices() async throws -> JSONValue {
        let manager = deviceManager
        await manager.refreshDevices()
        let running = manager.isAgentRunning ? manager.selectedDeviceID : nil
        var lines: [String] = []
        var list: [JSONValue] = []
        for device in manager.devices {
            let kind = device.isSimulator ? "Simulator" : (device.isPad ? "iPad" : "iPhone")
            let state = device.isSimulator ? "available" : (device.isConnected ? "connected" : "not connected")
            let agent = device.id == running ? ", Xamine agent running" : ""
            lines.append("\(device.name) — \(kind), iOS \(device.osVersion), \(state)\(agent)\n    device: \(device.udid)")
            list.append(["name": .string(device.name), "udid": .string(device.udid), "id": .string(device.id), "simulator": .bool(device.isSimulator),
                         "connected": .bool(device.isConnected), "agentRunning": .bool(device.id == running)])
        }
        if lines.isEmpty { lines = ["No iPhones, iPads or Simulators found. Connect a device with a cable, or create a Simulator in Xcode."] }
        lines.append("\nPass device (a name or the UDID) to any tool to use it. The first call starts Xamine's agent on the device, which takes a minute the first time.")
        return ["text": .string(lines.joined(separator: "\n")), "devices": .array(list)]
    }

    func releaseDevice(_ params: [String: JSONValue]) async throws -> JSONValue {
        let manager = deviceManager
        let name = manager.selectedDevice?.name ?? "the device"
        guard manager.client != nil || manager.isAgentRunning else {
            return ["text": "Xamine's agent isn't running on any device."]
        }
        manager.stopAgent()
        return ["text": .string("Stopped Xamine's agent on \(name), so your own UI tests can run there. The next call with device starts it again.")]
    }

    private func findDevice(_ name: String) async throws -> IOSDevice {
        let manager = deviceManager
        if manager.devices.isEmpty { await manager.refreshDevices() }
        func match() -> IOSDevice? {
            let devices = manager.devices
            if let exact = devices.first(where: { $0.id == name || $0.udid == name || $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return exact
            }
            // Device names often hold typographic apostrophes ("Steven’s iPhone"), so also compare loosely.
            func loose(_ string: String) -> String { string.lowercased().filter { $0.isLetter || $0.isNumber } }
            let partial = devices.filter { loose($0.name).contains(loose(name)) }
            return partial.count == 1 ? partial.first : partial.first { !$0.isSimulator }
        }
        if let device = match() { return device }
        await manager.refreshDevices()
        if let device = match() { return device }
        let names = manager.devices.map(\.name)
        throw Failure(code: "deviceNotFound", message: "No device named “\(name)”. Available: \(names.isEmpty ? "none" : names.joined(separator: ", ")). Use list_devices.")
    }

    /// The agent on `device`, started (built, installed and launched) if needed.
    private func agent(for device: IOSDevice) async throws -> AgentClient {
        let manager = deviceManager
        if manager.selectedDeviceID != device.id { manager.selectedDeviceID = device.id }
        if manager.isAgentRunning, await manager.reconnect(wait: .seconds(3)), let client = manager.client { return client }
        await manager.startAgent()
        if manager.isAgentRunning, let client = manager.client { return client }
        if case .failed(let message) = manager.state {
            throw Failure(code: "agentFailed", message: "Couldn't start Xamine's agent on \(device.name): \(message)")
        }
        throw Failure(code: "agentFailed", message: "Xamine's agent didn't start on \(device.name). Check the device is unlocked, then try again.")
    }

    /// The app a device call is about: `app` (a bundle ID or an installed app's name), else the one used last.
    private func deviceApp(_ params: [String: JSONValue], device: IOSDevice) async throws -> String {
        if let name = params["app"]?.string, !name.isEmpty {
            var bundleID = name
            if !name.contains(".") {
                if deviceManager.apps.isEmpty { await deviceManager.loadApps() }
                guard let app = deviceManager.apps.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                    throw Failure(code: "appNotFound", message: "No app named “\(name)” on \(device.name). Use list_apps with device, or pass the bundle ID.")
                }
                bundleID = app.bundleID
            }
            currentDeviceApps[device.id] = bundleID
            return bundleID
        }
        if let current = currentDeviceApps[device.id] { return current }
        throw Failure(code: "noApp", message: "Say which app with app (bundle ID or name), or open one with launch_app and device.")
    }

    private func deviceStatus(_ device: IOSDevice) async throws -> JSONValue {
        let manager = deviceManager
        let running = manager.isAgentRunning && manager.selectedDeviceID == device.id
        let lines = [
            "\(device.name): \(device.summary)",
            "Xamine agent: \(running ? "running" : "not running (starts on the first call)")",
            "Current app: \(currentDeviceApps[device.id] ?? "none")",
            "Recording: \(recording.map { "\($0.name), \($0.steps.count) steps" } ?? "off")",
        ]
        return ["text": .string(lines.joined(separator: "\n")), "agentRunning": .bool(running)]
    }

    private func deviceApps(_ device: IOSDevice) async throws -> JSONValue {
        let manager = deviceManager
        if manager.selectedDeviceID != device.id { manager.selectedDeviceID = device.id }
        await manager.loadApps()
        // Your own apps first; Apple's after.
        let apps = manager.apps.sorted { ($0.isApple ? 1 : 0) < ($1.isApple ? 1 : 0) }
        let lines = apps.map { "\($0.name) — \($0.bundleID)" }
        return ["text": .string(lines.isEmpty ? "No apps found on \(device.name)." : "Apps on \(device.name):\n" + lines.joined(separator: "\n")),
                "apps": .array(apps.map { ["name": .string($0.name), "bundleId": .string($0.bundleID)] })]
    }

    // MARK: - Scanning

    private func scanDevice(_ device: IOSDevice, bundleID: String, client: AgentClient) async throws -> DeviceSnapshot {
        let root: AgentNode
        do {
            root = try await client.tree(bundleID: bundleID)
        } catch {
            let reason = error.localizedDescription.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            throw Failure(code: "scanFailed", message: "\(reason). Open the app with launch_app (and device) first.")
        }
        let tree = root.makeTree(appName: deviceManager.appName(for: bundleID), bundleID: bundleID)
        let snapshot = DeviceSnapshot(id: nextSnapshotID, tree: tree, device: device)
        nextSnapshotID += 1
        deviceSnapshots["\(device.id)/\(bundleID)"] = snapshot
        return snapshot
    }

    private func header(for snapshot: DeviceSnapshot) -> String {
        let tree = snapshot.tree
        let screen = tree.windowFrame
        return "\(tree.appName) (\(tree.bundleID ?? "?")) on \(snapshot.device.name), iOS \(snapshot.device.osVersion) — "
            + "screen \(Int(screen.width))×\(Int(screen.height)) — snapshot \(snapshot.id), \(tree.nodes.count) elements"
    }

    private func deviceLaunch(_ device: IOSDevice, bundleID: String, client: AgentClient, params: [String: JSONValue]) async throws -> JSONValue {
        let relaunch = params["relaunch"]?.bool ?? false
        do {
            _ = try await client.automate("launch", bundleID: bundleID, parameters: ["mode": relaunch ? "launch" : "activate"])
        } catch {
            throw Failure(code: "launchFailed", message: "Couldn't open \(bundleID) on \(device.name): \(error.localizedDescription)")
        }
        let name = deviceManager.appName(for: bundleID)
        return ["text": .string("\(relaunch ? "Relaunched" : "Opened") \(name) (\(bundleID)) on \(device.name)."), "bundleId": .string(bundleID)]
    }

    private func deviceSnapshotTool(_ device: IOSDevice, bundleID: String, client: AgentClient, params: [String: JSONValue]) async throws -> JSONValue {
        let snapshot = try await scanDevice(device, bundleID: bundleID, client: client)
        let tree = snapshot.tree
        let maxDepth = params["max_depth"]?.int ?? .max
        let frames = params["frames"]?.bool ?? false
        let interactiveOnly = params["interactive_only"]?.bool ?? false
        var lines = [header(for: snapshot)]
        for node in tree.nodes where node.depth <= maxDepth {
            if interactiveOnly, node.id != 0, !node.hasSelector, ![.control, .input, .link].contains(node.kind.category) { continue }
            if lines.count > 2000 {
                lines.append("… more. Use max_depth, interactive_only or find_elements.")
                break
            }
            lines.append(String(repeating: "  ", count: node.depth) + describe(node, frames: frames))
        }
        return ["text": .string(lines.joined(separator: "\n")), "snapshotId": .number(Double(snapshot.id)), "elementCount": .number(Double(tree.nodes.count))]
    }

    private func deviceFind(_ device: IOSDevice, bundleID: String, client: AgentClient, params: [String: JSONValue]) async throws -> JSONValue {
        let snapshot = try await scanDevice(device, bundleID: bundleID, client: client)
        let tree = snapshot.tree
        let text = params["text"]?.string?.lowercased()
        let kind = params["kind"]?.string?.lowercased().replacingOccurrences(of: " ", with: "")
        let identifier = params["identifier"]?.string
        let limit = params["limit"]?.int ?? 25
        let matches = tree.nodes.filter { node in
            if let identifier, node.identifier != identifier { return false }
            if let kind, ![node.kind.typeName, node.kind.queryName, node.kind.displayName]
                .contains(where: { $0.lowercased().replacingOccurrences(of: " ", with: "") == kind }) { return false }
            if let text, ![node.identifier, node.title, node.label, node.value, node.placeholder]
                .contains(where: { $0?.lowercased().contains(text) == true }) { return false }
            return true
        }
        let builder = QueryBuilder(tree: tree, includeAppDeclaration: false)
        var lines = [header(for: snapshot), "\(matches.count) match\(matches.count == 1 ? "" : "es")\(matches.count > limit ? ", showing \(limit)" : ""):"]
        var results: [JSONValue] = []
        for node in matches.prefix(limit) {
            let query = builder.bestQuery(for: node.id)
            lines.append("\(describe(node, frames: true))\n    → \(query.replacingOccurrences(of: "\n    ", with: ""))")
            results.append(["ref": .string("e\(node.id)"), "type": .string(node.kind.typeName), "query": .string(query)])
        }
        return ["text": .string(lines.joined(separator: "\n")), "snapshotId": .number(Double(snapshot.id)), "elements": .array(results)]
    }

    // MARK: - Targets

    /// An element named by `element` (a ref into the latest snapshot of the app on this device) or `query`.
    private struct DeviceTarget {
        let query: String
        let steps: [QueryResolver.Step]
        let node: UINode?
        var description: String
    }

    private func deviceTarget(_ params: [String: JSONValue], device: IOSDevice, bundleID: String, required: Bool = true) throws -> DeviceTarget? {
        if let ref = params["element"]?.string, !ref.isEmpty {
            guard let snapshot = deviceSnapshots["\(device.id)/\(bundleID)"] else {
                throw Failure(code: "noSnapshot", message: "Take a snapshot (or find_elements) of this app on \(device.name) first; refs like \(ref) come from it.")
            }
            guard ref.hasPrefix("e"), let id = Int(ref.dropFirst()), snapshot.tree.nodes.indices.contains(id) else {
                throw Failure(code: "elementNotFound", message: "No element \(ref) in snapshot \(snapshot.id).")
            }
            // Act by query rather than position: the agent finds the element afresh, so a ref from before the UI
            // moved still reaches the right element (or fails clearly).
            let query = QueryBuilder(tree: snapshot.tree, includeAppDeclaration: false).bestQuery(for: id)
            let node = snapshot.tree.node(id)
            return DeviceTarget(query: query, steps: try parse(query), node: node, description: describe(node))
        }
        if let query = params["query"]?.string, !query.isEmpty {
            let steps = try parse(query)
            return DeviceTarget(query: Self.trimmed(query), steps: steps, node: nil, description: Self.trimmed(query))
        }
        if required { throw Failure(code: "invalidParams", message: "Pass element (a ref like e12) or query.") }
        return nil
    }

    private func perform(_ path: String, on device: IOSDevice, bundleID: String, client: AgentClient, target: DeviceTarget?,
                         parameters: [String: String] = [:], timeout: TimeInterval = 60) async throws -> JSONValue {
        do {
            return try await client.automate(path, bundleID: bundleID, steps: target.map { QueryResolver.json($0.steps) },
                                             parameters: parameters, timeout: timeout)
        } catch {
            let hint = target != nil ? " Use resolve_query with device to see why." : ""
            throw Failure(code: "actionFailed", message: "\(error.localizedDescription)\(hint)")
        }
    }

    /// A query the agent passed that matches several elements gets `.firstMatch`, which is what the agent taps, so the
    /// recorded test doesn't fail with "multiple matching elements". Counts come from XCUITest on the device.
    private func disambiguated(_ target: DeviceTarget, device: IOSDevice, bundleID: String, client: AgentClient) async throws -> DeviceTarget {
        guard target.node == nil, let last = target.steps.last?.operation,
              ![.firstMatch, .element].contains(last), !{ if case .boundBy = last { true } else { false } }() else { return target }
        let reply = try await perform("resolve", on: device, bundleID: bundleID, client: client, target: target)
        guard case .array(let counts) = reply["counts"], let count = counts.last?.int, count > 1 else { return target }
        let query = target.query + ".firstMatch"
        return DeviceTarget(query: query, steps: try parse(query), node: nil, description: "\(target.description) (first of \(count) matches)")
    }

    private func recordOnDevice(_ step: TestComposer.Step, device: IOSDevice, bundleID: String) -> String {
        record(step, bundleID: bundleID, deviceID: device.id, platform: .iOSDevice)
    }

    // MARK: - Actions

    private func deviceTap(_ device: IOSDevice, bundleID: String, client: AgentClient, params: [String: JSONValue]) async throws -> JSONValue {
        guard var target = try deviceTarget(params, device: device, bundleID: bundleID) else { return .null }
        target = try await disambiguated(target, device: device, bundleID: bundleID, client: client)
        // Switches get checked: a SwiftUI Toggle in a Form spans its whole row, and a tap in the middle lands on the
        // label without toggling. Then the switch control inside is tapped, and that's what gets recorded.
        let before = try await switchValue(target, device: device, bundleID: bundleID, client: client)
        _ = try await perform("tap", on: device, bundleID: bundleID, client: client, target: target)
        try? await Task.sleep(for: .milliseconds(300))

        var query = target.query
        var note = ""
        if let before, let after = try await switchValue(target, device: device, bundleID: bundleID, client: client), after == before {
            let inner = DeviceTarget(query: target.query + ".switches.firstMatch", steps: try parse(target.query + ".switches.firstMatch"),
                                     node: nil, description: target.description)
            _ = try await perform("tap", on: device, bundleID: bundleID, client: client, target: inner)
            try? await Task.sleep(for: .milliseconds(300))
            if try await switchValue(target, device: device, bundleID: bundleID, client: client) != before {
                query = inner.query
                note = " Tapping the middle of the switch's row didn't toggle it, so Xamine tapped the switch control inside and recorded that."
            } else {
                note = " The switch's value didn't change; check the result with a snapshot."
            }
        }
        let code = recordOnDevice(.init(query: query, action: .click), device: device, bundleID: bundleID)
        return actionResult("Tapped \(target.description) on \(device.name).\(note) Take a new snapshot to see the result.", code: code)
    }

    /// The value of the switch `target` finds, or `nil` if it isn't a switch.
    private func switchValue(_ target: DeviceTarget, device: IOSDevice, bundleID: String, client: AgentClient) async throws -> String? {
        if let node = target.node, !["switch", "toggle"].contains(node.kind.typeName) { return nil }
        if target.node == nil, !target.steps.contains(where: {
            if case .descendants(let type) = $0.operation { return type == "switch" || type == "toggle" }
            if case .typedKey(let type, _) = $0.operation { return type == "switch" || type == "toggle" }
            return false
        }) { return nil }
        let snapshot = try await scanDevice(device, bundleID: bundleID, client: client)
        guard let id = QueryResolver(tree: snapshot.tree).resolve(target.steps).matches.first else { return nil }
        let node = snapshot.tree.node(id)
        return ["switch", "toggle"].contains(node.kind.typeName) ? (node.value ?? "") : nil
    }

    private func deviceType(_ device: IOSDevice, bundleID: String, client: AgentClient, params: [String: JSONValue]) async throws -> JSONValue {
        guard var text = params["text"]?.string else { throw Failure(code: "invalidParams", message: "type_text needs text.") }
        var target = try deviceTarget(params, device: device, bundleID: bundleID, required: false)
        if let query = target { target = try await disambiguated(query, device: device, bundleID: bundleID, client: client) }
        let typed = text
        if params["clear"]?.bool == true, let value = target?.node?.value, value != target?.node?.placeholder {
            // Delete what's there; XCUIKeyboardKey.delete is a backspace character.
            text = String(repeating: "\u{8}", count: value.count) + text
        }
        _ = try await perform("type", on: device, bundleID: bundleID, client: client, target: target, parameters: ["text": text])
        let code = recordOnDevice(.init(query: target?.query, action: .typeText(text)), device: device, bundleID: bundleID)
        let into = target.map { " into \($0.description)" } ?? ""
        return actionResult("Typed \(Self.quote(typed))\(into) on \(device.name).", code: code)
    }

    private func deviceKey(_ device: IOSDevice, bundleID: String, client: AgentClient, params: [String: JSONValue]) async throws -> JSONValue {
        guard let name = params["key"]?.string, !name.isEmpty else { throw Failure(code: "invalidParams", message: "press_key needs key.") }
        let step: TestComposer.Step
        let agentName: String
        switch name.lowercased() {
        case "home", "volumeup", "volumedown":
            agentName = ["home": "home", "volumeup": "volumeUp", "volumedown": "volumeDown"][name.lowercased()]!
            step = .init(query: nil, action: .deviceButton(agentName))
        case "return", "enter": agentName = "return"; step = .init(query: nil, action: .typeText("\n"))
        case "delete", "backspace": agentName = "delete"; step = .init(query: nil, action: .typeText("\u{8}"))
        case "tab": agentName = "tab"; step = .init(query: nil, action: .typeText("\t"))
        case "space": agentName = "space"; step = .init(query: nil, action: .typeText(" "))
        default:
            guard name.count == 1 else {
                throw Failure(code: "invalidParams", message: "On iOS, key can be home, volumeUp, volumeDown, return, delete, tab, space or one character.")
            }
            agentName = name
            step = .init(query: nil, action: .typeText(name))
        }
        _ = try await perform("key", on: device, bundleID: bundleID, client: client, target: nil, parameters: ["name": agentName])
        try? await Task.sleep(for: .milliseconds(300))
        let code = recordOnDevice(step, device: device, bundleID: bundleID)
        return actionResult("Pressed \(agentName) on \(device.name).", code: code)
    }

    /// `scroll` on iOS is a swipe. The direction is where the content should move into view, so scrolling down swipes up.
    private func deviceSwipe(_ device: IOSDevice, bundleID: String, client: AgentClient, params: [String: JSONValue]) async throws -> JSONValue {
        let target = try deviceTarget(params, device: device, bundleID: bundleID, required: false)
        let direction = params["direction"]?.string ?? "down"
        let finger = ["down": "up", "up": "down", "left": "right", "right": "left"][direction] ?? "up"
        _ = try await perform("swipe", on: device, bundleID: bundleID, client: client, target: target, parameters: ["direction": finger])
        try? await Task.sleep(for: .milliseconds(300))
        let code = recordOnDevice(.init(query: target?.query, action: .swipe(finger)), device: device, bundleID: bundleID)
        return actionResult("Scrolled \(target?.description ?? "the app") \(direction) (swiped \(finger)) on \(device.name).", code: code)
    }

    private func deviceWait(_ device: IOSDevice, bundleID: String, client: AgentClient, params: [String: JSONValue]) async throws -> JSONValue {
        let timeout = params["timeout"]?.double ?? 5
        let gone = params["gone"]?.bool ?? false
        if let query = params["query"]?.string, !query.isEmpty {
            let target = DeviceTarget(query: Self.trimmed(query), steps: try parse(query), node: nil, description: Self.trimmed(query))
            let reply = try await perform("wait", on: device, bundleID: bundleID, client: client, target: target,
                                          parameters: ["timeout": String(timeout), "gone": gone ? "1" : "0"], timeout: timeout + 30)
            guard reply["met"]?.bool == true else {
                throw Failure(code: "timeout", message: "\(target.query) \(gone ? "was still there" : "didn't appear") after \(Int(timeout))s." + (gone ? "" : " Use resolve_query with device to see why."))
            }
            let code = recordOnDevice(.init(query: target.query, action: gone ? .assertGone(timeout: timeout) : .assertExists(timeout: timeout)), device: device, bundleID: bundleID)
            return actionResult(gone ? "\(target.query) is gone." : "Found \(target.query).", code: code)
        }
        guard let text = params["text"]?.string, !text.isEmpty else { throw Failure(code: "invalidParams", message: "wait_for needs query or text.") }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let snapshot = try await scanDevice(device, bundleID: bundleID, client: client)
            let found = snapshot.tree.nodes.first { node in
                [node.identifier, node.title, node.label, node.value].contains { $0?.localizedCaseInsensitiveContains(text) == true }
            }
            if (found != nil) != gone {
                let query = found.map { QueryBuilder(tree: snapshot.tree, includeAppDeclaration: false).bestQuery(for: $0.id) }
                    ?? "app.descendants(matching: .any).matching(NSPredicate(format: \(QueryBuilder.literal("label CONTAINS '" + text.replacingOccurrences(of: "'", with: "\\'") + "'")))).firstMatch"
                let code = recordOnDevice(.init(query: query, action: gone ? .assertGone(timeout: timeout) : .assertExists(timeout: timeout)), device: device, bundleID: bundleID)
                return actionResult(gone ? "“\(text)” is gone." : "Found \(found.map { describe($0) } ?? text).", code: code)
            }
            if Date() >= deadline {
                throw Failure(code: "timeout", message: "“\(text)” \(gone ? "was still there" : "didn't appear") after \(Int(timeout))s.")
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    // MARK: - Inspection

    private func deviceScreenshot(_ device: IOSDevice, bundleID: String, client: AgentClient, params: [String: JSONValue]) async throws -> JSONValue {
        var image: CGImage
        do {
            image = try await client.screenshot()
        } catch {
            throw Failure(code: "captureFailed", message: "Couldn't take a screenshot on \(device.name): \(error.localizedDescription)")
        }
        var described = "the screen of \(device.name)"
        if let ref = params["element"]?.string, !ref.isEmpty,
           let snapshot = deviceSnapshots["\(device.id)/\(bundleID)"], ref.hasPrefix("e"), let id = Int(ref.dropFirst()),
           snapshot.tree.nodes.indices.contains(id), let frame = snapshot.tree.node(id).frame, snapshot.tree.windowFrame.width > 0 {
            let scale = CGFloat(image.width) / snapshot.tree.windowFrame.width
            let pixels = frame.insetBy(dx: -8, dy: -8).applying(CGAffineTransform(scaleX: scale, y: scale))
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if !pixels.isEmpty, let cropped = image.cropping(to: pixels.integral) { image = cropped }
            described = describe(snapshot.tree.node(id))
        }
        guard let png = Self.pngData(image) else { throw Failure(code: "captureFailed", message: "Couldn't encode the screenshot.") }
        var scaleNote = ""
        if let screen = deviceSnapshots["\(device.id)/\(bundleID)"]?.tree.windowFrame, screen.width > 0, params["element"] == nil {
            scaleNote = " Snapshot frames are in points; this image is \(Int((CGFloat(image.width) / screen.width).rounded()))× that."
        }
        return ["text": .string("Screenshot of \(described), \(image.width)×\(image.height) px.\(scaleNote)"), "png": .string(png.base64EncodedString())]
    }

    private func deviceQueries(_ device: IOSDevice, bundleID: String, client: AgentClient, params: [String: JSONValue]) async throws -> JSONValue {
        if deviceSnapshots["\(device.id)/\(bundleID)"] == nil || params["query"] != nil {
            _ = try await scanDevice(device, bundleID: bundleID, client: client)
        }
        guard let snapshot = deviceSnapshots["\(device.id)/\(bundleID)"] else { return .null }
        let id: Int
        if let target = try deviceTarget(params, device: device, bundleID: bundleID), let node = target.node {
            id = node.id
        } else if let query = params["query"]?.string, let match = QueryResolver(tree: snapshot.tree).resolve(try parse(query)).matches.first {
            id = match
        } else {
            throw Failure(code: "elementNotFound", message: "Nothing matches that query in the latest snapshot.")
        }
        let builder = QueryBuilder(tree: snapshot.tree, includeAppDeclaration: false)
        let queries = builder.queries(for: id)
        var lines = ["\(describe(snapshot.tree.node(id)))", "Path: \(queries.breadcrumb)", "", "Best: \(builder.bestQuery(for: id))"]
        for (title, snippet) in [("By identifier", queries.byIdentifier), ("From anchor", queries.fromAnchor),
                                 ("From container", queries.hasUniqueContainer ? queries.fromContainer : nil), ("By hierarchy (text-free)", queries.byHierarchy)] {
            guard let snippet else { continue }
            lines.append("\n\(title):\n\(snippet.code)")
            if let note = snippet.note { lines.append("  (\(note))") }
        }
        return ["text": .string(lines.joined(separator: "\n")), "best": .string(builder.bestQuery(for: id))]
    }

    /// Asks XCUITest on the device how many elements each step matches, then explains the result against a snapshot.
    private func deviceResolve(_ device: IOSDevice, bundleID: String, client: AgentClient, params: [String: JSONValue]) async throws -> JSONValue {
        guard let query = params["query"]?.string, !query.isEmpty else { throw Failure(code: "invalidParams", message: "resolve_query needs query.") }
        let steps = try parse(query)
        let target = DeviceTarget(query: Self.trimmed(query), steps: steps, node: nil, description: query)
        let reply = try await perform("resolve", on: device, bundleID: bundleID, client: client, target: target)
        let snapshot = try await scanDevice(device, bundleID: bundleID, client: client)
        let counts: [Int]
        if case .array(let values) = reply["counts"] { counts = values.compactMap(\.int) } else { counts = [] }
        // Match what XCUITest found to the snapshot's nodes by type and frame, so they get refs.
        var matches: [Int] = []
        if case .array(let found) = reply["matches"] {
            for item in found {
                guard case .array(let frameValues) = item["frame"], frameValues.count == 4 else { continue }
                let f = frameValues.compactMap(\.double)
                guard f.count == 4 else { continue }
                let frame = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
                if let node = snapshot.tree.nodes.first(where: {
                    !matches.contains($0.id) && $0.kind.typeName == item["type"]?.string && $0.frame.map { Self.close($0, frame) } == true
                }) {
                    matches.append(node.id)
                }
            }
        }
        return resolutionReport(steps: steps, tree: snapshot.tree, searched: header(for: snapshot),
                                counts: counts.count == steps.count ? counts : QueryResolver(tree: snapshot.tree).resolve(steps).counts,
                                matches: matches, source: "Match counts are XCUITest's own, from the device.")
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }
}

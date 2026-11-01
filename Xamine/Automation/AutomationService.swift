import AppKit
import ApplicationServices
import UniformTypeIdentifiers

/// Implements the automation tools in `Automation.tools` for agents and scripts connected over the socket.
@MainActor
final class AutomationService {
    struct Failure: Error {
        let code: String
        let message: String
    }

    /// One scan of an app's window. Element refs (`e12`) are node ids in the app's latest snapshot.
    private struct Snapshot {
        let id: Int
        let tree: UITree
        let elements: ScannedElements
        let target: PickedWindow
    }

    /// An element an action applies to, and the XCUITest query that finds it.
    private struct Target {
        let snapshot: Snapshot
        let nodeID: Int
        let query: String

        var node: UINode { snapshot.tree.node(nodeID) }
        var element: AXElement? { snapshot.elements[nodeID] }
    }

    private let permissions: PermissionsManager
    private var snapshots: [String: Snapshot] = [:]
    private var nextSnapshotID = 1
    private var currentBundleID: String?
    private var recording: TestComposer?

    init(permissions: PermissionsManager) {
        self.permissions = permissions
        // Builds in /tmp or a custom DerivedData folder aren't registered with Launch Services, so remember every copy
        // of an app seen running (e.g. launched by Xcode or a UI test) to offer it to launch_app later.
        for app in NSWorkspace.shared.runningApplications { Self.remember(app) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { app.map(Self.remember) }
        }
    }

    private static let knownCopiesKey = "automationKnownAppCopies"

    private static func remember(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular, let bundleID = app.bundleIdentifier, let path = app.bundleURL?.path else { return }
        var known = UserDefaults.standard.dictionary(forKey: knownCopiesKey) as? [String: [String]] ?? [:]
        guard known[bundleID]?.contains(path) != true else { return }
        known[bundleID, default: []].append(path)
        UserDefaults.standard.set(known, forKey: knownCopiesKey)
    }

    /// Every copy of the app on disk that Launch Services or Xamine knows about.
    private static func copies(of bundleID: String) -> [URL] {
        let known = (UserDefaults.standard.dictionary(forKey: knownCopiesKey) as? [String: [String]])?[bundleID] ?? []
        let urls = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID) + known.map { URL(fileURLWithPath: $0) }
        var seen = Set<String>()
        return urls.filter { url in
            let path = url.resolvingSymlinksInPath().path
            return FileManager.default.fileExists(atPath: path) && seen.insert(path).inserted
        }
    }

    func handle(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        switch method {
        case "status": return status()
        case "list_apps": return listApps()
        case "launch_app": return try await launchApp(params)
        case "snapshot": return try await snapshot(params)
        case "find_elements": return try await findElements(params)
        case "screenshot": return try await screenshot(params)
        case "get_queries": return try await getQueries(params)
        case "click": return try await click(params)
        case "type_text": return try await typeText(params)
        case "press_key": return try await pressKey(params)
        case "scroll": return try await scroll(params)
        case "wait_for": return try await waitFor(params)
        case "resolve_query": return try await resolveQuery(params)
        case "recording_start": return try recordingStart(params)
        case "recording_stop": return try recordingStop()
        default: throw Failure(code: "unknownMethod", message: "Unknown method \(method).")
        }
    }

    // MARK: - Status and apps

    private func status() -> JSONValue {
        permissions.refresh()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let front = NSWorkspace.shared.frontmostApplication
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/xamine").path
        let lines = [
            "Xamine \(version)",
            "Accessibility: \(permissions.accessibilityGranted ? "granted" : "MISSING — grant it in System Settings › Privacy & Security")",
            "Screen Recording: \(permissions.screenRecordingGranted ? "granted" : "MISSING (screenshots won't work)")",
            "Frontmost app: \(front?.localizedName ?? "?") (\(front?.bundleIdentifier ?? "?"))",
            "Current app: \(currentBundleID.map { id in "\(id) — \(runningApp(matching: id)?.bundleURL?.path ?? "not running")" } ?? "none")",
            "Recording: \(recording.map { "\($0.name), \($0.steps.count) steps" } ?? "off")",
            "Helper: \(helper)",
        ]
        return [
            "text": .string(lines.joined(separator: "\n")),
            "version": .string(version),
            "accessibility": .bool(permissions.accessibilityGranted),
            "screenRecording": .bool(permissions.screenRecordingGranted),
            "frontmostApp": .string(front?.bundleIdentifier ?? ""),
            "recording": .bool(recording != nil),
        ]
    }

    private func listApps() -> JSONValue {
        var lines: [String] = []
        var apps: [JSONValue] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier else { continue }
            let titles = WindowLocator.windows(of: app).map { $0.title ?? "" }
            lines.append("\(app.localizedName ?? bundleID) — \(bundleID)\(app.isActive ? " (frontmost)" : "")"
                + (titles.isEmpty ? ", no windows" : ": " + titles.map { "“\($0)”" }.joined(separator: ", ")))
            apps.append(["name": .string(app.localizedName ?? ""), "bundleId": .string(bundleID), "pid": .number(Double(app.processIdentifier)),
                         "windows": .array(titles.map(JSONValue.string))])
        }
        return ["text": .string(lines.joined(separator: "\n")), "apps": .array(apps)]
    }

    private func launchApp(_ params: [String: JSONValue]) async throws -> JSONValue {
        guard let name = params["app"]?.string, !name.isEmpty else { throw Failure(code: "invalidParams", message: "launch_app needs app.") }
        var notes: [String] = []
        let url: URL
        if name.hasSuffix(".app") || name.hasPrefix("/") || name.hasPrefix("~") {
            url = URL(fileURLWithPath: (name as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { throw Failure(code: "appNotFound", message: "No app at \(url.path).") }
        } else if let running = runningApp(matching: name), let bundleURL = running.bundleURL {
            url = bundleURL
            notes.append("It was already running; brought it forward.")
        } else {
            // Several copies may be registered (Xcode builds in DerivedData, /tmp, /Applications…). The one built most
            // recently is almost always the one being worked on.
            let copies = Self.copies(of: name)
            if let newest = copies.max(by: { Self.buildDate($0) < Self.buildDate($1) }) {
                url = newest
                if copies.count > 1 {
                    notes.append("\(copies.count) copies of \(name) are installed; opened the most recently built. Pass a path to choose another:\n"
                        + copies.map { "  \($0.path) (built \(Self.buildDate($0).formatted(date: .abbreviated, time: .shortened)))" }.joined(separator: "\n"))
                }
            } else if let found = Self.findApplication(named: name) {
                url = found
            } else {
                throw Failure(code: "appNotFound", message: "No app with bundle ID, name or path “\(name)”.")
            }
        }

        // Launch Services brings an already-running copy forward instead of starting another from a different path.
        let bundleID = Bundle(url: url)?.bundleIdentifier
        if let bundleID, let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.bundleURL?.standardizedFileURL != url.standardizedFileURL }), let otherPath = other.bundleURL?.path {
            notes.append("Warning: another copy is running from \(otherPath). Quit it (or pass its path) so you inspect the build you mean.")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app: NSRunningApplication
        do {
            app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            throw Failure(code: "launchFailed", message: "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)")
        }
        guard let launchedID = app.bundleIdentifier else { throw Failure(code: "launchFailed", message: "The app has no bundle ID.") }
        currentBundleID = launchedID
        var window: PickedWindow?
        if params["wait"]?.bool ?? true {
            window = await WindowLocator.waitForWindow(of: launchedID)
        }
        let appName = app.localizedName ?? launchedID
        let path = app.bundleURL?.path ?? url.path
        let summary = window.map { "Launched \(appName) (\(launchedID)) from \(path); front window “\($0.title ?? "")”." }
            ?? "Launched \(appName) (\(launchedID)) from \(path), but no window appeared yet."
        return [
            "text": .string(([summary] + notes).joined(separator: "\n")),
            "bundleId": .string(launchedID),
            "path": .string(path),
            "window": .string(window?.title ?? ""),
        ]
    }

    /// When the app's executable was last written, i.e. when it was built.
    private static func buildDate(_ bundle: URL) -> Date {
        let executable = Bundle(url: bundle)?.executableURL ?? bundle
        return (try? executable.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func findApplication(named name: String) -> URL? {
        let fileName = name.hasSuffix(".app") ? name : name + ".app"
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                       NSHomeDirectory() + "/Applications", "/System/Library/CoreServices"]
        return folders.map { URL(fileURLWithPath: $0).appending(path: fileName) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func runningApp(matching name: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        let matches = apps.filter { $0.bundleIdentifier?.caseInsensitiveCompare(name) == .orderedSame }
        let named = matches.isEmpty
            ? apps.filter { $0.activationPolicy == .regular && $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }
            : matches
        // With several copies running, the one showing a window is the one meant.
        return named.first { !WindowLocator.windows(of: $0).isEmpty } ?? named.first
    }

    /// The app a call is about: the `app` parameter, else the app used last, else the frontmost app.
    private func resolveApp(_ params: [String: JSONValue]) throws -> NSRunningApplication {
        if let name = params["app"]?.string, !name.isEmpty {
            guard let app = runningApp(matching: name) else {
                throw Failure(code: "appNotRunning", message: "“\(name)” isn't running. Start it with launch_app.")
            }
            currentBundleID = app.bundleIdentifier
            return app
        }
        if let current = currentBundleID, let app = runningApp(matching: current) { return app }
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier,
              front.bundleIdentifier != nil else {
            throw Failure(code: "noApp", message: "Say which app with app (bundle ID or name), or start one with launch_app.")
        }
        currentBundleID = front.bundleIdentifier
        return front
    }

    // MARK: - Scanning

    private func requireAccessibility() throws {
        permissions.refresh()
        guard permissions.accessibilityGranted else {
            AppState.shared.showOnboarding()
            throw Failure(code: "permissionDenied", message: "Xamine needs Accessibility permission. Grant it in System Settings › Privacy & Security › Accessibility (Xamine opened its setup window).")
        }
    }

    private func scan(_ params: [String: JSONValue]) async throws -> Snapshot {
        try requireAccessibility()
        let app = try resolveApp(params)
        guard let bundleID = app.bundleIdentifier else { throw Failure(code: "noApp", message: "The app has no bundle ID.") }
        let title = params["window"]?.string
        var window = WindowLocator.frontWindow(of: bundleID, title: title)
        if window == nil {
            // Its windows may be on another Space or behind a full-screen app; bring it forward, as XCUITest would.
            app.unhide()
            app.activate()
            window = await WindowLocator.waitForWindow(of: bundleID, title: title, timeout: .seconds(3))
        }
        guard let window else {
            let hint = app.isHidden ? " The app is hidden." : ""
            throw Failure(code: "noWindow", message: "\(app.localizedName ?? bundleID) has no on-screen window\(title.map { " titled “\($0)”" } ?? "").\(hint)")
        }
        do {
            let (tree, elements) = try await scanRetrying(window)
            let snapshot = Snapshot(id: nextSnapshotID, tree: tree, elements: elements, target: window)
            nextSnapshotID += 1
            snapshots[bundleID] = snapshot
            return snapshot
        } catch {
            throw Failure(code: "scanFailed", message: error.localizedDescription)
        }
    }

    /// Right after an app is activated or switches Spaces, its window is listed before its accessibility tree is
    /// ready, so a missing window is retried briefly.
    private func scanRetrying(_ window: PickedWindow) async throws -> (tree: UITree, elements: ScannedElements) {
        for _ in 0..<4 {
            do {
                return try await HierarchyScanner.scanWithElements(window)
            } catch ScanError.windowNotFound {
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        return try await HierarchyScanner.scanWithElements(window)
    }

    private func snapshot(_ params: [String: JSONValue]) async throws -> JSONValue {
        let snapshot = try await scan(params)
        let tree = snapshot.tree
        let maxDepth = params["max_depth"]?.int ?? .max
        let frames = params["frames"]?.bool ?? false
        let interactiveOnly = params["interactive_only"]?.bool ?? false
        var lines = [header(for: snapshot)]
        let limit = 2000
        var shown = 0
        for node in tree.nodes where node.depth <= maxDepth {
            if interactiveOnly, node.id != 0, !node.hasSelector, ![.control, .input, .link].contains(node.kind.category) { continue }
            if shown == limit {
                lines.append("… \(tree.nodes.count - limit) more. Use max_depth, interactive_only or find_elements.")
                break
            }
            lines.append(String(repeating: "  ", count: node.depth) + describe(node, frames: frames))
            shown += 1
        }
        return [
            "text": .string(lines.joined(separator: "\n")),
            "snapshotId": .number(Double(snapshot.id)),
            "elementCount": .number(Double(tree.nodes.count)),
            "bundleId": .string(tree.bundleID ?? ""),
            "window": .string(snapshot.target.title ?? ""),
        ]
    }

    /// First line of scan results: which app (and which copy of it), which window, and how big the tree is.
    private func header(for snapshot: Snapshot) -> String {
        let app = NSRunningApplication(processIdentifier: snapshot.tree.pid)
        let copies = snapshot.tree.bundleID.map { NSRunningApplication.runningApplications(withBundleIdentifier: $0).count } ?? 1
        var header = "\(snapshot.tree.appName) (\(snapshot.tree.bundleID ?? "?")) — window “\(snapshot.target.title ?? "")” — snapshot \(snapshot.id), \(snapshot.tree.nodes.count) elements"
        if let path = app?.bundleURL?.path { header += "\nApp: \(path)" }
        if copies > 1 { header += "\nWarning: \(copies) copies of this app are running; this is the one whose window is in front." }
        return header
    }

    /// One line per element: `e12 Button id=save "Save" value=… [disabled]`.
    private func describe(_ node: UINode, frames: Bool = false) -> String {
        var parts = ["e\(node.id)", node.kind.displayName]
        if let identifier = node.identifier.nonEmpty { parts.append("id=\(identifier)") }
        if let title = node.title.nonEmpty { parts.append("title=\(Self.quote(title))") }
        if let label = node.label.nonEmpty, label != node.title { parts.append("label=\(Self.quote(label))") }
        if let value = node.value.nonEmpty { parts.append("value=\(Self.quote(String(value.prefix(80))))") }
        if let placeholder = node.placeholder.nonEmpty { parts.append("placeholder=\(Self.quote(placeholder))") }
        if node.isEnabled == false { parts.append("[disabled]") }
        if frames, let frame = node.frame {
            parts.append("@\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
        }
        return parts.joined(separator: " ")
    }

    private static func quote(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\n", with: "⏎") + "\""
    }

    private func findElements(_ params: [String: JSONValue]) async throws -> JSONValue {
        let snapshot = try await scan(params)
        let tree = snapshot.tree
        let text = params["text"]?.string?.lowercased()
        let kind = params["kind"]?.string?.lowercased()
        let identifier = params["identifier"]?.string
        let limit = params["limit"]?.int ?? 25
        let matches = tree.nodes.filter { node in
            if let identifier, node.identifier != identifier { return false }
            if let kind, ![node.kind.typeName, node.kind.queryName, node.kind.displayName, node.role ?? ""]
                .contains(where: { $0.lowercased().replacingOccurrences(of: " ", with: "") == kind.replacingOccurrences(of: " ", with: "") }) { return false }
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

    /// The element named by `element` (a ref into the app's latest snapshot) or `query` (resolved on a fresh scan).
    private func target(_ params: [String: JSONValue], required: Bool = true) async throws -> Target? {
        if let ref = params["element"]?.string, !ref.isEmpty {
            let app = try resolveApp(params)
            guard let bundleID = app.bundleIdentifier, let snapshot = snapshots[bundleID] else {
                throw Failure(code: "noSnapshot", message: "Take a snapshot (or find_elements) of this app first; refs like \(ref) come from it.")
            }
            guard ref.hasPrefix("e"), let id = Int(ref.dropFirst()), snapshot.tree.nodes.indices.contains(id) else {
                throw Failure(code: "elementNotFound", message: "No element \(ref) in snapshot \(snapshot.id).")
            }
            let builder = QueryBuilder(tree: snapshot.tree, includeAppDeclaration: false)
            return Target(snapshot: snapshot, nodeID: id, query: builder.bestQuery(for: id))
        }
        if let query = params["query"]?.string, !query.isEmpty {
            let steps = try parse(query)
            let snapshot = try await scan(params)
            let resolution = QueryResolver(tree: snapshot.tree).resolve(steps)
            guard let first = resolution.matches.first else {
                throw Failure(code: "elementNotFound", message: "No element matches \(query). Use resolve_query to see why.")
            }
            return Target(snapshot: snapshot, nodeID: first, query: Self.trimmed(query))
        }
        if required { throw Failure(code: "invalidParams", message: "Pass element (a ref like e12) or query.") }
        return nil
    }

    private func parse(_ query: String) throws -> [QueryResolver.Step] {
        do {
            return try QueryResolver.parse(query)
        } catch {
            throw Failure(code: "invalidQuery", message: error.localizedDescription)
        }
    }

    /// The query part of an expression an agent passed in, without a trailing `.click()` or similar.
    private static func trimmed(_ query: String) -> String {
        guard let steps = try? QueryResolver.parse(query) else { return query }
        return "app" + steps.map(\.source).joined()
    }

    private func liveFrame(_ target: Target) -> CGRect? {
        target.element?.frame ?? target.node.frame
    }

    private func record(_ step: TestComposer.Step, bundleID: String?) -> String {
        let line = TestComposer.line(for: step)
        if recording != nil, recording?.bundleID == bundleID {
            recording?.steps.append(step)
        }
        return line
    }

    private func actionResult(_ summary: String, code: String) -> JSONValue {
        let recorded = recording.map { " (recorded as step \($0.steps.count))" } ?? ""
        return ["text": .string("\(summary)\nXCUITest\(recorded): \(code)"), "code": .string(code)]
    }

    // MARK: - Actions

    private func click(_ params: [String: JSONValue]) async throws -> JSONValue {
        try requireAccessibility()
        guard let target = try await target(params) else { return .null }
        let method = params["method"]?.string ?? "auto"
        let element = target.element
        let rowKinds: Set<String> = ["outlineRow", "tableRow", "cell"]
        var how = "mouse click"
        var pressed = false
        if method != "mouse", let element, !rowKinds.contains(target.node.kind.typeName) || method == "press",
           InputSynthesizer.actions(of: element).contains(kAXPressAction as String) {
            pressed = InputSynthesizer.perform(kAXPressAction, on: element)
            how = "AXPress"
        }
        if !pressed {
            if method == "press" { throw Failure(code: "actionFailed", message: "\(describe(target.node)) doesn't support AXPress. Try method mouse.") }
            guard let frame = liveFrame(target), frame.width > 0, frame.height > 0 else {
                throw Failure(code: "actionFailed", message: "\(describe(target.node)) has no frame to click.")
            }
            await InputSynthesizer.bringForward(pid: target.snapshot.tree.pid, window: target.snapshot.elements[0])
            await InputSynthesizer.click(at: CGPoint(x: frame.midX, y: frame.midY))
            how = "mouse click"
        }
        try? await Task.sleep(for: .milliseconds(300)) // let the UI respond before the agent looks again
        let code = record(.init(query: target.query, action: .click), bundleID: target.snapshot.tree.bundleID)
        return actionResult("Clicked \(describe(target.node)) (\(how)). Take a new snapshot to see the result.", code: code)
    }

    private func typeText(_ params: [String: JSONValue]) async throws -> JSONValue {
        try requireAccessibility()
        guard let text = params["text"]?.string else { throw Failure(code: "invalidParams", message: "type_text needs text.") }
        let target = try await target(params, required: false)
        let app = try target.map { NSRunningApplication(processIdentifier: $0.snapshot.tree.pid) } ?? resolveApp(params)
        guard let pid = app?.processIdentifier else { throw Failure(code: "noApp", message: "The app isn't running.") }

        await InputSynthesizer.bringForward(pid: pid, window: target?.snapshot.elements[0])
        if let target {
            // Focus it the way a click would; fall back to a real click for fields that ignore AXFocused.
            let focused = target.element.map(InputSynthesizer.focus) ?? false
            if !focused, let frame = liveFrame(target) {
                await InputSynthesizer.click(at: CGPoint(x: frame.midX, y: frame.midY))
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        if params["clear"]?.bool == true, let selectAll = InputSynthesizer.key(named: "a"), let delete = InputSynthesizer.key(named: "delete") {
            await InputSynthesizer.press(selectAll, modifiers: ["command"])
            await InputSynthesizer.press(delete, modifiers: [])
        }
        await InputSynthesizer.type(text)

        let bundleID = target?.snapshot.tree.bundleID ?? app?.bundleIdentifier
        var code = record(.init(query: target?.query, action: .typeText(text)), bundleID: bundleID)
        if params["clear"]?.bool == true {
            code = "// cleared the field first (⌘A, delete)\n" + code
        }
        let into = target.map { " into \(describe($0.node))" } ?? ""
        return actionResult("Typed \(Self.quote(text))\(into).", code: code)
    }

    private func pressKey(_ params: [String: JSONValue]) async throws -> JSONValue {
        try requireAccessibility()
        guard let name = params["key"]?.string, let key = InputSynthesizer.key(named: name) else {
            throw Failure(code: "invalidParams", message: "Unknown key \(params["key"]?.string ?? "(none)"). Use return, escape, tab, delete, space, up, down, left, right, home, end, pageUp, pageDown or one character.")
        }
        guard let modifiers = InputSynthesizer.parseModifiers(params["modifiers"]?.string) else {
            throw Failure(code: "invalidParams", message: "Modifiers must be command, shift, option or control.")
        }
        let app = try resolveApp(params)
        await InputSynthesizer.bringForward(pid: app.processIdentifier, window: nil)
        await InputSynthesizer.press(key, modifiers: modifiers)
        try? await Task.sleep(for: .milliseconds(200))
        let code = record(.init(query: nil, action: .typeKey(key: key.xcuiName, modifiers: modifiers)), bundleID: app.bundleIdentifier)
        let combo = (modifiers + [name]).joined(separator: "+")
        return actionResult("Pressed \(combo) in \(app.localizedName ?? "the app").", code: code)
    }

    private func scroll(_ params: [String: JSONValue]) async throws -> JSONValue {
        try requireAccessibility()
        let target = try await target(params, required: false)
        let snapshot: Snapshot
        if let target { snapshot = target.snapshot } else { snapshot = try await scan(params) }
        guard let frame = target.flatMap(liveFrame) ?? snapshot.target.bounds as CGRect? else {
            throw Failure(code: "actionFailed", message: "Nothing to scroll.")
        }
        let amount = Int32(params["amount"]?.int ?? 5)
        let direction = params["direction"]?.string ?? "down"
        let (dx, dy): (Int32, Int32) = switch direction {
        case "up": (0, amount)
        case "left": (amount, 0)
        case "right": (-amount, 0)
        default: (0, -amount)
        }
        await InputSynthesizer.bringForward(pid: snapshot.tree.pid, window: snapshot.elements[0])
        await InputSynthesizer.scroll(at: CGPoint(x: frame.midX, y: frame.midY), dx: dx, dy: dy)
        let what = target.map { describe($0.node) } ?? "the window"
        return ["text": .string("Scrolled \(what) \(direction) by \(amount). XCUITest scrolls to elements automatically when clicking them, so this isn't recorded.")]
    }

    private func waitFor(_ params: [String: JSONValue]) async throws -> JSONValue {
        try requireAccessibility()
        let query = params["query"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let text = params["text"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        guard query != nil || text != nil else { throw Failure(code: "invalidParams", message: "wait_for needs query or text.") }
        let steps = try query.map(parse)
        let timeout = params["timeout"]?.double ?? 5
        let gone = params["gone"]?.bool ?? false
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            let snapshot = try await scan(params)
            let found: Int? = if let steps {
                QueryResolver(tree: snapshot.tree).resolve(steps).matches.first
            } else {
                snapshot.tree.nodes.first { node in
                    [node.identifier, node.title, node.label, node.value].contains { $0?.localizedCaseInsensitiveContains(text!) == true }
                }?.id
            }
            if (found != nil) != gone {
                let builder = QueryBuilder(tree: snapshot.tree, includeAppDeclaration: false)
                let recordedQuery = query.map(Self.trimmed)
                    ?? found.map { builder.bestQuery(for: $0) }
                    ?? "app.descendants(matching: .any).matching(NSPredicate(format: \(QueryBuilder.literal("label CONTAINS " + Self.predicateLiteral(text!))))).firstMatch"
                let code = record(.init(query: recordedQuery, action: gone ? .assertGone(timeout: timeout) : .assertExists(timeout: timeout)),
                                  bundleID: snapshot.tree.bundleID)
                let what = found.map { describe(snapshot.tree.node($0)) } ?? (query ?? text!)
                return actionResult(gone ? "\(what) is gone." : "Found \(what).", code: code)
            }
            if Date() >= deadline {
                throw Failure(code: "timeout", message: "\(query ?? "“\(text!)”") \(gone ? "was still there" : "didn't appear") after \(timeout)s." + (query != nil && !gone ? " Use resolve_query to see why." : ""))
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    private static func predicateLiteral(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    // MARK: - Inspection

    private func screenshot(_ params: [String: JSONValue]) async throws -> JSONValue {
        permissions.refresh()
        guard permissions.screenRecordingGranted else {
            throw Failure(code: "permissionDenied", message: "Xamine needs Screen Recording permission for screenshots (System Settings › Privacy & Security › Screen & System Audio Recording).")
        }
        let target = try await target(params, required: false)
        let window: PickedWindow
        if let target {
            window = target.snapshot.target
        } else {
            let app = try resolveApp(params)
            guard let bundleID = app.bundleIdentifier, let front = WindowLocator.frontWindow(of: bundleID) else {
                throw Failure(code: "noWindow", message: "\(app.localizedName ?? "The app") has no on-screen window.")
            }
            window = front
        }
        var picked = window
        if let bounds = WindowLocator.frontWindow(of: window.bundleID ?? "")?.bounds, WindowLocator.frontWindow(of: window.bundleID ?? "")?.windowID == window.windowID {
            picked.bounds = bounds
        }
        let capture: WindowCapture.Result
        do {
            capture = try await WindowCapture.capture(picked)
        } catch {
            throw Failure(code: "captureFailed", message: error.localizedDescription)
        }
        var image = capture.image
        var described = "window “\(picked.title ?? "")”"
        if let target, let frame = liveFrame(target) {
            let scale = CGFloat(image.width) / capture.frame.width
            let local = frame.offsetBy(dx: -capture.frame.minX, dy: -capture.frame.minY).insetBy(dx: -8, dy: -8)
            let pixels = CGRect(x: local.minX * scale, y: local.minY * scale, width: local.width * scale, height: local.height * scale)
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if !pixels.isEmpty, let cropped = image.cropping(to: pixels.integral) { image = cropped }
            described = describe(target.node)
        }
        guard let png = Self.pngData(image) else { throw Failure(code: "captureFailed", message: "Couldn't encode the screenshot.") }
        return ["text": .string("Screenshot of \(described), \(image.width)×\(image.height) px."), "png": .string(png.base64EncodedString())]
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private func getQueries(_ params: [String: JSONValue]) async throws -> JSONValue {
        guard let target = try await target(params) else { return .null }
        let tree = target.snapshot.tree
        let builder = QueryBuilder(tree: tree, includeAppDeclaration: false)
        let queries = builder.queries(for: target.nodeID)
        var lines = ["\(describe(target.node))", "Path: \(queries.breadcrumb)", "", "Best: \(builder.bestQuery(for: target.nodeID))"]
        func add(_ title: String, _ snippet: Snippet?) {
            guard let snippet else { return }
            lines.append("")
            lines.append("\(title):\n\(snippet.code)")
            if let note = snippet.note { lines.append("  (\(note))") }
        }
        add("By identifier", queries.byIdentifier)
        add("From anchor", queries.fromAnchor)
        if queries.hasUniqueContainer { add("From container", queries.fromContainer) }
        add("By hierarchy (text-free)", queries.byHierarchy)
        return [
            "text": .string(lines.joined(separator: "\n")),
            "best": .string(builder.bestQuery(for: target.nodeID)),
            "byIdentifier": queries.byIdentifier.map { .string($0.code) } ?? .null,
            "byHierarchy": .string(queries.byHierarchy.code),
        ]
    }

    private func resolveQuery(_ params: [String: JSONValue]) async throws -> JSONValue {
        guard let query = params["query"]?.string, !query.isEmpty else { throw Failure(code: "invalidParams", message: "resolve_query needs query.") }
        let steps = try parse(query)
        let snapshot = try await scan(params)
        let tree = snapshot.tree
        let resolver = QueryResolver(tree: tree)
        let resolution = resolver.resolve(steps)
        let builder = QueryBuilder(tree: tree, includeAppDeclaration: false)

        var lines = [
            "Query: app" + steps.map(\.source).joined(),
            "Searched: \(header(for: snapshot)) (front window only)",
        ]
        lines.append("")
        lines.append("Step by step:")
        let width = (steps.map(\.source.count).max() ?? 0) + 2
        for (index, step) in steps.enumerated() {
            let count = resolution.counts[index]
            let marker = index == resolution.failedStep ? "   ← stops matching here" : ""
            lines.append("  \(index + 1). \(step.source.padding(toLength: width, withPad: " ", startingAt: 0))→ \(count) element\(count == 1 ? "" : "s")\(marker)")
        }
        lines.append("")

        var candidates: [JSONValue] = []
        if !resolution.matches.isEmpty {
            let count = resolution.matches.count
            lines.append("Result: \(count) match\(count == 1 ? "" : "es").")
            if count > 1, steps.last.map({ ![.firstMatch, .element].contains($0.operation) && !Self.isBoundBy($0.operation) }) ?? true {
                lines.append("Note: interacting with this query raises “multiple matching elements”; add .firstMatch or .element(boundBy:).")
            }
            for id in resolution.matches.prefix(10) {
                lines.append("  \(describe(tree.node(id)))")
            }
        } else if let failed = resolution.failedStep {
            lines.append("Result: no match. Step \(failed + 1) (\(steps[failed].source)) found nothing.")
            let key = steps[failed].operation.key ?? steps[(failed + 1)...].lazy.compactMap(\.operation.key).first
            func score(_ id: Int) -> Double {
                guard let key else { return 0 }
                let node = tree.node(id)
                let fields = [node.identifier, node.title, node.label, node.value, node.placeholder].compactMap(\.nonEmpty)
                return fields.map { QueryResolver.similarity(key, $0) }.max() ?? 0
            }
            func add(_ id: Int) {
                let node = tree.node(id)
                let best = builder.bestQuery(for: id).replacingOccurrences(of: "\n    ", with: "")
                let free = textFreeQuery(for: id, builder: builder)
                lines.append("  \(describe(node))\(key != nil ? String(format: "  (similarity %.2f)", score(id)) : "")")
                lines.append("    query:     \(best)")
                lines.append("    text-free: \(free)")
                candidates.append(["ref": .string("e\(id)"), "query": .string(best), "textFree": .string(free), "similarity": .number(score(id))])
            }

            // What the failing step chose from: the same kind of element in the same place, which is usually the one
            // whose text changed.
            let pool = resolver.candidates(before: failed, in: steps).filter { $0 >= 0 }.sorted { score($0) > score($1) }
            if !pool.isEmpty {
                lines.append("")
                lines.append("Step \(failed + 1) had \(pool.count) element\(pool.count == 1 ? "" : "s") to choose from\(pool.count > 5 ? " (closest 5)" : ""):")
                pool.prefix(5).forEach(add)
            }
            // The text may also have moved to another element or type.
            if let key {
                let shown = Set(pool.prefix(5))
                let elsewhere = tree.nodes.map(\.id).filter { !shown.contains($0) && score($0) > 0.3 }.sorted { score($0) > score($1) }.prefix(3)
                if !elsewhere.isEmpty {
                    lines.append("")
                    lines.append("Similar text elsewhere in the window:")
                    elsewhere.forEach(add)
                }
            }
            if let first = pool.first, tree.node(first).kind.typeName == "window" {
                lines.append("")
                lines.append("Window titles come from the app's navigation title. To check that a title appears without pinning its text: XCTAssertFalse(app.windows.firstMatch.title.isEmpty)")
            }
        }
        return [
            "text": .string(lines.joined(separator: "\n")),
            "matchCount": .number(Double(resolution.matches.count)),
            "failedStep": resolution.failedStep.map { .number(Double($0 + 1)) } ?? .null,
            "matches": .array(resolution.matches.prefix(10).map { .string("e\($0)") }),
            "candidates": .array(candidates),
        ]
    }

    /// A query that finds the element by type and position only, so copy changes don't break it: from the closest
    /// unique container if there is one, otherwise the full path.
    private func textFreeQuery(for id: Int, builder: QueryBuilder) -> String {
        let queries = builder.queries(for: id)
        if builder.tree.node(id).kind.typeName == "window" { return "app.windows.firstMatch" }
        return (queries.hasUniqueContainer ? queries.fromContainer : queries.byHierarchy).code.replacingOccurrences(of: "\n    ", with: "")
    }

    private static func isBoundBy(_ operation: QueryResolver.Operation) -> Bool {
        if case .boundBy = operation { return true }
        return false
    }

    // MARK: - Recording

    private func recordingStart(_ params: [String: JSONValue]) throws -> JSONValue {
        let app = try resolveApp(params)
        guard let bundleID = app.bundleIdentifier else { throw Failure(code: "noApp", message: "The app has no bundle ID.") }
        let composer = TestComposer(name: params["name"]?.string ?? app.localizedName ?? "Recorded", bundleID: bundleID)
        recording = composer
        return ["text": .string("Recording \(composer.name)Tests for \(bundleID). Clicks, typing, keys and wait_for are added until recording_stop.")]
    }

    private func recordingStop() throws -> JSONValue {
        guard let composer = recording else { throw Failure(code: "notRecording", message: "Nothing is being recorded. Call recording_start first.") }
        recording = nil
        let source = composer.source()
        let fileName = "\(composer.name)Tests.swift"
        return [
            "text": .string("// \(fileName) — \(composer.steps.count) recorded steps\n\(source)"),
            "source": .string(source),
            "fileName": .string(fileName),
        ]
    }
}

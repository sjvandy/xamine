#if DEBUG
import AppKit

/// Debug-only: `open -n Xamine.app --args --dump <bundle id> <output path>` scans that app's frontmost
/// window and writes the tree as indented text, then quits. Runs under xamine's own Accessibility permission.
enum DebugDump {
    @MainActor
    static func runIfRequested() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--dump"), args.count > index + 2 else { return false }
        let bundleID = args[index + 1]
        let output = URL(fileURLWithPath: args[index + 2])
        // `--dump at <x> <y> <path>` scans whatever is at that screen point instead, like the hands-off picker.
        let atPoint: CGPoint? = bundleID == "at" && args.count > index + 4
            ? CGPoint(x: Double(args[index + 2]) ?? 0, y: Double(args[index + 3]) ?? 0) : nil
        let outputURL = atPoint == nil ? output : URL(fileURLWithPath: args[index + 4])

        // `--dump device <bundle id> <path>` reads that app through an agent running on a simulator.
        if bundleID == "device", args.count > index + 3 {
            let app = args[index + 2]
            let path = URL(fileURLWithPath: args[index + 3])
            Task {
                var text = ""
                do {
                    let client = AgentClient(host: "127.0.0.1")
                    let tree = try await client.tree(bundleID: app).makeTree(appName: app, bundleID: app)
                    let image = try await client.screenshot()
                    let builder = QueryBuilder(tree: tree, includeAppDeclaration: false)
                    text += "nodes: \(tree.nodes.count) screen: \(tree.windowFrame) screenshot: \(image.width)x\(image.height)\n"
                    for node in tree.nodes where node.hasSelector {
                        let queries = builder.queries(for: node.id)
                        text += "\(node.kind.displayName) \(node.bestKey ?? "")\n  \(queries.byIdentifier?.code ?? "-")\n  \(queries.fromContainer.code.replacingOccurrences(of: "\n", with: " "))\n"
                    }
                } catch {
                    text = "error: \(error.localizedDescription)\n"
                }
                try? text.write(to: path, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
            return true
        }

        Task {
            var text = ""
            let target = atPoint.map {
                PickedWindow(pid: 0, windowID: 0, bounds: CGRect(origin: .zero, size: CGSize(width: 1, height: 1)),
                             appName: "?", layer: 1, anchor: $0)
            } ?? frontWindow(of: bundleID)
            if let target {
                do {
                    let start = Date()
                    let tree = try await HierarchyScanner.scan(target)
                    text += "app: \(tree.appName) \(tree.bundleID ?? "")\n"
                    text += "nodes: \(tree.nodes.count) in \(String(format: "%.2f", Date().timeIntervalSince(start)))s\n"
                    for node in tree.nodes {
                        let attrs = [
                            node.subrole, node.identifier.map { "id=\($0)" }, node.title.map { "title=\($0)" },
                            node.label.map { "label=\($0)" }, node.value.map { "value=\($0.prefix(40))" },
                            node.frame.map { "frame=\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" },
                        ].compactMap { $0 }.joined(separator: " ")
                        text += String(repeating: "  ", count: node.depth) + "\(node.role ?? "?") \(attrs)\n"
                    }
                } catch {
                    text = "error: \(error.localizedDescription)\n"
                }
            } else {
                text = "no window for \(bundleID)\n"
            }
            try? text.write(to: outputURL, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
        return true
    }

    private static func frontWindow(of bundleID: String) -> PickedWindow? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }),
              let id = info[kCGWindowNumber as String] as? CGWindowID,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict)
        else { return nil }
        return PickedWindow(pid: app.processIdentifier, windowID: id, bounds: bounds, appName: app.localizedName ?? bundleID,
                            bundleID: bundleID, title: info[kCGWindowName as String] as? String)
    }
}
#endif

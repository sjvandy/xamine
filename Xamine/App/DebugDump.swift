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

        Task {
            var text = ""
            if let target = frontWindow(of: bundleID) {
                do {
                    let start = Date()
                    let tree = try await HierarchyScanner.scan(target)
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
            try? text.write(to: output, atomically: true, encoding: .utf8)
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

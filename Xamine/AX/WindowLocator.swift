import AppKit

/// Finds an app's windows without the picker, for scripted inspection.
enum WindowLocator {
    /// The app's frontmost normal window, or the first whose title contains `title`. When several copies of the app
    /// are running (say, builds from two folders), looks at all of them.
    static func frontWindow(of bundleID: String, title: String? = nil) -> PickedWindow? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        return windows(of: apps).first { window in
            guard let title, !title.isEmpty else { return true }
            return window.title?.localizedCaseInsensitiveContains(title) == true
        }
    }

    /// The app's on-screen normal windows, front to back.
    static func windows(of app: NSRunningApplication) -> [PickedWindow] {
        windows(of: [app])
    }

    private static func windows(of apps: [NSRunningApplication]) -> [PickedWindow] {
        let byPID = Dictionary(apps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        guard !byPID.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, let app = byPID[pid],
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 1, bounds.height > 1 else { return nil }
            return PickedWindow(pid: app.processIdentifier, windowID: id, bounds: bounds,
                                appName: app.localizedName ?? app.bundleIdentifier ?? "?",
                                bundleID: app.bundleIdentifier, title: info[kCGWindowName as String] as? String)
        }
    }

    /// Polls until the app has a window, for just after launching it.
    static func waitForWindow(of bundleID: String, title: String? = nil, timeout: Duration = .seconds(10)) async -> PickedWindow? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let window = frontWindow(of: bundleID, title: title) { return window }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return frontWindow(of: bundleID, title: title)
    }
}

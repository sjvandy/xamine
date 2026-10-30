import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case windowNotShareable

    var errorDescription: String? {
        "That window can't be captured. Check that xamine has Screen Recording permission."
    }
}

/// Captures what was picked: a single app window on its own, or the screen region under system UI.
enum WindowCapture {
    static func capture(_ target: PickedWindow) async throws -> CGImage {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if target.isAppWindow, let window = content.windows.first(where: { $0.windowID == target.windowID }) {
                Log.capture.notice("capturing window \(target.windowID)")
                return try await capture(window: window)
            }
            Log.capture.notice("capturing region \(String(describing: target.bounds), privacy: .public) desktopOnly=\(target.isDesktop)")
            return try await capture(region: target.bounds, desktopOnly: target.isDesktop, from: content)
        } catch {
            Log.capture.error("capture failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// One window, independent of what overlaps it.
    private static func capture(window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// A region of the display, as it appears on screen minus xamine's own windows. System UI such as
    /// Control Center is often several windows composited together, so a region captures it as seen.
    /// For the desktop, only desktop-level windows (wallpaper, icons, widgets) are included.
    private static func capture(region: CGRect, desktopOnly: Bool, from content: SCShareableContent) async throws -> CGImage {
        guard let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: region.midX, y: region.midY)) })
            ?? content.displays.first else { throw CaptureError.windowNotShareable }

        let filter: SCContentFilter
        if desktopOnly {
            let desktopWindows = content.windows.filter { $0.windowLayer < 0 }
            filter = SCContentFilter(display: display, including: desktopWindows)
        } else {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let ourApps = content.applications.filter { $0.processID == ownPID }
            filter = SCContentFilter(display: display, excludingApplications: ourApps, exceptingWindows: [])
        }

        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let local = region.intersection(display.frame).offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.sourceRect = local
        config.width = Int(local.width * scale)
        config.height = Int(local.height * scale)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

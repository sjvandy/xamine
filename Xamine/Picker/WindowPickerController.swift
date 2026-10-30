import AppKit

/// A ⌘⇧5-style picker: covers every screen, highlights the window under the cursor, and reports the one clicked.
@MainActor
final class WindowPickerController {
    struct Candidate {
        let window: PickedWindow
        let icon: NSImage?
    }

    private var panels: [PickerPanel] = []
    private var candidates: [Candidate] = []
    private var hidden: [NSWindow] = []
    private var completion: ((PickedWindow?) -> Void)?
    private(set) var hovered: Candidate?

    var isActive: Bool { completion != nil }

    func start(completion: @escaping (PickedWindow?) -> Void) {
        guard !isActive else { return }
        self.completion = completion

        // Hide our own windows so they don't cover what the user wants to pick.
        hidden = NSApp.windows.filter { $0.isVisible && !($0 is PickerPanel) && $0.level == .normal }
        hidden.forEach { $0.orderOut(nil) }

        candidates = Self.onScreenWindows()
        panels = NSScreen.screens.map { screen in
            let panel = PickerPanel(screen: screen, controller: self)
            panel.orderFrontRegardless()
            return panel
        }
        NSApp.activate(ignoringOtherApps: true)
        panels.first { $0.screen == NSScreen.main }?.makeKey()
        PickerPanel.cursor.set()
        updateHover()
    }

    func updateHover() {
        let point = Self.cgPoint(fromCocoa: NSEvent.mouseLocation)
        let next = candidates.first { $0.window.bounds.contains(point) }
        guard next?.window != hovered?.window else { return }
        hovered = next
        panels.forEach { $0.contentView?.needsDisplay = true }
    }

    func finish(selecting: Bool) {
        let result = selecting ? hovered?.window : nil
        panels.forEach { $0.orderOut(nil) }
        panels = []
        candidates = []
        hovered = nil
        NSCursor.arrow.set()
        if result == nil { hidden.forEach { $0.orderFront(nil) } }
        hidden = []
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }

    // MARK: - Window list

    /// Normal app windows, front to back, excluding xamine's own.
    private static func onScreenWindows() -> [Candidate] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 40, bounds.height > 40,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { return nil }
            let app = NSRunningApplication(processIdentifier: pid)
            let window = PickedWindow(
                pid: pid,
                windowID: id,
                bounds: bounds,
                appName: app?.localizedName ?? info[kCGWindowOwnerName as String] as? String ?? "Unknown",
                bundleID: app?.bundleIdentifier,
                title: info[kCGWindowName as String] as? String
            )
            return Candidate(window: window, icon: app?.icon)
        }
    }

    // MARK: - Coordinates

    /// Height of the primary screen, which anchors both coordinate systems.
    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func cgPoint(fromCocoa point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func cocoaRect(fromCG rect: CGRect) -> NSRect {
        NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// A transparent full-screen panel that draws the highlight and forwards mouse/keyboard input.
final class PickerPanel: NSPanel {
    static let cursor: NSCursor = {
        let config = NSImage.SymbolConfiguration(pointSize: 26, weight: .medium)
            .applying(.init(paletteColors: [.white]))
        let symbol = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
        let size = NSSize(width: symbol.size.width + 4, height: symbol.size.height + 4)
        // Draw a dark outline under the white glyph so the cursor reads on any background.
        let image = NSImage(size: size, flipped: false) { rect in
            let shadow = NSShadow()
            shadow.shadowColor = .black.withAlphaComponent(0.8)
            shadow.shadowBlurRadius = 2
            shadow.set()
            symbol.draw(in: rect.insetBy(dx: 2, dy: 2))
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }()

    init(screen: NSScreen, controller: WindowPickerController) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = PickerOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), controller: controller)
    }

    override var canBecomeKey: Bool { true }
}

private final class PickerOverlayView: NSView {
    private weak var controller: WindowPickerController?

    init(frame: NSRect, controller: WindowPickerController) {
        self.controller = controller
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .cursorUpdate, .inVisibleRect], owner: self))
    }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: PickerPanel.cursor) }
    override func cursorUpdate(with event: NSEvent) { PickerPanel.cursor.set() }
    override func mouseMoved(with event: NSEvent) {
        PickerPanel.cursor.set()
        controller?.updateHover()
    }
    override func mouseDown(with event: NSEvent) {
        controller?.updateHover()
        controller?.finish(selecting: controller?.hovered != nil)
    }
    override func rightMouseDown(with event: NSEvent) { controller?.finish(selecting: false) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { controller?.finish(selecting: false) } // Escape
    }
    override func cancelOperation(_ sender: Any?) { controller?.finish(selecting: false) }

    override func draw(_ dirtyRect: NSRect) {
        guard let window, let screen = window.screen else { return }

        guard let hovered = controller?.hovered else {
            drawHint("Click a window to inspect it  ·  Esc to cancel", in: bounds)
            return
        }

        let global = WindowPickerController.cocoaRect(fromCG: hovered.window.bounds)
        let rect = global.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        guard rect.intersects(bounds) else { return }

        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 3
        path.stroke()

        drawBadge(for: hovered, centeredIn: rect.intersection(bounds))
    }

    private func drawBadge(for candidate: WindowPickerController.Candidate, centeredIn rect: NSRect) {
        let title = NSAttributedString(string: candidate.window.appName, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        let subtitle = NSAttributedString(string: candidate.window.title.nonEmpty ?? "Click to inspect", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white.withAlphaComponent(0.8),
        ])
        let iconSize: CGFloat = 40
        let textWidth = min(max(title.size().width, subtitle.size().width), 320)
        let badge = NSRect(x: 0, y: 0, width: iconSize + textWidth + 36, height: iconSize + 20)
            .offsetBy(dx: rect.midX - (iconSize + textWidth + 36) / 2, dy: rect.midY - (iconSize + 20) / 2)

        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 12, yRadius: 12).fill()
        candidate.icon?.draw(in: NSRect(x: badge.minX + 12, y: badge.minY + 10, width: iconSize, height: iconSize))
        let textX = badge.minX + iconSize + 24
        title.draw(with: NSRect(x: textX, y: badge.midY + 1, width: textWidth, height: 20), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
        subtitle.draw(with: NSRect(x: textX, y: badge.midY - 17, width: textWidth, height: 16), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
    }

    private func drawHint(_ text: String, in rect: NSRect) {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white,
        ])
        let size = string.size()
        let pill = NSRect(x: rect.midX - size.width / 2 - 16, y: rect.minY + 60, width: size.width + 32, height: size.height + 16)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        string.draw(at: NSPoint(x: pill.minX + 16, y: pill.minY + 8))
    }
}

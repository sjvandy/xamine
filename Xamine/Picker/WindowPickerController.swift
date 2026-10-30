import AppKit

/// A ⌘⇧5-style picker: covers every screen, highlights the window under the cursor, and reports the one picked.
///
/// Two modes:
/// - **Click** (`start`): xamine takes focus and the user clicks a window. Works for app windows, the Dock, the menu bar and the desktop.
/// - **Hands-off** (`startHandsOff`): the overlay never takes focus or mouse events, so transient system UI like Spotlight,
///   Control Center or an open menu stays open. Whatever is under the cursor is picked when the countdown ends
///   (or immediately with no countdown).
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
    private var trackingTimer: Timer?
    private(set) var hovered: Candidate?
    private(set) var isHandsOff = false
    private(set) var secondsRemaining = 0

    var isActive: Bool { completion != nil }

    // MARK: - Click mode

    func start(completion: @escaping (PickedWindow?) -> Void) {
        guard !isActive else { return }
        begin(handsOff: false, completion: completion)
        NSApp.activate(ignoringOtherApps: true)
        panels.first { $0.screen == NSScreen.main }?.makeKey()
        PickerPanel.cursor.set()
        updateHover()
    }

    // MARK: - Hands-off mode

    /// Picks what's under the cursor after `delay` seconds (0 = right away) without taking focus.
    func startHandsOff(delay: Int, completion: @escaping (PickedWindow?) -> Void) {
        if isActive {
            // Pressing the shortcut again during a countdown picks immediately.
            if isHandsOff { finish(selecting: true) }
            return
        }
        guard delay > 0 else {
            self.completion = completion
            candidates = Self.onScreenWindows()
            updateHover()
            finish(selecting: true)
            return
        }
        begin(handsOff: true, completion: completion)
        secondsRemaining = delay
        updateHover()

        // The overlay ignores the mouse, so poll the cursor position instead.
        var ticks = 0
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                ticks += 1
                if ticks % 20 == 0 {
                    self.secondsRemaining -= 1
                    self.redraw()
                }
                if self.secondsRemaining <= 0 {
                    self.finish(selecting: true)
                } else {
                    self.updateHover()
                }
            }
        }
    }

    // MARK: - Shared

    private func begin(handsOff: Bool, completion: @escaping (PickedWindow?) -> Void) {
        self.completion = completion
        isHandsOff = handsOff

        // Hide our own windows so they don't cover what the user wants to pick.
        hidden = NSApp.windows.filter { $0.isVisible && !($0 is PickerPanel) && $0.level == .normal }
        hidden.forEach { $0.orderOut(nil) }

        candidates = Self.onScreenWindows()
        panels = NSScreen.screens.map { screen in
            let panel = PickerPanel(screen: screen, controller: self, passive: handsOff)
            panel.orderFrontRegardless()
            return panel
        }
    }

    func updateHover() {
        let point = Self.cgPoint(fromCocoa: NSEvent.mouseLocation)
        let next = candidates.first { $0.window.bounds.contains(point) }.map { candidate in
            Candidate(window: candidate.window.anchored(at: point), icon: candidate.icon)
        } ?? Self.desktopCandidate(at: point)
        let changed = next?.window.windowID != hovered?.window.windowID || (next == nil) != (hovered == nil)
        hovered = next
        if changed { redraw() }
    }

    private func redraw() {
        panels.forEach { $0.contentView?.needsDisplay = true }
    }

    func finish(selecting: Bool) {
        if selecting { updateHover() }
        let result = selecting ? hovered?.window : nil
        trackingTimer?.invalidate()
        trackingTimer = nil
        panels.forEach { $0.orderOut(nil) }
        panels = []
        candidates = []
        hovered = nil
        isHandsOff = false
        NSCursor.arrow.set()
        if result == nil { hidden.forEach { $0.orderFront(nil) } }
        hidden = []
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }

    // MARK: - Window list

    /// Owners whose on-screen windows are backdrops rather than UI worth inspecting.
    private static let ignoredOwners: Set<String> = ["WindowManager", "Wallpaper", "Screenshot", "screencaptureui"]

    /// Everything above the desktop, front to back, excluding xamine's own windows: app windows plus system UI
    /// such as the menu bar, Dock, Spotlight, Control Center and open menus.
    private static func onScreenWindows() -> [Candidate] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 20, bounds.height > 16,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { return nil }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let name = info[kCGWindowName as String] as? String
            guard !ignoredOwners.contains(owner) else { return nil }
            // The only Window Server window worth picking is the menu bar; the real owner is resolved when scanning.
            if owner == "Window Server", name != "Menubar" { return nil }

            let app = NSRunningApplication(processIdentifier: pid)
            let window = PickedWindow(
                pid: pid,
                windowID: id,
                bounds: bounds,
                appName: owner == "Window Server" ? "Menu Bar" : app?.localizedName ?? owner,
                bundleID: app?.bundleIdentifier,
                title: name,
                layer: layer
            )
            return Candidate(window: window, icon: owner == "Window Server" ? NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: nil) : app?.icon)
        }
    }

    /// When nothing is above the cursor, pick the desktop (Finder's icons and widgets) on that screen.
    private static func desktopCandidate(at point: CGPoint) -> Candidate? {
        guard let screen = NSScreen.screens.first(where: { cgRect(fromCocoa: $0.frame).contains(point) }),
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        else { return nil }
        let window = PickedWindow(
            pid: finder.processIdentifier,
            windowID: 0,
            bounds: cgRect(fromCocoa: screen.frame),
            appName: "Desktop",
            bundleID: "com.apple.finder",
            title: screen.localizedName,
            layer: PickedWindow.desktopLayer,
            anchor: point
        )
        return Candidate(window: window, icon: NSImage(systemSymbolName: "menubar.dock.rectangle", accessibilityDescription: nil))
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

    static func cgRect(fromCocoa rect: NSRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// A transparent full-screen panel that draws the highlight and, in click mode, forwards mouse/keyboard input.
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

    private let passive: Bool

    init(screen: NSScreen, controller: WindowPickerController, passive: Bool) {
        self.passive = passive
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = passive
        acceptsMouseMovedEvents = !passive
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = PickerOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), controller: controller)
    }

    override var canBecomeKey: Bool { !passive }
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

    private var isPassive: Bool { controller?.isHandsOff == true }

    override func resetCursorRects() {
        if !isPassive { addCursorRect(bounds, cursor: PickerPanel.cursor) }
    }
    override func cursorUpdate(with event: NSEvent) {
        if !isPassive { PickerPanel.cursor.set() }
    }
    override func mouseMoved(with event: NSEvent) {
        PickerPanel.cursor.set()
        controller?.updateHover()
    }
    override func mouseDown(with event: NSEvent) {
        controller?.finish(selecting: true)
    }
    override func rightMouseDown(with event: NSEvent) { controller?.finish(selecting: false) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { controller?.finish(selecting: false) } // Escape
    }
    override func cancelOperation(_ sender: Any?) { controller?.finish(selecting: false) }

    override func draw(_ dirtyRect: NSRect) {
        guard let window, let screen = window.screen, let controller else { return }

        if controller.isHandsOff {
            drawHint("Inspecting what's under the cursor in \(controller.secondsRemaining)…  ·  ⌥⌘⇧X to pick now", in: bounds)
        }

        guard let hovered = controller.hovered else {
            if !controller.isHandsOff { drawHint("Click a window to inspect it  ·  Esc to cancel", in: bounds) }
            return
        }

        let global = WindowPickerController.cocoaRect(fromCG: hovered.window.bounds)
        let rect = global.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        guard rect.intersects(bounds) else { return }

        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), xRadius: 10, yRadius: 10)
        NSColor.controlAccentColor.withAlphaComponent(hovered.window.isDesktop ? 0.1 : 0.22).setFill()
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
        // Thin windows such as the menu bar get a compact badge below them.
        let compact = rect.height < 80
        let iconSize: CGFloat = compact ? 24 : 40
        let textWidth = min(max(title.size().width, subtitle.size().width), 320)
        let badgeSize = NSSize(width: iconSize + textWidth + 36, height: iconSize + 20)
        var origin = NSPoint(x: rect.midX - badgeSize.width / 2, y: rect.midY - badgeSize.height / 2)
        if compact { origin.y = max(rect.minY - badgeSize.height - 8, bounds.minY + 8) }
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - badgeSize.width - 8)
        let badge = NSRect(origin: origin, size: badgeSize)

        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 12, yRadius: 12).fill()
        candidate.icon?.draw(in: NSRect(x: badge.minX + 12, y: badge.minY + 10, width: iconSize, height: iconSize))
        let textX = badge.minX + iconSize + 24
        if compact {
            title.draw(with: NSRect(x: textX, y: badge.midY - 9, width: textWidth, height: 20), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
        } else {
            title.draw(with: NSRect(x: textX, y: badge.midY + 1, width: textWidth, height: 20), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
            subtitle.draw(with: NSRect(x: textX, y: badge.midY - 17, width: textWidth, height: 16), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
        }
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

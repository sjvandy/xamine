import AppKit
import SwiftUI

/// The menu bar item: the plain viewfinder normally, a blue pill with the AI glyph while an agent is active.
struct MenuBarIcon: View {
    let isAgentActive: Bool

    var body: some View {
        if isAgentActive {
            Image(nsImage: Self.agentPill)
                .accessibilityLabel("Xamine — AI agent active")
        } else {
            Image(systemName: "viewfinder")
                .accessibilityLabel("Xamine")
        }
    }

    /// The system blue, which adapts to light and dark mode.
    static let pillColor = NSColor.systemBlue

    /// Drawn in full color (not a template) so the menu bar keeps it blue in light and dark mode.
    static let agentPill: NSImage = {
        let size = NSSize(width: 30, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            pillColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            guard let glyph = NSImage(named: "AIGlyph") else { return true }
            let side: CGFloat = 13
            let glyphRect = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            glyph.draw(in: glyphRect)
            return true
        }
        image.isTemplate = false
        return image
    }()
}

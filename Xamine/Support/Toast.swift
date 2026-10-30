import SwiftUI

/// A transient capsule shown at the bottom of a view, e.g. "Copied hierarchy query".
struct ToastView: View {
    let message: String
    var symbol = "checkmark.circle.fill"

    var body: some View {
        Label(message, systemImage: symbol)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: .capsule)
            .overlay(Capsule().strokeBorder(.separator))
            .shadow(radius: 8, y: 2)
    }
}

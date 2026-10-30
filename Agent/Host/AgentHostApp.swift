import SwiftUI

/// Host app for the UI-test bundle that does the real work. It only needs to exist on the device.
@main
struct AgentHostApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("Xamine Agent").font(.title2.bold())
                Text("Started from Xamine on your Mac. You can switch to any app to inspect it.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}

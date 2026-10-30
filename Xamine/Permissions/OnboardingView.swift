import SwiftUI

struct OnboardingView: View {
    let permissions: PermissionsManager
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Xamine").font(.title2.bold())
                    Text("Two permissions let Xamine read other apps' UI and capture their windows.")
                        .foregroundStyle(.secondary)
                }
            }

            PermissionRow(
                title: "Accessibility",
                detail: "Reads element identifiers, labels and the UI hierarchy.",
                symbol: "accessibility",
                granted: permissions.accessibilityGranted,
                action: permissions.requestAccessibility
            )
            PermissionRow(
                title: "Screen Recording",
                detail: "Captures a screenshot of the window you inspect.",
                symbol: "rectangle.dashed.badge.record",
                granted: permissions.screenRecordingGranted,
                action: permissions.requestScreenRecording
            )

            Text("macOS may ask you to quit and reopen Xamine after granting Screen Recording.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Continue", action: onContinue)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!permissions.allGranted)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear(perform: permissions.startPolling)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let symbol: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Grant…", action: action)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
    }
}

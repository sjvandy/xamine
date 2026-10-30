import AppKit
import ApplicationServices
import Observation

/// Tracks the two system permissions xamine needs.
@Observable @MainActor
final class PermissionsManager {
    private(set) var accessibilityGranted = AXIsProcessTrusted()
    private(set) var screenRecordingGranted = CGPreflightScreenCaptureAccess()

    @ObservationIgnored private var pollTimer: Timer?

    var allGranted: Bool { accessibilityGranted && screenRecordingGranted }

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        if allGranted { stopPolling() }
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        openSettings(pane: "Privacy_Accessibility")
        startPolling()
    }

    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            openSettings(pane: "Privacy_ScreenCapture")
        }
        startPolling()
    }

    /// Re-checks once a second while the user is in System Settings.
    func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func openSettings(pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

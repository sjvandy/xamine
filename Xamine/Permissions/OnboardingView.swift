import SwiftUI

enum WelcomePage: Int, CaseIterable {
    case welcome, features, permissions
}

/// Remembers whether the welcome tour has been finished, so later launches only ask for missing permissions.
enum WelcomeFlow {
    static let completedKey = "hasCompletedWelcome"

    static func hasCompleted(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: completedKey)
    }

    static func markCompleted(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completedKey)
    }

    /// The welcome window appears on first launch, and whenever a permission is missing.
    static func shouldShow(permissionsGranted: Bool, defaults: UserDefaults = .standard) -> Bool {
        !permissionsGranted || !hasCompleted(defaults)
    }

    /// People who have seen the tour go straight to the permissions they still need to grant.
    static func startPage(defaults: UserDefaults = .standard) -> WelcomePage {
        hasCompleted(defaults) ? .permissions : .welcome
    }
}

struct OnboardingView: View {
    let permissions: PermissionsManager
    var onContinue: () -> Void
    @State private var page: WelcomePage

    init(permissions: PermissionsManager, startPage: WelcomePage = .welcome, onContinue: @escaping () -> Void) {
        self.permissions = permissions
        self.onContinue = onContinue
        _page = State(initialValue: startPage)
    }

    private var isLastPage: Bool { page == WelcomePage.allCases.last }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch page {
                case .welcome: WelcomeHero()
                case .features: FeatureHighlights()
                case .permissions: PermissionsPage(permissions: permissions)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            .id(page)

            footer
        }
        .padding(28)
        .frame(width: 560, height: 460)
        .background(.background)
    }

    private var footer: some View {
        HStack {
            Button("Back") { go(to: page.rawValue - 1) }
                .opacity(page == .welcome ? 0 : 1)
                .disabled(page == .welcome)

            Spacer()
            HStack(spacing: 7) {
                ForEach(WelcomePage.allCases, id: \.rawValue) { dot in
                    Circle()
                        .fill(dot == page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityHidden(true)
            Spacer()

            continueButton
        }
    }

    @ViewBuilder
    private var continueButton: some View {
        let title = isLastPage ? "Get Started" : "Continue"
        let action = { isLastPage ? onContinue() : go(to: page.rawValue + 1) }
        if #available(macOS 26, *) {
            Button(title, action: action)
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isLastPage && !permissions.allGranted)
        } else {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isLastPage && !permissions.allGranted)
        }
    }

    private func go(to index: Int) {
        guard let next = WelcomePage(rawValue: index) else { return }
        withAnimation(.smooth(duration: 0.3)) { page = next }
    }
}

// MARK: - Pages

private struct WelcomeHero: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "viewfinder")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
                .padding(26)
                .glassCard(cornerRadius: 36)
            VStack(spacing: 6) {
                Text("Welcome to Xamine").font(.largeTitle.bold())
                Text("See what's inside any app, and turn it into UI tests.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

private struct FeatureHighlights: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("What you can do").font(.title.bold())
            FeatureRow(
                symbol: "scope",
                title: "Inspect any app",
                detail: "Pick a window, or whatever is under the cursor, on your Mac or a connected iPhone or iPad."
            )
            FeatureRow(
                symbol: "doc.on.clipboard",
                title: "Copy queries that work",
                detail: "Click an element to copy its identifier, container or anchored XCUITest query."
            )
            FeatureRow(
                symbol: "sparkles",
                title: "Let an AI agent drive",
                detail: "Set up Claude Code or Claude in Xcode to operate apps and write UI tests for you."
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .glassCard(cornerRadius: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PermissionsPage: View {
    let permissions: PermissionsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Two permissions").font(.title.bold())
                Text("They let Xamine read other apps' UI and capture their windows.")
                    .foregroundStyle(.secondary)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .glassCard(cornerRadius: 12)
    }
}

private extension View {
    /// Liquid Glass on macOS 26 and later, a material before that.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

import Foundation
import Testing
@testable import Xamine

struct WelcomeFlowTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "WelcomeFlowTests-\(UUID().uuidString)")!
    }

    @Test func firstLaunchShowsFullTourEvenWithPermissions() {
        let defaults = makeDefaults()
        #expect(WelcomeFlow.shouldShow(permissionsGranted: true, defaults: defaults))
        #expect(WelcomeFlow.startPage(defaults: defaults) == .welcome)
    }

    @Test func finishedTourOnlyReturnsForMissingPermissions() {
        let defaults = makeDefaults()
        WelcomeFlow.markCompleted(defaults)
        #expect(!WelcomeFlow.shouldShow(permissionsGranted: true, defaults: defaults))
        #expect(WelcomeFlow.shouldShow(permissionsGranted: false, defaults: defaults))
        #expect(WelcomeFlow.startPage(defaults: defaults) == .permissions)
    }
}

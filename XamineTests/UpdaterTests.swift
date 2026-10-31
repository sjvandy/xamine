import Testing
@testable import Xamine

@Test func newerVersions() {
    #expect(Updater.isNewer("0.2.0", than: "0.1.0"))
    #expect(Updater.isNewer("0.10.0", than: "0.9.0"))
    #expect(Updater.isNewer("1.0", than: "0.9.9"))
    #expect(!Updater.isNewer("0.1.0", than: "0.1.0"))
    #expect(!Updater.isNewer("0.1.0", than: "0.2.0"))
}

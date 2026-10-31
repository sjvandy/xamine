import Carbon.HIToolbox
import Foundation
import Testing
@testable import Xamine

@MainActor
struct ShortcutStoreTests {
    private func makeStore() -> ShortcutStore {
        let suite = "ShortcutStoreTests-\(UUID().uuidString)"
        return ShortcutStore(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test func defaultsMatchOriginalShortcuts() {
        let store = makeStore()
        #expect(store.inspect.displayString == "⇧⌘X")
        #expect(store.handsOff.displayString == "⌥⇧⌘X")
    }

    @Test func persistsAcrossInstances() {
        let suite = "ShortcutStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = ShortcutStore(defaults: defaults)
        let custom = Shortcut(keyCode: kVK_ANSI_K, modifiers: cmdKey | controlKey, key: "k")
        #expect(store.set(custom, for: .inspect))
        #expect(ShortcutStore(defaults: defaults).inspect == custom)
    }

    @Test func rejectsConflicts() {
        let store = makeStore()
        #expect(store.conflictingAction(for: store.handsOff, excluding: .inspect) == .handsOff)
        #expect(!store.set(store.handsOff, for: .inspect))
        #expect(store.inspect == .inspectDefault)
    }

    @Test func resetRestoresDefaults() {
        let store = makeStore()
        store.set(Shortcut(keyCode: kVK_ANSI_K, modifiers: cmdKey, key: "k"), for: .inspect)
        store.resetAll()
        #expect(store.inspect == .inspectDefault)
        #expect(store.handsOff == .handsOffDefault)
    }

    @Test func convertsModifierFlags() {
        let mask = Shortcut.carbonModifiers(from: [.command, .option])
        #expect(mask == cmdKey | optionKey)
    }

    @Test func notifiesOnChange() {
        let store = makeStore()
        var count = 0
        store.onChange = { count += 1 }
        store.set(Shortcut(keyCode: kVK_ANSI_K, modifiers: cmdKey, key: "k"), for: .inspect)
        #expect(count == 1)
    }
}

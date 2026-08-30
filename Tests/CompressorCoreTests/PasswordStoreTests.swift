import Foundation
import Testing
@testable import CompressorCore

/// Uses a per-run service name and always deletes it, so the developer's real login
/// keychain is never polluted with leftovers.
@Suite("KeychainPasswordStore", .serialized)
struct PasswordStoreTests {

    private func makeStore() -> KeychainPasswordStore {
        KeychainPasswordStore(service: "com.local.sevenzip-compressor.tests.\(UUID().uuidString)")
    }

    @Test func roundTripsAPassword() throws {
        let store = makeStore()
        defer { try? store.delete() }

        #expect(try store.load() == nil, "a fresh service must start empty")
        try store.save(try Password("Corr3ct Horse 日本語 €"))
        #expect(try store.load()?.value == "Corr3ct Horse 日本語 €")
    }

    @Test func savingTwiceOverwritesRatherThanFailing() throws {
        let store = makeStore()
        defer { try? store.delete() }

        try store.save(try Password("first"))
        try store.save(try Password("second"))
        #expect(try store.load()?.value == "second")
    }

    @Test func deleteRemovesTheEntry() throws {
        let store = makeStore()
        try store.save(try Password("temporary"))
        try store.delete()
        #expect(try store.load() == nil)
    }

    @Test func deletingSomethingThatIsNotThereIsNotAnError() throws {
        let store = makeStore()
        try store.delete()
        try store.delete()
    }

    @Test("two stores with different service names cannot see each other's password")
    func storesAreIsolated() throws {
        let a = makeStore(), b = makeStore()
        defer { try? a.delete(); try? b.delete() }
        try a.save(try Password("only-in-a"))
        #expect(try b.load() == nil)
    }
}

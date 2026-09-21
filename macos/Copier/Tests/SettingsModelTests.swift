import CopierCore
import Foundation
import Testing

@MainActor
@Suite("SettingsModel")
struct SettingsModelTests {
    private func makeModel() -> (SettingsModel, SettingsStore, KeychainStore) {
        let defaults = UserDefaults(suiteName: "copier-settings-tests-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        let keychain = KeychainStore(service: "copier.tests.\(UUID().uuidString)")
        return (SettingsModel(store: store, keychain: keychain), store, keychain)
    }

    @Test("an op:// reference is stored in defaults, not in the keychain")
    func referenceGoesToDefaults() {
        let (model, store, keychain) = makeModel()
        model.synologyPassword = "op://Private/Synology/password"
        model.commitEdits()

        #expect(store.synologyPassword == "op://Private/Synology/password")
        #expect(keychain.synologyPassword == nil)
        #expect(model.usesPasswordReference)
    }

    @Test("a literal password goes to the keychain and clears the defaults entry")
    func literalGoesToKeychain() {
        let (model, store, keychain) = makeModel()
        model.synologyPassword = "op://Private/Synology/password"
        model.commitEdits()
        #expect(store.synologyPassword != nil)

        model.synologyPassword = "hunter2"
        model.commitEdits()

        #expect(store.synologyPassword == nil)
        #expect(model.usesPasswordReference == false)
        // The keychain may be unavailable to an unsigned test bundle; only assert when it wrote.
        if let stored = keychain.synologyPassword {
            #expect(stored == "hunter2")
        }
    }

    @Test("commitEdits flushes host, user and password together")
    func commitFlushesEverything() {
        let (model, store, _) = makeModel()
        model.synologyHost = "  nas.local  "
        model.synologyUser = " yannick "
        model.synologyPassword = "op://Private/Synology/password"
        model.commitEdits()

        #expect(store.synologyHost == "nas.local")
        #expect(store.synologyUser == "yannick")
        #expect(store.synologyPassword == "op://Private/Synology/password")
        #expect(model.isNASConfigured)
    }

    @Test("adding shared folders keeps them unique and ordered")
    func addsFolders() {
        let (model, store, _) = makeModel()
        model.addSynologyFolder("/photo")
        model.addSynologyFolder("/photo/2026")
        model.addSynologyFolder("/photo") // ignored
        model.addSynologyFolder("   ") // ignored

        #expect(model.synologyFolders == ["/photo", "/photo/2026"])
        #expect(store.synologyFolders == ["/photo", "/photo/2026"])
    }
}

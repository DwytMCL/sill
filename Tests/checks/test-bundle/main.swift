import Foundation
import Security

// Check the production stores' selectors without reading or writing any Keychain item.
let upstream = KeychainIdentityStore(service: IdentityStorePlan.keychainService(bundleIdentifier: "me.saffer.sill.mac"))
let port = KeychainIdentityStore(service: IdentityStorePlan.keychainService(bundleIdentifier: "local.sill.amd-test"))
precondition(upstream.service == "me.saffer.sill.remote")
precondition(KeychainIdentityStore().service == upstream.service)
precondition(upstream.keyTag == Data("me.saffer.sill.remote.host-key".utf8))
precondition(port.service == "local.sill.amd-test.remote")
precondition(port.keyTag == Data("local.sill.amd-test.remote.host-key".utf8))
for id in [nil, "SillMenuBar", "local.sill.amd-test.other", "me.saffer.sill.mac"] as [String?] {
    precondition(IdentityStorePlan.keychainService(bundleIdentifier: id) == upstream.service)
}
let protected = KeychainIdentityStore(accessGroup: "test.group", service: port.service)
precondition(protected.accessGroup == "test.group" && protected.keyTag == port.keyTag)
precondition(IdentityStorePlan.choose(bundled: true, synthetic: true, entitledAccessGroup: nil, testRemoteDir: nil) == .memory)
precondition(IdentityStorePlan.choose(bundled: true, synthetic: false, entitledAccessGroup: nil, testRemoteDir: nil) == .legacy)

// Volatile defaults: stale cached ARM release must never appear as a port update.
// No persistent domain is opened and start/checkNow must not schedule a network request.
MainActor.assumeIsolated {
    let defaults = UserDefaults()
    defaults.setVolatileDomain([
        UpdatePolicy.Stored.tagKey: "v99.0.0",
        UpdatePolicy.Stored.urlKey: "https://github.com/Saffsanity/sill/releases/tag/v99.0.0"
    ], forName: UserDefaults.registrationDomain)
    var c = UpdateChecker.Configuration()
    c.running = "0.5.1"
    c.portTestBundle = true
    c.testFeed = true // even a debug feed/version override cannot reopen the production update path
    c.checkAtStart = true
    let checker = UpdateChecker(configuration: c, automatic: true, defaults: defaults)
    precondition(!checker.canCheck && checker.offer == nil)
    precondition(!checker.pane.canCheck && !checker.pane.automaticAvailable && checker.pane.releasePage == nil)
    precondition(checker.pane.line.contains("Sill AMD Test"))
    checker.start()
    checker.checkNow()
    checker.setAutomatic(false)
    checker.setAutomatic(true)
    checker.systemDidWake()
    precondition(checker.phase == .idle && checker.resultCount == 0 && checker.offer == nil)
    c.portTestBundle = false
    let original = UpdateChecker(configuration: c, automatic: false, defaults: defaults)
    precondition(original.canCheck && original.offer != nil && original.pane.automaticAvailable)
}
print("test-bundle: namespace, cache and update guards passed; no Keychain or network calls")

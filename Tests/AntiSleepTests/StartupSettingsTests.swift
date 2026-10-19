import Foundation
import AntiSleepCore

final class StartupSettingsTests {
    func testDefaultsToOffAndPersistsExplicitChoice() {
        let name = "AntiSleepChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = StartupSettings(defaults: defaults)
        expectFalse(settings.startsOn)
        settings.startsOn = true
        expectTrue(StartupSettings(defaults: UserDefaults(suiteName: name)!).startsOn)
        settings.startsOn = false
        expectFalse(StartupSettings(defaults: UserDefaults(suiteName: name)!).startsOn)
    }

    func testChoiceDoesNotChangeRunningProtection() {
        let name = "AntiSleepChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let power = FakePower()
        let protection = ProtectionSwitch(makeSession: { ProtectionSession(backend: power) })
        let settings = StartupSettings(defaults: defaults)
        settings.startsOn = true
        expectFalse(protection.enabled)
        expectTrue(power.events.isEmpty)
        expectTrue(protection.setEnabled(settings.startsOn).confirmedOn)
        let events = power.events
        settings.startsOn = false
        expectTrue(protection.enabled)
        expectEqual(power.events, events)
        expectTrue(protection.shutdown())
        expectFalse(power.disabled!)
    }
}

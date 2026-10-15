import AntiSleepCore

final class ProtectionSwitchTests {
    func testOffLaunchDoesNotTouchPowerSettings() {
        let power = FakePower()
        var sessions = 0
        let sut = ProtectionSwitch(makeSession: {
            sessions += 1
            return ProtectionSession(backend: power)
        })
        let result = sut.reconcile()
        expectFalse(result.enabled)
        expectFalse(result.confirmedOn)
        expectEqual(sessions, 0)
        expectTrue(power.events.isEmpty)
    }

    func testOnOffChangesProtectionWhileAppStaysAlive() {
        let power = FakePower()
        let sut = ProtectionSwitch(makeSession: { ProtectionSession(backend: power) })
        expectTrue(sut.setEnabled(true).confirmedOn)
        expectEqual(power.disabled, true)
        expectFalse(sut.setEnabled(false).enabled)
        expectEqual(power.disabled, false)
        expectEqual(power.releases, 1)
        _ = sut.reconcile()
        expectEqual(power.sets, [true, false])
    }

    func testNextActivationCapturesFreshBaseline() {
        let power = FakePower()
        let sut = ProtectionSwitch(makeSession: { ProtectionSession(backend: power) })
        _ = sut.setEnabled(true)
        _ = sut.setEnabled(false)
        power.disabled = true
        _ = sut.setEnabled(true)
        _ = sut.setEnabled(false)
        expectEqual(power.disabled, true)
        expectEqual(power.sets, [true, false])
    }

    func testOffRestoreFailureKeepsOn() {
        let power = FakePower()
        let sut = ProtectionSwitch(makeSession: { ProtectionSession(backend: power) })
        _ = sut.setEnabled(true)
        power.canSet = false
        let failed = sut.setEnabled(false)
        expectTrue(failed.enabled)
        expectTrue(failed.restoreFailed)
        expectTrue(sut.reconcile().restoreFailed)
        expectEqual(power.releases, 0)
        power.canSet = true
        expectFalse(sut.setEnabled(false).enabled)
    }

    func testQuitOnRestoresAndNextLaunchAlwaysStartsOff() {
        let power = FakePower()
        let sut = ProtectionSwitch(makeSession: { ProtectionSession(backend: power) })
        expectTrue(sut.setEnabled(true).confirmedOn)
        expectTrue(sut.shutdown())
        expectEqual(power.disabled, false)
        let next = ProtectionSwitch(makeSession: { ProtectionSession(backend: power) })
        expectFalse(next.reconcile().enabled)
        expectEqual(power.sets, [true, false])
    }

    func testOffQuitHasNoPowerSideEffects() {
        let power = FakePower()
        let sut = ProtectionSwitch(makeSession: { ProtectionSession(backend: power) })
        expectTrue(sut.shutdown())
        expectTrue(power.events.isEmpty)
    }

    func testRequestedOnIsNotGreenUntilBothProtectionsAreConfirmed() {
        let power = FakePower(); power.canArm = false
        let sut = ProtectionSwitch(makeSession: { ProtectionSession(backend: power) })
        let result = sut.setEnabled(true)
        expectTrue(result.enabled)
        expectFalse(result.confirmedOn)
        power.canArm = true
        expectTrue(sut.reconcile().confirmedOn)
    }
}

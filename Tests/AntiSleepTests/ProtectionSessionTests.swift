import Foundation
import AntiSleepCore

final class FakePower: PowerBackend {
    var idle = true
    var conflict = false
    var disabled: Bool? = false
    var canArm = true
    var canSet = true
    var closed: Bool? = false
    var canDarken = true
    var sets: [Bool] = []
    var recoveryOriginals: [Bool] = []
    var releases = 0
    var disarms = 0
    var displayRequests = 0
    var events: [String] = []
    func acquireIdleAssertion() -> Bool { events.append("idle"); return idle }
    func releaseIdleAssertion() { releases += 1; events.append("release") }
    func conflictingAppIsRunning() -> Bool { conflict }
    func readSleepDisabled() -> Bool? { disabled }
    func armRecovery(restoring original: Bool) -> Bool {
        events.append("arm"); recoveryOriginals.append(original); return canArm
    }
    func disarmRecovery() { disarms += 1; events.append("disarm") }
    func setSleepDisabled(_ value: Bool) -> Bool {
        sets.append(value); events.append("set=\(value)")
        if canSet { disabled = value }
        return canSet
    }
    func lidIsClosed() -> Bool? { closed }
    func turnDisplaysOff() -> Bool { displayRequests += 1; return canDarken }
}

final class ProtectionSessionTests {
    func testLaunchProtectsWithoutKeyboardInputAndQuitRestores() {
        let power = FakePower()
        let sut = ProtectionSession(backend: power)
        let result = sut.reconcile()
        expectTrue(result.idleProtected)
        expectTrue(result.lidProtected)
        expectEqual(power.sets, [true])
        expectEqual(power.displayRequests, 0)
        expectTrue(sut.stop())
        expectEqual(power.sets, [true, false])
        expectEqual(power.releases, 1)
    }

    func testRecoveryIsArmedBeforeChangingSystemSetting() {
        let power = FakePower()
        _ = ProtectionSession(backend: power).reconcile()
        expectLessThan(power.events.firstIndex(of: "arm")!, power.events.firstIndex(of: "set=true")!)
    }

    func testEachLidClosureTurnsDisplaysOffOnce() {
        let power = FakePower(), sut: ProtectionSession
        sut = ProtectionSession(backend: power)
        power.closed = true
        _ = sut.reconcile(); _ = sut.reconcile()
        expectEqual(power.displayRequests, 1)
        power.closed = false; _ = sut.reconcile()
        power.closed = true; _ = sut.reconcile()
        expectEqual(power.displayRequests, 2)
        expectEqual(power.sets, [true])
    }

    func testFailedDisplaySleepIsRetriedWithoutDroppingProtection() {
        let power = FakePower(), sut: ProtectionSession
        sut = ProtectionSession(backend: power)
        power.closed = true; power.canDarken = false
        expectTrue(sut.reconcile().lidProtected)
        power.canDarken = true; _ = sut.reconcile()
        expectEqual(power.displayRequests, 2)
        expectEqual(power.disabled, true)
    }

    func testExternalSettingDriftIsRepaired() {
        let power = FakePower(), sut: ProtectionSession
        sut = ProtectionSession(backend: power)
        _ = sut.reconcile(); power.disabled = false
        expectTrue(sut.reconcile().lidProtected)
        expectEqual(power.sets, [true, true])
        expectTrue(sut.stop())
        expectEqual(power.disabled, false)
    }

    func testExistingDisabledSettingIsPreservedOnQuit() {
        let power = FakePower(); power.disabled = true
        let sut = ProtectionSession(backend: power)
        _ = sut.reconcile()
        expectTrue(sut.stop())
        expectEqual(power.disabled, true)
        expectEqual(power.sets, [])
    }

    func testExistingDisabledBaselineSurvivesRepair() {
        let power = FakePower(); power.disabled = true
        let sut = ProtectionSession(backend: power)
        _ = sut.reconcile(); power.disabled = false
        _ = sut.reconcile(); expectTrue(sut.stop())
        expectEqual(power.disabled, true)
        expectTrue(power.recoveryOriginals.allSatisfy { $0 })
    }

    func testMissingHelperOrMonitorDoesNotClaimLidProtection() {
        let power = FakePower(); power.canArm = false
        let result = ProtectionSession(backend: power).reconcile()
        expectTrue(result.idleProtected)
        expectFalse(result.lidProtected)
        expectEqual(power.sets, [])
    }

    func testLostRecoveryMonitorIsCheckedAgain() {
        let power = FakePower(), sut: ProtectionSession
        sut = ProtectionSession(backend: power)
        _ = sut.reconcile(); power.canArm = false
        expectFalse(sut.reconcile().lidProtected)
        expectEqual(power.recoveryOriginals.count, 2)
    }

    func testFailedApplyDoesNotClaimSuccess() {
        let power = FakePower(); power.canSet = false
        expectFalse(ProtectionSession(backend: power).reconcile().lidProtected)
        expectEqual(power.disabled, false)
    }

    func testUnknownSettingDoesNotOverwriteSystemState() {
        let power = FakePower(); power.disabled = nil
        expectFalse(ProtectionSession(backend: power).reconcile().lidProtected)
        expectEqual(power.sets, [])
        expectTrue(power.recoveryOriginals.isEmpty)
    }

    func testLegacyAppConflictDoesNotFightSettings() {
        let power = FakePower(); power.conflict = true
        let sut = ProtectionSession(backend: power)
        expectFalse(sut.reconcile().lidProtected)
        expectEqual(power.sets, [])
        power.conflict = false
        expectTrue(sut.reconcile().lidProtected)
    }

    func testFailedRestoreKeepsIdleAssertionAndMonitorAlive() {
        let power = FakePower(), sut: ProtectionSession
        sut = ProtectionSession(backend: power)
        _ = sut.reconcile(); power.canSet = false
        expectFalse(sut.stop())
        expectEqual(power.releases, 0)
        expectEqual(power.disarms, 0)
        power.canSet = true
        expectTrue(sut.stop())
        expectEqual(power.releases, 1)
    }

    func testIdleAssertionFailureIsNotReportedAsCompleteProtection() {
        let power = FakePower(); power.idle = false
        expectFalse(ProtectionSession(backend: power).reconcile().idleProtected)
    }

    func testUnknownLidStateDoesNotBlankDisplays() {
        let power = FakePower(); power.closed = nil
        _ = ProtectionSession(backend: power).reconcile()
        expectEqual(power.displayRequests, 0)
    }

    func testSleepSettingParsingRequiresExplicitValue() {
        expectEqual(SleepSettingParser.parse("System-wide power settings:\n SleepDisabled\t1\n"), true)
        expectEqual(SleepSettingParser.parse(" SleepDisabled 0"), false)
        expectNil(SleepSettingParser.parse("SleepDisabled unknown"))
        expectNil(SleepSettingParser.parse("sleep 0"))
    }
}

import Foundation

// Command Line Toolsだけで実行できる、外部依存のない検証ランナー。
var failures = 0
func failure(_ message: String, file: StaticString, line: UInt) {
    failures += 1
    print("失敗: \(file):\(line) \(message)")
}
func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !value { failure("trueを期待", file: file, line: line) }
}
func expectFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    if value { failure("falseを期待", file: file, line: line) }
}
func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) {
    if a != b { failure("\(a) != \(b)", file: file, line: line) }
}
func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    if value != nil { failure("nilを期待", file: file, line: line) }
}
func expectLessThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) {
    if !(a < b) { failure("順序の不一致", file: file, line: line) }
}
let suite = ProtectionSessionTests()
let switches = ProtectionSwitchTests()
let startup = StartupSettingsTests()
let checks: [(String, () -> Void)] = [
    ("起動で保護・終了で復元", suite.testLaunchProtectsWithoutKeyboardInputAndQuitRestores),
    ("設定変更より先に復元監視", suite.testRecoveryIsArmedBeforeChangingSystemSetting),
    ("ふた閉じごとに一度消灯", suite.testEachLidClosureTurnsDisplaysOffOnce),
    ("消灯失敗時も本体保護を維持", suite.testFailedDisplaySleepIsRetriedWithoutDroppingProtection),
    ("外部からの解除を再適用", suite.testExternalSettingDriftIsRepaired),
    ("変更前の保護設定を保存", suite.testExistingDisabledSettingIsPreservedOnQuit),
    ("修復後も元の設定へ復元", suite.testExistingDisabledBaselineSurvivesRepair),
    ("監視なしでは設定を変更しない", suite.testMissingHelperOrMonitorDoesNotClaimLidProtection),
    ("復元監視の生存を再確認", suite.testLostRecoveryMonitorIsCheckedAgain),
    ("適用失敗を成功表示しない", suite.testFailedApplyDoesNotClaimSuccess),
    ("不明な設定を上書きしない", suite.testUnknownSettingDoesNotOverwriteSystemState),
    ("旧版との設定競合を回避", suite.testLegacyAppConflictDoesNotFightSettings),
    ("復元失敗時は終了しない", suite.testFailedRestoreKeepsIdleAssertionAndMonitorAlive),
    ("防止要求の失敗を検知", suite.testIdleAssertionFailureIsNotReportedAsCompleteProtection),
    ("ふたの状態不明時は消灯しない", suite.testUnknownLidStateDoesNotBlankDisplays),
    ("設定値の解析", suite.testSleepSettingParsingRequiresExplicitValue),
    ("OFF起動では電源設定を変更しない", switches.testOffLaunchDoesNotTouchPowerSettings),
    ("アプリを終了せずONとOFFを切り替え", switches.testOnOffChangesProtectionWhileAppStaysAlive),
    ("再度ONにするときの設定を正しく復元", switches.testNextActivationCapturesFreshBaseline),
    ("OFF失敗時にONを保持する", switches.testOffRestoreFailureKeepsOn),
    ("ONで終了すると復元し次回はOFF", switches.testQuitOnRestoresAndNextLaunchAlwaysStartsOff),
    ("OFFで終了するときは設定に触れない", switches.testOffQuitHasNoPowerSideEffects),
    ("適用未確認のONを成功扱いしない", switches.testRequestedOnIsNotGreenUntilBothProtectionsAreConfirmed),
    ("失敗応答でも変更された設定を復元", suite.testFailedApplyThatChangedSettingStillRestores),
    ("復元の成功応答だけでは終了を許可しない", suite.testSuccessfulCommandWithoutRestoreDoesNotAllowExit),
    ("防止要求の解除失敗時は監視を維持", suite.testAssertionReleaseFailureKeepsRecoveryArmed),
    ("監視が終了するまで終了を許可しない", suite.testRecoveryMustExitBeforeShutdownCompletes),
    ("正常終了後は定期確認で再度ONにしない", switches.testSuccessfulShutdownCannotReenableProtectionOnReconcile),
    ("終了失敗後に再試行して復元", switches.testFailedShutdownCanBeRetried),
    ("起動時設定の初期値OFFと保存", startup.testDefaultsToOffAndPersistsExplicitChoice),
    ("起動時設定と現在の保護を分離", startup.testChoiceDoesNotChangeRunningProtection)
]
for (name, check) in checks {
    let before = failures
    check()
    print("\(before == failures ? "PASS" : "FAIL") \(name)")
}
print("\(checks.count)項目 / 失敗\(failures)件")
exit(failures == 0 ? 0 : 1)

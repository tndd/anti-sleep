import Foundation

public protocol PowerBackend: AnyObject {
    func acquireIdleAssertion() -> Bool
    func releaseIdleAssertion()
    func conflictingAppIsRunning() -> Bool
    func readSleepDisabled() -> Bool?
    func armRecovery(restoring original: Bool) -> Bool
    func disarmRecovery()
    func setSleepDisabled(_ disabled: Bool) -> Bool
    func lidIsClosed() -> Bool?
    func turnDisplaysOff() -> Bool
}

public struct ProtectionStatus: Equatable {
    public let idleProtected: Bool
    public let lidProtected: Bool
    public let detail: String

    public init(idleProtected: Bool, lidProtected: Bool, detail: String) {
        self.idleProtected = idleProtected
        self.lidProtected = lidProtected
        self.detail = detail
    }
}

/// シリアルキュー上で使用する。要求した設定と、実際に確認した設定を区別する。
public final class ProtectionSession {
    private let backend: PowerBackend
    private var original: Bool?
    private var recoveryArmed = false
    private var changedSetting = false
    private var displaysOffForCurrentClosure = false

    public init(backend: PowerBackend) { self.backend = backend }

    public func reconcile() -> ProtectionStatus {
        let idle = backend.acquireIdleAssertion()
        guard !backend.conflictingAppIsRunning() else {
            return status(idle, false, "旧版Capsomniaを終了してください。ふた閉じ保護が競合します。")
        }
        guard let actual = backend.readSleepDisabled() else {
            return status(idle, false, "本体のスリープ設定を確認できません。再試行しています。")
        }
        if original == nil { original = actual }
        recoveryArmed = backend.armRecovery(restoring: original!)
        guard recoveryArmed else {
            return status(idle, false, "ふた閉じ保護を準備できません。ヘルパーを設定してください。")
        }
        if !actual {
            guard backend.setSleepDisabled(true) else {
                return status(idle, false, "ふた閉じ保護の適用に失敗しました。ヘルパー設定を確認してください。")
            }
            changedSetting = true
        }
        guard backend.readSleepDisabled() == true else {
            return status(idle, false, "ふた閉じ保護が解除されています。再試行しています。")
        }
        guard idle else {
            return status(false, true, "無操作スリープの防止要求を登録できません。再試行しています。")
        }
        guard let closed = backend.lidIsClosed() else {
            return status(true, true, "本体は保護中です。ふたの状態を確認できません。")
        }
        if closed {
            if !displaysOffForCurrentClosure {
                displaysOffForCurrentClosure = backend.turnDisplaysOff()
                if !displaysOffForCurrentClosure {
                    return status(true, true, "本体は保護中です。画面の消灯に失敗したため再試行しています。")
                }
            }
        } else {
            displaysOffForCurrentClosure = false
        }
        return status(true, true, "画面は消灯できます。Caps Lockを操作しても保護は続きます。")
    }

    /// 復元に失敗した場合は防止要求を保持し、呼び出し側に終了を取りやめさせる。
    public func stop() -> Bool {
        if changedSetting, let original {
            if backend.readSleepDisabled() != original {
                guard backend.setSleepDisabled(original),
                      backend.readSleepDisabled() == original else { return false }
            }
        }
        backend.disarmRecovery()
        backend.releaseIdleAssertion()
        return true
    }

    private func status(_ idle: Bool, _ lid: Bool, _ detail: String) -> ProtectionStatus {
        ProtectionStatus(idleProtected: idle, lidProtected: lid, detail: detail)
    }
}

public enum SleepSettingParser {
    public static func parse(_ text: String) -> Bool? {
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count == 2, fields[0] == "SleepDisabled" {
                if fields[1] == "1" { return true }
                if fields[1] == "0" { return false }
            }
        }
        return nil
    }
}

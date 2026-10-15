import Foundation

public struct ProtectionSwitchState {
    public let enabled: Bool
    public let protection: ProtectionStatus?
    public let restoreFailed: Bool
    public init(enabled: Bool, protection: ProtectionStatus?, restoreFailed: Bool = false) {
        self.enabled = enabled
        self.protection = protection
        self.restoreFailed = restoreFailed
    }
    public var confirmedOn: Bool {
        enabled && protection?.idleProtected == true && protection?.lidProtected == true
    }
}

/// アプリの寿命と保護の寿命を分離する。シリアルキュー上で使用する。
public final class ProtectionSwitch {
    public private(set) var enabled = false
    private var session: ProtectionSession?
    private var restoreFailed = false
    private let makeSession: () -> ProtectionSession
    public init(makeSession: @escaping () -> ProtectionSession) {
        self.makeSession = makeSession
    }

    public func reconcile() -> ProtectionSwitchState {
        guard enabled else { return state(nil) }
        if session == nil { session = makeSession() }
        return state(session?.reconcile())
    }

    public func setEnabled(_ requested: Bool) -> ProtectionSwitchState {
        restoreFailed = false
        if !requested, let session {
            guard session.stop() else {
                restoreFailed = true
                return state(session.reconcile())
            }
            self.session = nil
        }
        enabled = requested
        return reconcile()
    }

    /// 終了時は設定を復元する。新しいインスタンスは常にOFFで開始する。
    public func shutdown() -> Bool { session?.stop() ?? true }

    private func state(_ protection: ProtectionStatus?) -> ProtectionSwitchState {
        ProtectionSwitchState(enabled: enabled, protection: protection, restoreFailed: restoreFailed)
    }
}

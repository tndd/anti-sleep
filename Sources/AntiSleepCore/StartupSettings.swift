import Foundation

/// 現在の保護状態とは独立した、次回起動時の設定。
public final class StartupSettings {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var startsOn: Bool {
        get { defaults.bool(forKey: "startOnLaunch") }
        set { defaults.set(newValue, forKey: "startOnLaunch") }
    }
}

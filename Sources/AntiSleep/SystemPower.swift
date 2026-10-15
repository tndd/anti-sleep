import AppKit
import AntiSleepCore
import IOKit.pwr_mgt
import Darwin

struct CommandResult {
    let status: Int32
    let output: String
}

enum Command {
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 8) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return CommandResult(status: -1, output: "") }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            return CommandResult(status: -2, output: "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

enum Helper {
    static let ownPath = "/Library/PrivilegedHelperTools/anti-sleep-pmset"
    static let legacyPath = "/Library/PrivilegedHelperTools/capsomnia-pmset"

    static func isTrusted(_ path: String) -> Bool {
        guard [ownPath, legacyPath].contains(path),
              let a = try? FileManager.default.attributesOfItem(atPath: path),
              (a[.type] as? FileAttributeType) == .typeRegular,
              (a[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
              let permissions = (a[.posixPermissions] as? NSNumber)?.uint16Value else { return false }
        return permissions & 0o022 == 0 && FileManager.default.isExecutableFile(atPath: path)
    }

    static func availablePath() -> String? {
        for path in [ownPath, legacyPath] where isTrusted(path) {
            if Command.run("/usr/bin/sudo", ["-n", "-l", path, "on"]).status == 0 { return path }
        }
        return nil
    }

    static func run(_ path: String, disabled: Bool) -> Bool {
        guard isTrusted(path) else { return false }
        return Command.run("/usr/bin/sudo", ["-n", path, disabled ? "on" : "off"]).status == 0
    }
}

/// 親アプリのパイプが閉じたら、異常終了でも元のSleepDisabledへ戻す。
enum RecoveryMonitor {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.count == 4, args[1] == "--restore-on-exit" else { return false }
        guard Helper.isTrusted(args[2]), ["0", "1"].contains(args[3]) else { exit(64) }
        FileHandle.standardOutput.write(Data("ready\n".utf8))
        let message = FileHandle.standardInput.readDataToEndOfFile()
        if message == Data("handled".utf8) { exit(0) }
        for attempt in 0..<3 {
            if Helper.run(args[2], disabled: args[3] == "1") { exit(0) }
            if attempt < 2 { Thread.sleep(forTimeInterval: 1) }
        }
        exit(70)
    }
}

final class SystemPower: PowerBackend {
    private var assertion = IOPMAssertionID(0)
    private var helper: String?
    private var recovery: Process?
    private var recoveryInput: Pipe?
    var onEvent: ((String) -> Void)?

    func acquireIdleAssertion() -> Bool {
        if assertion != 0,
           let properties = IOPMAssertionCopyProperties(assertion)?.takeRetainedValue() as? [String: Any],
           let level = properties[kIOPMAssertionLevelKey] as? NSNumber,
           level.intValue == kIOPMAssertionLevelOn { return true }
        if assertion != 0 { IOPMAssertionRelease(assertion) }
        assertion = 0
        return IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "AntiSleep: アプリ起動中の処理継続" as CFString, &assertion
        ) == kIOReturnSuccess
    }

    func releaseIdleAssertion() {
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    }

    func conflictingAppIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.github.fuji-mak.capsomnia").isEmpty
    }

    func readSleepDisabled() -> Bool? {
        let r = Command.run("/usr/bin/pmset", ["-g"])
        return r.status == 0 ? SleepSettingParser.parse(r.output) : nil
    }

    func armRecovery(restoring original: Bool) -> Bool {
        if let recovery, recovery.isRunning { return true }
        guard let path = Helper.availablePath() else { return false }
        helper = path
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        // 親だけが書き込み側を保持する。子へ継承すると親の終了でEOFにならない。
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["--restore-on-exit", path, original ? "1" : "0"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        try? input.fileHandleForReading.close()
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let arrived = poll(&descriptor, 1, 5_000) > 0
        let answer = arrived ? (try? output.fileHandleForReading.read(upToCount: 6)) : nil
        guard answer == Data("ready\n".utf8), process.isRunning else {
            try? input.fileHandleForWriting.close()
            return false
        }
        recovery = process
        recoveryInput = input
        onEvent?("異常終了時の復元監視を開始")
        return true
    }

    func disarmRecovery() {
        // 正常終了では親が復元済み。異常終了時だけ監視側が復元する。
        try? recoveryInput?.fileHandleForWriting.write(contentsOf: Data("handled".utf8))
        try? recoveryInput?.fileHandleForWriting.close()
        recoveryInput = nil
        if let recovery {
            let deadline = Date().addingTimeInterval(3)
            while recovery.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if recovery.isRunning { recovery.terminate() }
        }
        recovery = nil
    }

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        guard let helper else { return false }
        let result = Helper.run(helper, disabled: disabled)
        onEvent?("本体スリープ防止=\(disabled) 適用成功=\(result)")
        return result
    }

    func lidIsClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                               kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    func turnDisplaysOff() -> Bool {
        let result = Command.run("/usr/bin/pmset", ["displaysleepnow"]).status == 0
        onEvent?("画面消灯 成功=\(result)")
        return result
    }
}

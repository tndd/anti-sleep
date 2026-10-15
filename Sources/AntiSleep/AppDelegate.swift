import AppKit
import AntiSleepCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let arguments = ProcessInfo.processInfo.arguments
    private var preview: Bool { arguments.contains("--preview") }
    private let worker = DispatchQueue(label: "app.antisleep.protection")
    private let power = SystemPower()
    private lazy var protection = ProtectionSwitch(makeSession: { ProtectionSession(backend: self.power) })
    private var timer: DispatchSourceTimer?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private lazy var exitMenu: NSMenu = {
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "終了", action: #selector(quit), keyEquivalent: "q")
        item.target = self
        return menu
    }()
    private let panel = PowerPanelView(frame: NSRect(x: 0, y: 0, width: 300, height: 330))
    private var renderWindow: NSWindow?
    private var stopping = false
    private var lastDetail = ""
    private var signalSources: [DispatchSourceSignal] = []
    private var latestState = ProtectionSwitchState(enabled: false, protection: nil)
    private var launchSnapshots: [[String: Any]] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua)
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "app.antisleep.AntiSleep")
            .filter { $0.processIdentifier != getpid() && !$0.isTerminated && $0.activationPolicy != .prohibited }
        if !preview, !others.isEmpty { exit(0) }
        // 画像出力では項目を作らない。isVisible=falseは保存され、本番の表示まで消してしまう。
        if !(preview && argument(after: "--render-preview") != nil) {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = preview ? "AntiSleepPreview" : "AntiSleep"
            item.isVisible = true
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            statusItem = item
        }
        let controller = NSViewController()
        controller.view = panel
        popover.contentViewController = controller
        popover.contentSize = panel.frame.size
        popover.behavior = .transient
        panel.powerButton.target = self
        panel.powerButton.action = #selector(togglePower)
        panel.helperButton.target = self
        panel.helperButton.action = #selector(installHelper)
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) }
            }
            source.resume()
            signalSources.append(source)
        }
        power.onEvent = { [weak self] event in self?.log(event) }
        show(latestState)
        if preview {
            if arguments.contains("--preview-on") { togglePower() }
        } else {
            // 通常起動は常にOFF。検証時だけ明示フラグでONを要求できる。
            if arguments.contains("--verify-start-on") {
                worker.async { [weak self] in
                    guard let self else { return }
                    let state = self.protection.setEnabled(true)
                    DispatchQueue.main.async { self.show(state) }
                }
            }
            startTimer()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        if let path = argument(after: "--render-preview"), preview {
            renderWindow = NSWindow(contentRect: panel.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            renderWindow?.contentView = panel
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.panel.layoutSubtreeIfNeeded()
                if let bitmap = self.panel.bitmapImageRepForCachingDisplay(in: self.panel.bounds) {
                    self.panel.cacheDisplay(in: self.panel.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
        } else if preview || arguments.contains("--show-window") {
            openPopover()
        }
        if let path = argument(after: "--record-launch") {
            for seconds in [0, 2, 8] {
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { self.recordLaunch(path, seconds: seconds) }
            }
        }
        if let path = argument(after: "--verify-toggle"), !preview {
            // 本番と同じNSButtonのactionを通し、起動OFF→ON→OFF→ON→終了を検証する。
            for seconds in [2, 6, 10] {
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { self.panel.powerButton.performClick(nil) }
            }
            for seconds in [1, 5, 9, 13] {
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { self.recordLaunch(path, seconds: seconds) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { NSApp.terminate(nil) }
        }
    }

    private func argument(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), arguments.count > i + 1 else { return nil }
        return arguments[i + 1]
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.reconcile() }
        timer.resume()
        self.timer = timer
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPopover(); return true
    }

    @objc private func woke() { worker.async { [weak self] in self?.reconcile() } }

    private func reconcile() {
        guard !stopping else { return }
        let state = protection.reconcile()
        let detail = state.enabled ? (state.protection?.detail ?? "保護を確認中") : "保護OFF"
        if lastDetail != detail { log(detail); lastDetail = detail }
        DispatchQueue.main.async { [weak self] in self?.show(state) }
    }

    private func show(_ state: ProtectionSwitchState) {
        latestState = state
        panel.show(state, preview: preview)
        popover.contentSize = panel.contentSize
        panel.setFrameSize(popover.contentSize)
        statusItem?.button?.image = StatusDotIcon.make(on: state.confirmedOn)
        statusItem?.button?.toolTip = "AntiSleep — " + (state.confirmedOn ? "スリープ防止ON" : (state.enabled ? "保護の確認が必要" : "OFF"))
    }

    @objc private func togglePower() {
        if preview {
            let enabled = !latestState.enabled
            show(ProtectionSwitchState(enabled: enabled, protection: enabled
                ? ProtectionStatus(idleProtected: true, lidProtected: true, detail: "プレビュー") : nil))
            return
        }
        let requested = !latestState.enabled
        panel.setWorking(true)
        worker.async { [weak self] in
            guard let self, !self.stopping else { return }
            let state = self.protection.setEnabled(requested)
            self.log("保護切替 要求=\(requested) 適用確認=\(state.confirmedOn) 復元失敗=\(state.restoreFailed)")
            DispatchQueue.main.async {
                self.panel.setWorking(false)
                self.show(state)
            }
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            exitMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        guard let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func installHelper() {
        guard !preview, let resources = Bundle.main.resourceURL else { return }
        let script = resources.appendingPathComponent("install-helper.sh").path
        let binary = resources.appendingPathComponent("anti-sleep-pmset").path
        let command = ["/bin/zsh", script, binary, NSUserName()].map(Self.shellQuote).joined(separator: " ")
        let quoted = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        worker.async { [weak self] in
            let result = Command.run("/usr/bin/osascript", ["-e", "do shell script \"\(quoted)\" with administrator privileges"], timeout: 180)
            DispatchQueue.main.async {
                if result.status != 0 { self?.alert("ヘルパーを設定できませんでした。", detail: "認証が取り消されたか、設定に失敗しました。既存の保護は継続します。") }
            }
            self?.reconcile()
        }
    }

    private static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if preview { return .terminateNow }
        panel.setWorking(true)
        worker.async { [weak self] in
            guard let self else { return }
            self.stopping = true
            self.timer?.cancel()
            let restored = self.protection.shutdown()
            self.log("終了時の復元 成功=\(restored)")
            if restored { exit(0) }
            self.stopping = false
            self.startTimer()
            RunLoop.main.perform(inModes: [.common]) {
                self.panel.setWorking(false)
                self.alert("元の設定に戻せなかったため、終了を中止しました。", detail: "ヘルパーを設定し直してから、もう一度終了してください。")
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    private func alert(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    private func log(_ text: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AntiSleep")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("app.log")
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 262_144 {
            let previous = directory.appendingPathComponent("previous.log")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: url, to: previous)
        }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let file = try? FileHandle(forWritingTo: url) {
            defer { try? file.close() }
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: Data("\(ISO8601DateFormatter().string(from: Date())) \(text)\n".utf8))
        }
    }

    private func recordLaunch(_ path: String, seconds: Int) {
        let assertions = Command.run("/usr/bin/pmset", ["-g", "assertions"]).output
        let own = assertions.components(separatedBy: "\n   pid ").filter { $0.hasPrefix("\(getpid())(") }.joined()
        let menuFrame = statusItem?.button?.window?.frame
        let menuScreen = statusItem?.button?.window?.screen
        let rightArea = menuScreen?.auxiliaryTopRightArea ?? menuScreen?.frame
        let onRight: Bool
        if let frame = menuFrame, let area = rightArea {
            onRight = frame.minX >= area.minX && frame.maxX <= area.maxX + 1
        } else {
            onRight = false
        }
        launchSnapshots.append([
            "seconds": seconds, "pid": getpid(),
            "menuBarItemCreated": statusItem != nil,
            "menuBarVisible": statusItem?.isVisible ?? false,
            "menuBarOnRight": onRight,
            "menuBarX": statusItem?.button?.window?.frame.minX as Any? ?? NSNull(),
            "menuBarWidth": statusItem?.button?.window?.frame.width as Any? ?? NSNull(),
            "windowVisible": popover.isShown, "appActive": NSApp.isActive,
            "enabled": latestState.enabled, "confirmedOn": latestState.confirmedOn,
            "sleepDisabled": power.readSleepDisabled() as Any? ?? NSNull(),
            "idleProtected": own.contains("PreventUserIdleSystemSleep"),
            "displayAssertion": own.contains("PreventUserIdleDisplaySleep")
        ])
        if let data = try? JSONSerialization.data(withJSONObject: launchSnapshots, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

import AppKit
import AntiSleepCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preview = ProcessInfo.processInfo.arguments.contains("--preview")
    private let worker = DispatchQueue(label: "app.antisleep.protection")
    private let power = SystemPower()
    private lazy var session = ProtectionSession(backend: power)
    private var timer: DispatchSourceTimer?
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var message: NSTextField!
    private var headline: NSTextField!
    private var idleValue: NSTextField!
    private var lidValue: NSTextField!
    private var menuStatus: NSMenuItem!
    private var stopping = false
    private var lastDetail = ""
    private var signalSources: [DispatchSourceSignal] = []
    private var latestStatus: ProtectionStatus?
    private var launchSnapshots: [[String: Any]] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua)
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "app.antisleep.AntiSleep")
            .filter { $0.processIdentifier != getpid() && !$0.isTerminated && $0.activationPolicy != .prohibited }
        if !preview, !others.isEmpty { exit(0) }
        buildMenu()
        buildWindow()
        if ProcessInfo.processInfo.arguments.contains("--window-id") {
            print(window.windowNumber)
            fflush(stdout)
        }
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
        if preview {
            show(ProtectionStatus(idleProtected: true, lidProtected: true,
                                  detail: "プレビューです。電源設定は変更していません。"))
        } else {
            let timer = DispatchSource.makeTimerSource(queue: worker)
            timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.reconcile() }
            timer.resume()
            self.timer = timer
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        if preview || ProcessInfo.processInfo.arguments.contains("--show-window") {
            openWindow()
        }
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--record-launch"),
           ProcessInfo.processInfo.arguments.count > index + 1 {
            let path = ProcessInfo.processInfo.arguments[index + 1]
            for seconds in [0, 2, 8] {
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self] in
                    self?.recordLaunch(path, seconds: seconds)
                }
            }
        }
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "--render-preview"),
           ProcessInfo.processInfo.arguments.count > i + 1, preview {
            let path = ProcessInfo.processInfo.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.renderPreview(path)
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow(); return true
    }

    @objc private func woke() { worker.async { [weak self] in self?.reconcile() } }

    private func reconcile() {
        guard !stopping else { return }
        let state = session.reconcile()
        if lastDetail != state.detail { log(state.detail); lastDetail = state.detail }
        DispatchQueue.main.async { [weak self] in self?.show(state) }
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "AntiSleep")
        statusItem.button?.toolTip = "AntiSleep — 保護を確認中"
        let menu = NSMenu()
        menuStatus = menu.addItem(withTitle: "保護を確認中…", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        addItem(menu, "AntiSleepを開く", #selector(openWindow))
        addItem(menu, "画面を消灯", #selector(turnOffDisplay))
        menu.addItem(.separator())
        addItem(menu, "終了して元の設定へ戻す", #selector(quit), key: "q")
        statusItem.menu = menu
    }

    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
    }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        return field
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 444, height: 450),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = preview ? "AntiSleep — プレビュー" : "AntiSleep"
        window.isReleasedWhenClosed = false
        window.center()
        let content = WindowContentView()
        window.contentView = content
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 17
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28)
        ])
        stack.addArrangedSubview(label("AntiSleep", size: 26, weight: .bold))
        headline = label("保護を確認しています…", size: 17, weight: .semibold)
        stack.addArrangedSubview(headline)
        let hint = label("このアプリの起動中は、ふたを閉じても処理を継続。\n画面の消灯は妨げません。", size: 13)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
        idleValue = label("確認中")
        lidValue = label("確認中")
        let grid = NSGridView(views: [
            [label("本体の自動スリープ"), idleValue],
            [label("ふたを閉じたとき"), lidValue],
            [label("画面"), label("消灯を許可・ふた閉じで消灯")],
            [label("Caps Lock"), label("保護には影響しません")]
        ])
        grid.rowSpacing = 11
        grid.columnSpacing = 18
        stack.addArrangedSubview(grid)
        message = label("")
        message.textColor = .secondaryLabelColor
        message.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        stack.addArrangedSubview(message)
        let buttons = NSStackView()
        buttons.spacing = 8
        buttons.addArrangedSubview(NSButton(title: "画面を消灯", target: self, action: #selector(turnOffDisplay)))
        buttons.addArrangedSubview(NSButton(title: "ヘルパーを設定…", target: self, action: #selector(installHelper)))
        stack.addArrangedSubview(buttons)
        stack.addArrangedSubview(NSButton(title: "終了して元の設定へ戻す", target: self, action: #selector(quit)))
        let note = label("ウィンドウを閉じても保護は続きます。終了はメニューバーから。", size: 11)
        note.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(note)
        for view in [hint, message!, note] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func show(_ state: ProtectionStatus) {
        latestStatus = state
        let protected = state.idleProtected && state.lidProtected
        headline.stringValue = protected ? "起動中 · 本体のスリープを防止" : "保護に確認が必要です"
        headline.textColor = protected ? .systemGreen : .systemOrange
        idleValue.stringValue = state.idleProtected ? "防止中" : "未適用"
        lidValue.stringValue = state.lidProtected ? "本体は保護中" : "未適用"
        message.stringValue = state.detail
        menuStatus.title = protected ? "本体のスリープを防止中" : "ふた閉じ保護を確認してください"
        statusItem.button?.image = NSImage(systemSymbolName: protected ? "shield.checkered" : "exclamationmark.shield",
                                           accessibilityDescription: headline.stringValue)
        statusItem.button?.toolTip = "AntiSleep — \(headline.stringValue)"
    }

    @objc private func openWindow() {
        worker.async { [weak self] in self?.log("明示的なウィンドウ表示要求") }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func turnOffDisplay() {
        guard !preview else { return }
        worker.async { [weak self] in
            guard let self else { return }
            if !self.power.turnDisplaysOff() {
                DispatchQueue.main.async { self.alert("画面を消灯できませんでした。", detail: "本体の保護は継続しています。") }
            }
        }
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
        worker.async { [weak self] in
            guard let self else { return }
            self.stopping = true
            self.timer?.cancel()
            let restored = self.session.stop()
            self.log("終了時の復元 成功=\(restored)")
            // 終了通知元のイベントループに依存せず、復元完了後に終了する。
            if restored { exit(0) }
            self.stopping = false
            let timer = DispatchSource.makeTimerSource(queue: self.worker)
            timer.schedule(deadline: .now(), repeating: 2)
            timer.setEventHandler { [weak self] in self?.reconcile() }
            timer.resume()
            self.timer = timer
            RunLoop.main.perform(inModes: [.common]) {
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

    private func renderPreview(_ path: String) {
        let result = Command.run("/usr/sbin/screencapture", ["-x", "-l", String(window.windowNumber), path])
        if result.status != 0 {
            log("画面収録は利用不可。アプリ自身のビューを画像化: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    private func recordLaunch(_ path: String, seconds: Int) {
        launchSnapshots.append([
            "seconds": seconds,
            "windowVisible": window.isVisible,
            "appActive": NSApp.isActive,
            "idleProtected": latestStatus?.idleProtected ?? false,
            "lidProtected": latestStatus?.lidProtected ?? false
        ])
        if let data = try? JSONSerialization.data(withJSONObject: launchSnapshots, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

private final class WindowContentView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

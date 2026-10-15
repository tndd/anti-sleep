#!/usr/bin/env python3
"""検証用コピーにだけ操作を追加し、実ボタンの終了経路と監視の再試行を確認する。"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("report", type=Path)
args = parser.parse_args()
args.report.unlink(missing_ok=True)
root = Path(__file__).resolve().parents[1]
output = args.report.resolve().parent
output.mkdir(parents=True, exist_ok=True)
source = output / "quit-source"
source.mkdir(exist_ok=True)
for name in ["Sources", "Tests"]:
    shutil.copytree(root / name, source / name, dirs_exist_ok=True)
shutil.copy2(root / "Package.swift", source)

# 操作・障害注入はこのコピーだけに追加し、配布版には検証用の終了操作を設けない。
delegate = source / "Sources/AntiSleep/AppDelegate.swift"
text = delegate.read_text().replace(
    '    private func argument(after flag: String) -> String? {',
    '''    private func verifyQuit() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.openPopover()
            self.panel.layoutSubtreeIfNeeded()
            self.recordLaunch(ProcessInfo.processInfo.environment["QUIT_RECORD"]!, seconds: 2)
            let bitmap = self.panel.bitmapImageRepForCachingDisplay(in: self.panel.bounds)!
            self.panel.cacheDisplay(in: self.panel.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(
                to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["QUIT_IMAGE"]!))
            self.clickQuitForVerification()
        }
    }

    private func clickQuitForVerification() {
        precondition(panel.quitButton.isEnabled && popover.isShown)
        let window = panel.window!
        let point = panel.quitButton.convert(NSPoint(x: 14, y: 14), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            NSApp.postEvent(event, atStart: false)
        }
    }

    private func argument(after flag: String) -> String? {''')
needle = '        if let path = argument(after: "--verify-toggle"), !preview {'
text = text.replace(needle, '        if ProcessInfo.processInfo.environment["QUIT_RECORD"] != nil { verifyQuit() }\n' + needle)
text = text.replace('        alert.runModal()', '''        if ProcessInfo.processInfo.environment["QUIT_RETRY"] == "1" {
            precondition(panel.quitButton.isEnabled && !terminationPending)
            try! Data(messageForVerification.utf8).write(to: URL(fileURLWithPath:
                ProcessInfo.processInfo.environment["QUIT_RECORD"]! + ".cancelled"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.clickQuitForVerification() }
        } else { alert.runModal() }'''.replace('messageForVerification', 'title'))
delegate.write_text(text)
power = source / "Sources/AntiSleep/SystemPower.swift"
text = power.read_text().replace('    private var assertion =', '    private var failRestoreOnce = ProcessInfo.processInfo.environment["QUIT_RETRY"] == "1"\n    private var assertion =')
text = text.replace('    func setSleepDisabled(_ disabled: Bool) -> Bool {', '''    func setSleepDisabled(_ disabled: Bool) -> Bool {
        if !disabled && failRestoreOnce { failRestoreOnce = false; return false }''')
# 監視だけを動かす試験ではpmsetへ書かず、4回の見かけ上の成功と実値不一致を作る。
assert text.count('    static func run(_ path: String, disabled: Bool) -> Bool {') == 1
assert text.count('    static func sleepDisabled() -> Bool? {') == 1
text = text.replace('    static func run(_ path: String, disabled: Bool) -> Bool {', '''    static func run(_ path: String, disabled: Bool) -> Bool {
        if let path = ProcessInfo.processInfo.environment["MONITOR_STATE"] {
            if ProcessInfo.processInfo.environment["MONITOR_INFLIGHT"] == "1" {
                if disabled { try! "1".write(toFile: path + ".started", atomically: true, encoding: .utf8) }
                Thread.sleep(forTimeInterval: 1)
                try! (disabled ? "1" : "0").write(toFile: path, atomically: true, encoding: .utf8)
                return true
            }
            let countPath = path + ".attempts"
            let count = (try? String(contentsOfFile: countPath)).flatMap(Int.init) ?? 0
            try! String(count + 1).write(toFile: countPath, atomically: true, encoding: .utf8)
            if count >= 4 { try! "0".write(toFile: path, atomically: true, encoding: .utf8) }
            return true
        }''')
text = text.replace('    static func sleepDisabled() -> Bool? {', '''    static func sleepDisabled() -> Bool? {
        if let path = ProcessInfo.processInfo.environment["MONITOR_STATE"] {
            return (try? String(contentsOfFile: path)) == "1"
        }''')
power.write_text(text)
build = subprocess.run(["swift", "build", "-c", "release", "--package-path", str(source), "--product", "AntiSleep"], capture_output=True, text=True)
assert build.returncode == 0, build.stderr
binary = source / ".build/release/AntiSleep"
app = output / "QuitCheck.app"
app.mkdir(exist_ok=True)
(app / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
shutil.copy2(binary, app / "Contents/MacOS/AntiSleep")
(app / "Contents/Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "app.antisleep.QuitCheck", "CFBundleExecutable": "AntiSleep",
    "CFBundlePackageType": "APPL", "LSUIElement": True,
}))
binary = app / "Contents/MacOS/AntiSleep"
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)


def disabled():
    lines = subprocess.check_output(["/usr/bin/pmset", "-g"], text=True).splitlines()
    return next(line.split()[1] == "1" for line in lines if line.strip().startswith("SleepDisabled"))


def monitors():
    return [line for line in subprocess.check_output(["/bin/ps", "-axo", "pid=,command="], text=True).splitlines()
            if str(binary) in line and "--restore-on-exit" in line]


assert not disabled(), "既存の保護をOFFにしてから実行してください"
checks = []
for mode in ["off", "on", "retry"]:
    record = output / f"quit-{mode}.json"
    record.unlink(missing_ok=True)
    Path(str(record) + ".cancelled").unlink(missing_ok=True)
    env = dict(os.environ, QUIT_RECORD=str(record), QUIT_IMAGE=str(record.with_suffix(".png")),
               QUIT_RETRY="1" if mode == "retry" else "0")
    options = ["--verify-start-on"] if mode != "off" else []
    p = subprocess.Popen([str(binary), *options], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        _, error = p.communicate(timeout=30)
        assert p.returncode == 0, error.decode()
        state = json.loads(record.read_text())[-1]
        assert state["windowVisible"] and state["enabled"] == (mode != "off"), state
        assert state["confirmedOn"] == (mode != "off"), state
        assert not disabled(), "終了後にSleepDisabledが残っています"
        assert not monitors(), "終了後に監視が残っています"
        assertions = subprocess.check_output(["/usr/bin/pmset", "-g", "assertions"], text=True)
        assert f"pid {p.pid}(" not in assertions, "終了したアプリの防止要求が残っています"
        if mode == "retry":
            assert Path(str(record) + ".cancelled").exists(), "復元失敗時の終了中止を通っていません"
        checks.append(f"パネルの×をマウスイベントで押して終了・復元・監視停止: {mode}")
    finally:
        if p.poll() is None:
            p.terminate()
            p.communicate(timeout=20)

state = output / "monitor-state"
state.write_text("1")
Path(str(state) + ".attempts").unlink(missing_ok=True)
helper = next(path for path in ["/Library/PrivilegedHelperTools/anti-sleep-pmset",
                              "/Library/PrivilegedHelperTools/capsomnia-pmset"] if Path(path).exists())
p = subprocess.Popen([str(binary), "--restore-on-exit", helper, "0"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=dict(os.environ, MONITOR_STATE=str(state)))
try:
    assert p.stdout.readline() == b"ready\n"
    for sig in [signal.SIGTERM, signal.SIGINT, signal.SIGHUP]:
        p.send_signal(sig)
    time.sleep(.2)
    assert p.poll() is None, "復元監視が通常のシグナルで終了しました"
    p.stdin.close()
    assert p.wait(timeout=30) == 0
    assert state.read_text() == "0" and Path(str(state) + ".attempts").read_text() == "5"
    assert not disabled(), "監視の模擬試験が実システム設定を変更しました"
    checks.append("監視はTERM・INT・HUPに耐え、4回の実値不一致後も5回目で復元")
finally:
    if p.poll() is None:
        p.kill()
        p.wait()
state.write_text("0")
Path(str(state) + ".started").unlink(missing_ok=True)
p = subprocess.Popen([str(binary), "--restore-on-exit", helper, "0"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     env=dict(os.environ, MONITOR_STATE=str(state), MONITOR_INFLIGHT="1"))
try:
    assert p.stdout.readline() == b"ready\n"
    p.stdin.write(b"on\n")
    p.stdin.flush()
    deadline = time.monotonic() + 5
    while not Path(str(state) + ".started").exists():
        assert time.monotonic() < deadline, "設定変更が開始されません"
        time.sleep(.05)
    # 親が設定変更の途中で落ち、応答も受け取れなくなった条件を再現する。
    p.stdin.close()
    p.stdout.close()
    assert p.wait(timeout=10) == 0
    assert state.read_text() == "0", "復元の後で遅延したONが適用されました"
    checks.append("設定変更中に親と応答先が消失しても、変更完了後に復元")
finally:
    if p.poll() is None:
        p.kill()
        p.wait()
result = {"result": "PASS", "checks": checks,
          "scope": "アプリ自身のイベントキューへの入力。物理マウス操作・OS全画面の取得とは区別する。"}
args.report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(result, ensure_ascii=False, indent=2))

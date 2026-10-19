#!/usr/bin/env python3
"""起動時設定の保存、実スイッチ操作、再起動、プレビュー分離を実機で確認する。

実行中のAntiSleepは先に終了する。設定は終了時に元へ戻す。
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=Path)
parser.add_argument("report", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
output = args.report.resolve().parent
output.mkdir(parents=True, exist_ok=True)
domain, key = "app.antisleep.AntiSleep", "startOnLaunch"


def disabled():
    text = subprocess.check_output(["/usr/bin/pmset", "-g"], text=True)
    return next(line.split()[1] == "1" for line in text.splitlines()
                if line.strip().startswith("SleepDisabled"))


def choice():
    return subprocess.run(["defaults", "read", domain, key], capture_output=True, text=True)


assert not disabled(), "開始時にSleepDisabled=0を確認してください"
previous = choice()
source = output / "startup-source"
source.mkdir(exist_ok=True)
for name in ["Sources", "Tests"]:
    shutil.copytree(root / name, source / name, dirs_exist_ok=True)
shutil.copy2(root / "Package.swift", source)
delegate = source / "Sources/AntiSleep/AppDelegate.swift"
text = delegate.read_text()
needle = '        if let path = argument(after: "--render-preview"), preview {'
assert text.count(needle) == 1
text = text.replace(needle, '''        if let record = ProcessInfo.processInfo.environment["STARTUP_QA_RECORD"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.openPopover()
                self.panel.layoutSubtreeIfNeeded()
                let control = self.panel.startupSwitch
                let window = self.panel.window!
                let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                    NSApp.postEvent(event, atStart: false)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.recordLaunch(record, seconds: 3)
                let bitmap = self.panel.bitmapImageRepForCachingDisplay(in: self.panel.bounds)!
                self.panel.cacheDisplay(in: self.panel.bounds, to: bitmap)
                try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: record + ".png"))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { NSApp.terminate(nil) }
        }
''' + needle)
text = text.replace('"enabled": latestState.enabled,',
                    '"panelWidth": panel.bounds.width, "panelHeight": panel.bounds.height, "enabled": latestState.enabled,')
delegate.write_text(text)
subprocess.run(["swift", "build", "-c", "release", "--package-path", str(source)], check=True)
qa_app = output / "StartupCheck.noindex" / "AntiSleep.app"
shutil.copytree(args.app, qa_app, dirs_exist_ok=True)
shutil.copy2(source / ".build/release/AntiSleep", qa_app / "Contents/MacOS/AntiSleep")
subprocess.run(["codesign", "--force", "--sign", "-", str(qa_app)], check=True)
results = {}


def launch(name, app, expected_on, expected_choice, click=False, preview=False):
    record = output / (name + ".json")
    record.unlink(missing_ok=True)
    env = dict(os.environ)
    options = []
    if click:
        env["STARTUP_QA_RECORD"] = str(record)
    else:
        options += ["--record-launch", str(record)]
    if preview:
        options.append("--preview")
    process = subprocess.Popen([str(app / "Contents/MacOS/AntiSleep"), *options], env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 18
        while time.monotonic() < deadline:
            if record.exists():
                samples = json.loads(record.read_text())
                if len(samples) >= (1 if click else 3):
                    break
            assert process.poll() is None, "起動記録なし。既存のAntiSleepを終了してください"
            time.sleep(.2)
        else:
            raise AssertionError("起動記録の期限切れ")
        for state in samples:
            if state["seconds"] < 2:
                continue
            assert state["enabled"] == expected_on, state
            assert state["confirmedOn"] == expected_on, state
            assert state["sleepDisabled"] == expected_on, state
            assert state["idleProtected"] == expected_on, state
            assert not state["displayAssertion"], state
            assert state["startsOn"] == expected_choice, state
            if click and not preview:
                assert state["panelWidth"] == 300 and state["panelHeight"] == 324, state
        if click:
            process.communicate(timeout=15)
        results[name] = samples
    finally:
        if process.poll() is None:
            process.terminate()
        process.communicate(timeout=20)
    assert process.returncode == 0
    assert not disabled(), "終了後の復元を確認できません"


try:
    subprocess.run(["defaults", "delete", domain, key], capture_output=True)
    launch("default-off", args.app.resolve(), False, False)
    launch("click-on-while-off", qa_app, False, True, click=True)
    assert choice().stdout.strip() == "1"
    launch("relaunch-on", args.app.resolve(), True, True)
    launch("click-off-while-on", qa_app, True, False, click=True)
    assert choice().stdout.strip() == "0"
    launch("relaunch-off", args.app.resolve(), False, False)
    launch("preview-isolated", qa_app, False, True, click=True, preview=True)
    assert choice().stdout.strip() == "0", "プレビューが本番設定を変更しました"
    subprocess.run([sys.executable, str(root / "scripts/verify-panel-pixels.py"),
                    str(output / "click-on-while-off.json.png"),
                    str(output / "click-off-while-on.json.png"),
                    "--report", str(output / "startup-pixels.json")], check=True)
    args.report.write_text(json.dumps({"result": "PASS", "checks": results}, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"result": "PASS", "checks": list(results)}, ensure_ascii=False))
finally:
    if previous.returncode == 0:
        subprocess.run(["defaults", "write", domain, key, "-bool", previous.stdout.strip()], check=True)
    else:
        subprocess.run(["defaults", "delete", domain, key], capture_output=True)

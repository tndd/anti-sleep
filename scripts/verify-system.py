#!/usr/bin/env python3
"""実Mac専用。設定の再適用・終了時の復元を実際のヘルパーで確認する。"""
import argparse
import datetime
import json
import os
import re
from pathlib import Path
import signal
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
parser.add_argument("report", type=Path)
parser.add_argument("--screen-off", action="store_true", help="画面を約70秒間消灯する")
args = parser.parse_args()
binary = args.app.resolve() / "Contents/MacOS/AntiSleep"
report = {"checks": {}, "physical_lid_test": "未検証"}
process = None
monitor_pid = None


def command(*cmd):
    return subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT).strip()


def disabled():
    for line in command("/usr/bin/pmset", "-g").splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] == "SleepDisabled":
            return parts[1] == "1"
    raise AssertionError("SleepDisabledが取得できません")


def wait_for(test, label, timeout=15):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if test():
            return
        time.sleep(.2)
    raise AssertionError(label)


def owner_assertions(pid):
    blocks = command("/usr/bin/pmset", "-g", "assertions").split("\n   pid ")
    return "\n".join(b for b in blocks if b.startswith(f"{pid}("))


def monitor(parent):
    for line in command("/bin/ps", "-axo", "pid=,ppid=,command=").splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3 and fields[1] == str(parent) and "--restore-on-exit" in fields[2]:
            return int(fields[0])
    return None


def launch():
    global process, monitor_pid
    process = subprocess.Popen([str(binary), "--verify-start-on"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    wait_for(disabled, "起動後にふた閉じ保護が適用されません")

    owned = owner_assertions(process.pid)
    assert "PreventUserIdleSystemSleep" in owned, "アプリ自身の防止要求がありません"
    assert "PreventUserIdleDisplaySleep" not in owned, "画面点灯要求が登録されています"
    monitor_pid = monitor(process.pid)
    assert monitor_pid, "復元監視プロセスがありません"



try:
    if "/Applications/Capsomnia.app/Contents/MacOS/Capsomnia" in command("/bin/ps", "-axo", "comm="):
        raise AssertionError("旧版Capsomniaを正常終了してから実行してください")
    assert disabled() is False, "開始時にSleepDisabled=0であることを確認してください"
    helpers = ["/Library/PrivilegedHelperTools/anti-sleep-pmset", "/Library/PrivilegedHelperTools/capsomnia-pmset"]
    helper = next((p for p in helpers if Path(p).is_file()), None)
    assert helper, "管理者ヘルパーがありません"

    launch()
    report["checks"]["起動時に独立した防止要求とSleepDisabled=1"] = "PASS"
    report["checks"]["画面点灯要求なし"] = "PASS"
    command("/usr/bin/sudo", "-n", helper, "off")
    wait_for(disabled, "解除された保護が再適用されません")
    report["checks"]["実際の設定解除から再適用"] = "PASS"
    os.kill(monitor_pid, signal.SIGKILL)
    wait_for(lambda: monitor(process.pid) not in (None, monitor_pid), "監視プロセスが再起動されません")
    report["checks"]["復元監視の異常終了から再起動"] = "PASS"
    process.send_signal(signal.SIGTERM)
    process.wait(timeout=20)
    wait_for(lambda: not disabled(), "通常終了後に設定が復元されません")
    assert not owner_assertions(process.pid), "終了後に防止要求が残っています"
    report["checks"]["通常終了で設定と防止要求を復元"] = "PASS"
    process = None

    launch()
    if args.screen_off:
        start = time.monotonic()
        wall_start = time.time()
        command("/usr/bin/pmset", "displaysleepnow")
        ticks = [time.monotonic()]
        for _ in range(70):
            time.sleep(1)
            ticks.append(time.monotonic())
        max_gap = max(b - a for a, b in zip(ticks, ticks[1:]))
        assert max_gap < 3, f"処理の停止を検出: {max_gap:.2f}秒"
        assert disabled()
        wall_end = time.time()
        events = []
        for line in command("/usr/bin/pmset", "-g", "log").splitlines():
            match = re.search(r"Display is turned (off|on)", line)
            if not match:
                continue
            stamp = datetime.datetime.strptime(line[:25], "%Y-%m-%d %H:%M:%S %z").timestamp()
            if wall_start - 1 <= stamp <= wall_end:
                events.append((stamp, match[1]))
        off = next((stamp for stamp, state in events if state == "off"), None)
        assert off is not None, "実際の画面消灯イベントがありません"
        assert not any(state == "on" and stamp >= off for stamp, state in events), "検証中に画面が点灯しました。この区間は消灯試験として採用しません"
        assert wall_end - off >= 69, "消灯の継続時間が不足しています"
        report["checks"]["明示消灯中70秒の処理継続"] = "PASS"
        report["display_off_seconds"] = round(wall_end - off, 2)
        report["heartbeat"] = {"ticks": len(ticks), "maximum_gap_seconds": round(max_gap, 3),
                               "elapsed_seconds": round(time.monotonic() - start, 3)}
        command("/usr/bin/caffeinate", "-u", "-t", "1")
    process.kill()
    process.wait(timeout=10)
    wait_for(lambda: not disabled(), "強制終了後に監視側が復元しません")
    report["checks"]["親プロセス強制終了で監視側が設定復元"] = "PASS"
    process = None
    report["result"] = "PASS"
except Exception as error:
    report["result"] = "FAIL"
    report["error"] = str(error)
finally:
    if process is not None and process.poll() is None:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))
raise SystemExit(0 if report.get("result") == "PASS" else 1)

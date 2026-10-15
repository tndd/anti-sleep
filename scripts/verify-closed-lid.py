#!/usr/bin/env python3
"""稼働中のAntiSleepで実際のふた閉じ・消灯・処理継続を測定する。設定は変更しない。"""
import argparse
import ctypes
import datetime
import json
from pathlib import Path
import re
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--pid', required=True, type=int)
parser.add_argument('--report', type=Path, default=Path('test-results/closed-lid-check.json'))
parser.add_argument('--required-seconds', type=int, default=70)
parser.add_argument('--timeout', type=int, default=300)
args = parser.parse_args()

class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]

lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
lib.mach_continuous_time.restype = ctypes.c_uint64
base = Timebase()
assert lib.mach_timebase_info(ctypes.byref(base)) == 0

def continuous():
    # mach_absolute_timeと異なり、システムスリープ中も進む時計を使用する。
    return lib.mach_continuous_time() * base.numer / base.denom / 1e9

def command(*parts):
    return subprocess.check_output(parts, text=True, stderr=subprocess.STDOUT, timeout=6)

def lid_closed():
    text = command('/usr/sbin/ioreg', '-r', '-c', 'IOPMrootDomain', '-d', '1')
    match = re.search(r'"AppleClamshellState"\s*=\s*(Yes|No)', text)
    assert match, 'ふたの実状態を取得できません'
    return match[1] == 'Yes'

def verify_protection():
    settings = command('/usr/bin/pmset', '-g')
    assert re.search(r'^\s*SleepDisabled\s+1\s*$', settings, re.M), 'ふた閉じ保護が解除されています'
    assertions = command('/usr/bin/pmset', '-g', 'assertions')
    owned = '\n'.join(b for b in assertions.split('\n   pid ') if b.startswith(f'{args.pid}(AntiSleep)'))
    assert 'PreventUserIdleSystemSleep' in owned, '対象AntiSleepの防止要求がありません'
    assert 'PreventUserIdleDisplaySleep' not in owned, '対象AntiSleepが画面点灯を要求しています'
    assert '(caffeinate)' not in assertions, 'caffeinateが残っているため、独立した試験として採用できません'

report = {'result': 'RUNNING', 'pid': args.pid, 'clock': 'mach_continuous_time', 'samples': []}
try:
    verify_protection()
    assert not lid_closed(), '開始時にふたを開けてください'
    start_wall, start_cont = time.time(), continuous()
    previous = start_cont
    closed_at = None
    closed_wall = None
    max_gap = 0
    print('ARMED: 測定を開始しました。ふたを閉じて90秒待ち、開けてください。', flush=True)
    while continuous() - start_cont < args.timeout:
        now = continuous()
        gap = now - previous
        max_gap = max(max_gap, gap)
        previous = now
        assert gap < 3, f'処理の停止を検出しました: {gap:.3f}秒'
        closed = lid_closed()
        wall = time.time()
        report['samples'].append({'elapsed': round(now - start_cont, 3), 'closed': closed})
        if len(report['samples']) % 5 == 1:
            verify_protection()
        if closed and closed_at is None:
            closed_at, closed_wall = now, wall
            print('ふた閉じを実検出。処理の連続性を測定中。', flush=True)
        if not closed and closed_at is not None:
            duration = now - closed_at
            assert duration >= args.required_seconds, f'ふた閉じ時間が不足しています: {duration:.2f}秒'
            break
        time.sleep(.9)
    else:
        raise AssertionError('制限時間内に、ふたを閉じて再び開く操作を確認できませんでした')

    verify_protection()
    end_wall = time.time()
    events = []
    for line in command('/usr/bin/pmset', '-g', 'log').splitlines():
        if not ('Display is turned' in line or 'Entering Sleep state' in line):
            continue
        try:
            stamp = datetime.datetime.strptime(line[:25], '%Y-%m-%d %H:%M:%S %z').timestamp()
        except ValueError:
            continue
        if not start_wall - 1 <= stamp <= end_wall:
            continue
        assert 'Entering Sleep state' not in line, '測定区間内に本体のスリープ記録があります'
        match = re.search(r'Display is turned (off|on)', line)
        if match:
            events.append((stamp, match[1]))
    off = None
    off_durations = []
    for stamp, state in events:
        if state == 'off' and off is None:
            off = stamp
        elif state == 'on' and off is not None:
            off_durations.append(max(0, min(stamp, end_wall) - max(off, closed_wall)))
            off = None
    if off is not None:
        off_durations.append(max(0, end_wall - max(off, closed_wall)))
    longest_off = max(off_durations, default=0)
    assert longest_off >= args.required_seconds, f'ふた閉じ中の実消灯時間が不足しています: {longest_off:.2f}秒'
    report.update(result='PASS', closed_seconds=round(duration, 3), display_off_seconds=round(longest_off, 3),
                  max_heartbeat_gap_seconds=round(max_gap, 3), heartbeat_count=len(report['samples']),
                  system_sleep_events=0, recovered_open_state=True,
                  display_events=[{'time': datetime.datetime.fromtimestamp(t).astimezone().isoformat(), 'state': s} for t, s in events])
except Exception as error:
    report.update(result='FAIL', error=str(error))
finally:
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'samples'}, ensure_ascii=False, indent=2), flush=True)
raise SystemExit(0 if report['result'] == 'PASS' else 1)

#!/usr/bin/env python3
"""実際の電源ボタンactionと電源設定を検証する。実行中のAntiSleepは先に終了する。"""
import argparse
import json
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('report', type=Path)
args = parser.parse_args()
binary = args.app.resolve() / 'Contents/MacOS/AntiSleep'
args.report.parent.mkdir(parents=True, exist_ok=True)


def disabled():
    output = subprocess.check_output(['/usr/bin/pmset', '-g'], text=True)
    return next(line.split()[1] == '1' for line in output.splitlines() if line.strip().startswith('SleepDisabled'))


def run(*options, timeout=25):
    result = subprocess.run([str(binary), *options], capture_output=True, text=True, timeout=timeout)
    assert result.returncode == 0, result.stderr


assert disabled() is False, '開始時にSleepDisabled=0を確認してください'
sequence = args.report.with_name(args.report.stem + '-sequence.json')
sequence.unlink(missing_ok=True)
run('--verify-toggle', str(sequence))
states = json.loads(sequence.read_text())
assert len(states) == 4, '切り替えの記録がありません。既存のAntiSleepを終了してください'
for state, expected in zip(states, [False, True, False, True]):
    assert state['enabled'] == expected, state
    assert state['confirmedOn'] == expected, state
    assert state['sleepDisabled'] == expected, state
    assert state['idleProtected'] == expected, state
    assert not state['displayAssertion'], state
    assert not state['windowVisible'], state
    assert not state['appActive'], state
assert not disabled(), 'ONでの通常終了後に設定が戻りません'
assert len({state['pid'] for state in states}) == 1, '同一プロセスの切り替えではありません'
# ONで終了した直後の再起動も、記憶したONではなくOFFになることを実アプリで確認する。
relaunch = args.report.with_name(args.report.stem + '-relaunch.json')
relaunch.unlink(missing_ok=True)
process = subprocess.Popen([str(binary), '--record-launch', str(relaunch)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
try:
    import time
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if relaunch.exists() and len(json.loads(relaunch.read_text())) == 3:
            break
        assert process.poll() is None, '再起動したアプリが終了しました'
        time.sleep(.2)
    snapshots = json.loads(relaunch.read_text())
    assert len(snapshots) == 3
    for state in snapshots:
        assert not any(state[key] for key in ['enabled', 'confirmedOn', 'sleepDisabled', 'idleProtected', 'displayAssertion', 'windowVisible', 'appActive']), state
finally:
    process.terminate()
    process.communicate(timeout=20)
assert process.returncode == 0
assert not disabled()
report = {'result': 'PASS', 'checks': [
    '通常起動はOFFで電源設定と防止要求を変更しない',
    '同一アプリの電源ボタンでOFF→ON→OFF→ON',
    'ON時だけSleepDisabledとアプリ自身の防止要求が有効',
    '画面の点灯維持要求を登録しない',
    '切り替えや定期確認でパネルを自動表示しない',
    'ONで終了すると元の設定へ復元',
    '再起動の直後・2秒後・8秒後もOFF・非表示・非アクティブ'
], 'sequence': states, 'relaunch': snapshots}
args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'result': 'PASS', 'checks': report['checks']}, ensure_ascii=False, indent=2))

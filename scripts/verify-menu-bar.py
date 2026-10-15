#!/usr/bin/env python3
"""メニューバーの可視性と、画像プレビューから本番への設定汚染を実アプリで確認する。"""
import argparse
import json
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('report', type=Path)
args = parser.parse_args()
binary = args.app.resolve() / 'Contents/MacOS/AntiSleep'
args.report.parent.mkdir(parents=True, exist_ok=True)
snapshots = args.report.with_name(args.report.stem + '-launch.json')
snapshots.unlink(missing_ok=True)
p = subprocess.Popen([str(binary), '--record-launch', str(snapshots)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)


def wait_for_samples(count):
    end = time.monotonic() + 15
    while time.monotonic() < end:
        assert p.poll() is None, '既存のAntiSleepを終了してから実行してください'
        if snapshots.exists():
            values = json.loads(snapshots.read_text())
            if len(values) >= count:
                return values
        time.sleep(.2)
    raise AssertionError('起動記録がありません')


try:
    before = wait_for_samples(2)
    # 最初のイベント時点はAppKitの配置前（x=0）になり得る。2秒後の配置を確認する。
    assert all(s['menuBarVisible'] for s in before), before
    assert before[-1]['menuBarX'] > 0, before
    for mode in ['off', 'on']:
        preview_record = args.report.with_name(args.report.stem + '-preview-' + mode + '.json')
        preview_record.unlink(missing_ok=True)
        image = preview_record.with_suffix('.png')
        options = ['--preview', '--render-preview', str(image), '--record-launch', str(preview_record)]
        if mode == 'on':
            options.append('--preview-on')
        subprocess.run([str(binary), *options], check=True, timeout=15, capture_output=True)
        assert image.is_file() and image.stat().st_size > 0
        values = json.loads(preview_record.read_text())
        assert all(not s['menuBarItemCreated'] and not s['menuBarVisible'] for s in values), values
    after = wait_for_samples(3)
    assert all(s['menuBarVisible'] for s in after), after
    assert all(s['menuBarOnRight'] for s in after if s['seconds'] >= 2), after
    assert all(not s['enabled'] and not s['windowVisible'] and not s['appActive'] for s in after), after
    result = {'result': 'PASS', 'checks': ['起動時に右側のメニューバーへ表示', '画像プレビューはメニューバー項目を作らない', 'プレビュー後も本番アイコンの表示を維持', 'OFF起動・パネル非表示を維持'], 'snapshots': after}
    args.report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))
finally:
    p.terminate()
    p.communicate(timeout=20)

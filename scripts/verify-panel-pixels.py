#!/usr/bin/env python3
"""枠ではなくPNGの描画像素から、トグル上下の空白を実測する。外部ライブラリ不要。"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import zlib


def read_png(path):
    raw = path.read_bytes()
    assert raw[:8] == b"\x89PNG\r\n\x1a\n", path
    pos, compressed = 8, bytearray()
    while pos < len(raw):
        size = struct.unpack(">I", raw[pos:pos + 4])[0]
        kind, data = raw[pos + 4:pos + 8], raw[pos + 8:pos + 8 + size]
        pos += size + 12
        if kind == b"IHDR":
            width, height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", data)
        elif kind == b"IDAT":
            compressed.extend(data)
        elif kind == b"IEND":
            break
    assert depth == 8 and color in (2, 6) and interlace == 0, "非対応のPNG形式"
    channels = 3 if color == 2 else 4
    stride = width * channels
    decoded = zlib.decompress(compressed)
    rows, pos, previous = [], 0, bytearray(stride)
    for _ in range(height):
        mode = decoded[pos]
        row = bytearray(decoded[pos + 1:pos + 1 + stride])
        pos += stride + 1
        for x in range(stride):
            a = row[x - channels] if x >= channels else 0
            b = previous[x]
            c = previous[x - channels] if x >= channels else 0
            if mode == 0:
                predictor = 0
            elif mode == 1:
                predictor = a
            elif mode == 2:
                predictor = b
            elif mode == 3:
                predictor = (a + b) // 2
            else:
                assert mode == 4
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                predictor = a if pa <= pb and pa <= pc else b if pb <= pc else c
            row[x] = (row[x] + predictor) & 255
        rows.append(row)
        previous = row
    return width, height, channels, rows


def measure(source):
    width, height, _, _ = read_png(source)
    normalized = source
    if width != 300:
        assert width % 300 == 0 and height % (width // 300) == 0, "整数倍率の画像が必要です"
        normalized = source.with_name(source.stem + "-1x.png")
        subprocess.run(["sips", "-z", str(height // (width // 300)), "300", str(source),
                        "--out", str(normalized)], check=True, stdout=subprocess.DEVNULL)
    width, height, channels, rows = read_png(normalized)

    def rgb(x, y):
        return rows[y][x * channels:x * channels + 3]

    background = rgb(25, 275)

    def bounds(x0, x1, y0, y1):
        points = [(x, y) for y in range(y0, y1) for x in range(x0, x1)
                  if max(abs(v - b) for v, b in zip(rgb(x, y), background)) >= 8]
        assert points, "描画像素がありません"
        return {"top": min(y for x, y in points), "bottom": max(y for x, y in points)}

    detail = bounds(60, 240, 220, 263)
    toggle = bounds(90, 210, 263, height)
    first_line = bounds(60, 240, 220, 240)
    startup_label = bounds(80, 170, 263, height)
    line_height = first_line["bottom"] - first_line["top"] + 1
    label_height = startup_label["bottom"] - startup_label["top"] + 1
    above = toggle["top"] - detail["bottom"] - 1
    below = height - toggle["bottom"] - 1
    return {"image": str(normalized), "sha256": hashlib.sha256(normalized.read_bytes()).hexdigest(),
            "size_px": [width, height], "background_rgb": list(background), "rgb_threshold": 8,
            "coordinates": "zero based; inclusive", "detail": detail, "toggle": toggle,
            "detail_first_line_ink_height_px": line_height, "startup_label_ink_height_px": label_height,
            "above_px": above, "below_px": below,
            "result": "PASS" if above == below == 28 and line_height == label_height == 12 else "FAIL"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("images", type=Path, nargs="+")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    measurements = [measure(path) for path in args.images]
    report = {"result": "PASS" if all(m["result"] == "PASS" for m in measurements) else "FAIL",
              "measurements": measurements}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False))
    raise SystemExit(0 if report["result"] == "PASS" else 1)

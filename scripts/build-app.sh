#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
app_path="${1:-$PWD/dist/AntiSleep.app}"
if [[ "$app_path" != /* || "$app_path" != *.app ]]; then
  print -u2 '出力先には.appで終わる絶対パスを指定してください。'
  exit 64
fi
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
install -m 0755 .build/release/AntiSleep "$app_path/Contents/MacOS/AntiSleep"
install -m 0755 .build/release/anti-sleep-pmset "$app_path/Contents/Resources/anti-sleep-pmset"
install -m 0755 scripts/install-helper.sh "$app_path/Contents/Resources/install-helper.sh"
install -m 0644 LICENSE "$app_path/Contents/Resources/LICENSE"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.antisleep.AntiSleep</string>
<key>CFBundleName</key><string>AntiSleep</string>
<key>CFBundleExecutable</key><string>AntiSleep</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.2</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_path/Contents/Resources/anti-sleep-pmset"
codesign --force --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
print "作成済み: $app_path"

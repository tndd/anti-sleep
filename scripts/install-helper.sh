#!/bin/zsh
set -euo pipefail

if [[ $EUID -ne 0 || $# -ne 2 || "$2" == *[^A-Za-z0-9._-]* || -z "$2" || ! -f "$1" ]]; then
  print -u2 '管理者権限・ヘルパー実行ファイル・有効なユーザー名が必要です。'
  exit 64
fi

helper_dir='/Library/PrivilegedHelperTools'
helper_path="$helper_dir/anti-sleep-pmset"
sudoers_path='/etc/sudoers.d/anti-sleep'
temp_rule="$(/usr/bin/mktemp)"
trap '/bin/rm -f "$temp_rule"' EXIT

print -r -- "$2 ALL=(root) NOPASSWD: $helper_path on, $helper_path off, $helper_path display-sleep" > "$temp_rule"
/usr/sbin/visudo -cf "$temp_rule"
/bin/mkdir -p "$helper_dir" /etc/sudoers.d
/usr/bin/install -o root -g wheel -m 0755 "$1" "$helper_path"
/usr/bin/install -o root -g wheel -m 0440 "$temp_rule" "$sudoers_path"
print 'AntiSleepのヘルパーを設定しました。'

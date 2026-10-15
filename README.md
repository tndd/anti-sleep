# AntiSleep

**起動中はMac本体をスリープさせず、画面は消灯できるmacOSアプリです。**
Caps Lockには連動しません。アプリを終了すると、変更前のスリープ設定へ戻します。

## 動作

| 操作・状態 | 動作 |
| --- | --- |
| アプリを起動 | 無操作スリープを防止し、ふた閉じによる本体スリープも無効化 |
| 通常起動・定期確認 | メニューバーで動作。ウィンドウを勝手に前面へ出さない |
| Caps Lockを操作 | 保護に影響なし |
| 画面の自動消灯 | 許可。点灯維持の要求は登録しない |
| ふたを閉じる | 本体の保護を維持し、外部画面を含む画面を明示的に消灯 |
| ウィンドウを閉じる | メニューバーで動作を継続 |
| メニューから終了 | 起動前の設定を確認して復元し、防止要求を解除 |
| 保護設定が外部から解除された | 2秒間隔の確認で再適用 |
| 異常終了 | 別プロセスが親の終了を検出し、起動前の設定へ復元 |

適用・確認に失敗した場合は、ふた閉じ保護を有効と表示しません。
終了時の復元に失敗した場合は終了を中止し、無操作スリープの防止要求を保持します。
復元監視が起動する前にシステム設定を書き換えることはありません。

## 使い方

macOS 14以降が必要です。今回の配布ビルドはApple Silicon用です。
配布アプリの実行にSwiftや追加のランタイムは不要です。

1. `AntiSleep.app`をアプリケーションフォルダなどに置いて開きます。通常起動ではメニューバーに常駐します。
2. 旧版Capsomniaが動作している場合は終了します。両アプリで同じ設定を変更しないよう、AntiSleepは競合を表示します。
3. ヘルパーが未設定の場合は「ヘルパーを設定…」を押し、macOSの管理者認証を行います。
4. メニューバーの「AntiSleepを開く」から、本体の自動スリープ・ふた閉じ時の保護が両方とも適用済みになったことを確認します。
5. 終了はメニューバーの「終了して元の設定へ戻す」を選びます。

すでにCapsomniaの正規ヘルパーが設定されていれば、その固定操作を利用できます。
ただしCapsomnia本体との同時実行には対応しません。
画面の自動消灯時間、充電設定、Caps Lock、ログイン時の自動起動設定は変更しません。

## 権限と復元

無操作スリープはIOKitの`PreventUserIdleSystemSleep`で防止します。
ふた閉じ保護は管理者権限で`pmset -a disablesleep 1`を適用します。
画面の点灯を維持する`PreventUserIdleDisplaySleep`は登録しません。

同梱ヘルパーの管理者操作は、固定された`on`・`off`・`display-sleep`だけです。
初回認証では`/Library/PrivilegedHelperTools/anti-sleep-pmset`と、
その3操作だけを許可する`/etc/sudoers.d/anti-sleep`を配置します。
任意のコマンドや任意の`pmset`引数を管理者権限で実行する口は設けません。

通常終了と親プロセスだけの異常終了では、起動前の`SleepDisabled`へ戻します。
OSクラッシュ、強制電源断、監視プロセスまで同時に強制終了した場合は復元を保証できません。
その場合、元の設定が通常スリープだったMacでは次の操作で戻せます。

```sh
sudo pmset -a disablesleep 0
```

スリープ防止は実行中アプリの異常終了、通信断、バッテリー切れを防ぐものではありません。
閉じたまま処理を続ける場合も、放熱できる場所で使用してください。

## 開発

Command Line ToolsのSwift 5.9以降でビルドできます。外部パッケージに依存しません。
XCTestがないCommand Line Tools環境でも、専用の検証ランナーで状態遷移を確認できます。

```sh
swift run AntiSleepChecks
zsh scripts/build-app.sh
```

生成物は`dist/AntiSleep.app`です。ローカルビルドはアドホック署名です。
AppleのDeveloper ID署名・公証は付いていません。

画面の構成だけを確認する場合は、設定変更を行わないプレビューを使えます。

```sh
dist/AntiSleep.app/Contents/MacOS/AntiSleep --preview
```

検証結果は[docs/verification.md](docs/verification.md)に記載します。
ログは`~/Library/Logs/AntiSleep/`にUTC時刻で保存します。

## ヘルパーの削除

AntiSleepを正常終了してから、不要であれば以下を削除します。
既存Capsomniaのヘルパー・設定には手を加えません。

```sh
sudo rm /etc/sudoers.d/anti-sleep /Library/PrivilegedHelperTools/anti-sleep-pmset
```

## 背景

[Capsomnia](https://github.com/fuji-mak/Capsomnia)の起動中にも処理が停止した調査を契機に、
キーの状態に左右されないアプリとして新規作成しています。
Capsomniaの公式版・公式フォークではありません。

# 実機受入れ

この手順は実際のサービス登録と電源設定を変更する手動検証です。通常の `swift test` とは分離します。物理的な閉蓋を含む項目は自動テストの成功だけで検証済みにしません。

## 準備・導入

1. `swift test` と README の両方の release build を実行します。
2. 旧版の `sudo dopa`、他の抑制ツールを終了します。`pmset -g` で SleepDisabled が 0 であることを確認します。
3. 一般ユーザーから `sudo .build/release/dopa-daemon install` を実行します。実行元が分からない場合は `--user USER` を指定します。
4. `launchctl print system/dev.dopa.daemon` でサービスの登録を確認します。`dopa-daemon status` と `status --json` は sudo なしで成功し、セッションなし・idle・確認値 false であることを確認します。
5. 配置した実行ファイル・plist は root 所有で一般ユーザーが変更できず、`/var/db/dopa` は 0700 であることを確認します。別ユーザーからはソケット API を操作できないことを確認します。

## セッション

1. sudo なしで `.build/release/dopa` を起動し、status と `pmset -g` の SleepDisabled 1 を照合します。
2. 別端末でも dopa を起動し、2 セッションを確認します。一方を Ctrl+C、もう一方を SIGTERM で終了し、最後の終了後だけ SleepDisabled 0 と復元記録の削除を確認します。
3. `dopa -d` と通常の dopa を併用します。`pmset -g assertions` で表示 assertion を確認し、`-d` 側の終了で表示 assertion だけが解除されることを確認します。
4. dopa の PID に SIGKILL を送り、接続断による解除を確認します。
5. 外部ディスプレイを外し、dopa と秒ごとの時刻を記録する別プロセスを動かして蓋を約 1 分閉じます。開いた後に記録の連続性と `pmset -g log` を照合します。通信の継続だけで判断しません。
6. `dopa -l` と通常の dopa を併用し、閉蓋で `-l` 側だけが終了することを確認します。`dopa -dl` でも表示 assertion の解除を確認します。

## 障害・管理

1. dopa 稼働中にデーモンへ SIGKILL を送ります。launchd が再起動し、記録を復旧することを確認します。旧 CLI は異常終了し、自動再取得しないため、復旧後はセッションなしとなります。
2. 再起動後に status と新しい dopa が利用できることを確認します。
3. セッション稼働中に `sudo dopa-daemon install` を再実行し、既存セッションの終了・復元・更新後の稼働を確認します。
4. `sudo dopa-daemon uninstall` を実行し、復元後にサービスと管理ファイルが削除され、CLI 自体は残ることを確認します。status は接続不能で非ゼロ終了します。
5. 復元失敗・配置失敗は模擬テストで確認します。実機で復元に失敗した場合は管理ファイルや復旧記録を手動削除せず、エラーを保存して復旧します。

手動の `sudo pmset disablesleep 0` は、dopa と他ツールが動いていないことを確認できた場合の最終的な復旧手段です。

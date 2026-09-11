# macOS 実機受入れ

自動テストは電源設定を変更しません。以下は手元の Mac を実際に操作して行う受入れです。OS バージョン・Mac 機種・CPU・電源条件を結果とともに記録してください。

1. 外部ディスプレイを外し、他の閉蓋抑制ツールを終了します。`pmset -g` の `SleepDisabled` が `0` であることを確認します。
2. `swift build -c release --product dopa` 後、`sudo ./.build/release/dopa` を起動し、開始メッセージと `pmset -g` の `SleepDisabled 1` を確認します。
3. 別の端末で `while true; do date -u; sleep 1; done > /tmp/dopa-heartbeat.log` を実行し、蓋を約1分閉じてから開きます。ログに約1秒ごとの記録が続くことと、`pmset -g log` の該当時刻にシステムスリープがないことを照合します。通信の継続だけを判定基準にしません。
4. AC 接続、バッテリー駆動、dopa 実行中の電源接続・切断で繰り返します。バッテリー残量による開始拒否や自動解除は行いません。
5. Ctrl+C で終了し、`SleepDisabled 0` と `/var/db/dopa/session` の削除を確認します。通常の閉蓋スリープに戻ることを確認します。
6. 再起動した dopa に対して SIGTERM／SIGHUP を送って同じ復元を確認します。開始メッセージのフロント PID に `sudo kill -KILL PID` を送り、監視側だけで復元することも確認します。sudo 自体の PID と取り違えないでください。
7. dopa 実行中に別の `sudo ./.build/release/dopa` を起動し、同じ監視 PID に接続することを確認します。一方を Ctrl+C または SIGKILL で終了しても `SleepDisabled 1` が続き、最後の終了後にだけ `SleepDisabled 0` に戻ることを確認します。
8. フロントを残して監視 PID だけを SIGKILL し、再接続メッセージと新しい監視 PID の開始メッセージを確認します。全フロントの終了後に設定が復元されることを確認します。
9. 復旧試験では、再接続を防ぐため全フロントを SIGSTOP で停止してから、監視 PID と全フロント PID を SIGKILL で強制終了し、記録が残ることを確認します。続けて `sudo ./.build/release/dopa` を起動し、復旧メッセージと新しい開始メッセージを確認してから Ctrl+C で解除します。

## オプションの確認

- `dopa --help` が sudo なしで成功し、2つのオプションの既定値が無効と表示されることを確認します。
- `sudo ./.build/release/dopa --keep-display-on` を実行し、蓋を開けた状態で通常の画面消灯時間を超えて待っても画面が消えないことを確認します。`pmset -g assertions` で dopa の `PreventUserIdleDisplaySleep` を確認し、終了後にその assertion がなくなることを確認します。
- `sudo ./.build/release/dopa --stop-on-lid-close` を実行して蓋を閉じ、再び開いたときには dopa が終了し、`SleepDisabled 0` と記録の削除を確認できることを確認します。
- `sudo ./.build/release/dopa -d -l` でも閉蓋時に復元・終了し、画面消灯抑制の assertion が残らないことを確認します。
- オプションなしでは、画面消灯を許容し、閉蓋後も処理が続くことを時刻ログで確認します。
- オプションなしの起動と `-d` の起動を併用し、`-d` 側の終了後は画面 assertion だけが消え、システムの抑制は続くことを確認します。
- オプションなしの起動と `-l` の起動を併用し、閉蓋で `-l` 側だけが終了し、残る起動分の抑制が続くことを確認します。

復元失敗時はエラーを保存し、同じバイナリを再実行して復旧してください。手動で `sudo pmset disablesleep 0` を実行するのは、dopa と他の抑制ツールが終了し、進行中の pmset がないことを確認できた場合の最終手段です。

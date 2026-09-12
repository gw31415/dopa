# Dopa 外部設計

この文書は CLI、デーモン、公開 API の設計契約である。実装は `dopa` / `dopa-daemon` に分離し、通常利用を非特権クライアントから行う。旧 guardian と 1 バイトの内部プロトコルは既存の復元回帰テスト用に残しているが、製品 CLI の起動経路では使用しない。実機のサービス導入・電源設定変更・閉蓋検証は `docs/acceptance.md` の手順で別途行う。

## 目的と境界

- `dopa-daemon` が root で電源操作、セッション管理、復元を行う。プロセスの起動・再起動は launchd が管理する。
- `dopa` CLI は一般ユーザーで動き、デーモンに直接接続する。`dopa UI` の設計・実装・配布は今回のスコープ外とする。
- 公開 API は Unix domain stream socket 上の UTF-8 JSON。外部プロジェクトからも同じ API を利用できる。
- CLI の簡潔さを保ち、画面表示や UI 設定をデーモンに持ち込まない。
- 初版は macOS、インストール時に指定した単一ユーザー向け。リモート接続、複数ユーザーへの共有、他クライアントの強制解除、タイマー、OS 横断対応は範囲外。

```text
一般ユーザー
  dopa CLI ─────── Unix domain socket / NDJSON
                              │
                              ▼
root                     dopa-daemon
                              ├── IOKit 電源操作
launchd ── 起動・再起動 ────────┤
                              └── 復元記録
```

## 成果物とコードの責務

| 成果物・モジュール | 責務 |
| --- | --- |
| `dopa-daemon` | `install` / `uninstall` / `run` / `status`。管理・状態確認コマンドとサービスの入口 |
| `dopa` | セッション開始、シグナルによる解除 |
| `DopaProtocol` | メッセージ型、NDJSON、入力制限、API バージョン。電源操作や UI への依存なし |
| `DopaClient` | 接続、hello、要求と応答の対応付け、購読、切断通知。CLI と `dopa-daemon status` で共有 |
| `DopaCore` | `DaemonService` による認証、セッション集約、状態通知、電源操作、既存ジャーナルの再利用 |
| `CDopa` | 必要な POSIX / IOKit SPI の C ブリッジ。クライアントから電源操作を参照しない |

デーモンと CLI は個別に配布・更新できる。今回の配布成果物は `dopa-daemon` と `dopa` に限定する。プロトコルの仕様と適合テストは言語非依存にし、Swift ライブラリの利用を外部クライアントに強制しない。

## コマンド

```sh
# 初回セットアップ・更新。実行元ユーザーを許可ユーザーとして記録
sudo dopa-daemon install
# root の直接実行など、実行元ユーザーが特定できない場合
sudo dopa-daemon install --user ama

# 通常利用。Ctrl+C などでこのセッションを解除
dopa
dopa -d
dopa -l
dopa -dl

# 状態表示。sudo 不要、セッションを作らない
dopa-daemon status
dopa-daemon status --json

# 復元・サービス登録解除・配置ファイル削除
sudo dopa-daemon uninstall

# launchd 用。フォアグラウンドでサービスを実行
dopa-daemon run
```

- `-d / --keep-display-on`、`-l / --stop-on-lid-close` の意味と既定値 false を維持する。
- `run` / `install` / `uninstall` は root 必須。`status` と `--help` は sudo 不要。権限の確認はサブコマンドごとに行う。
- `dopa` は自動 sudo、自動インストール、デーモンの子プロセス起動を行わない。未導入時は導入コマンドを案内する。
- `dopa-daemon status` はデーモン状態、設定の最終確認値、セッション一覧、障害を表示する。`--json` は公開 API の snapshot オブジェクトを 1 行で出す。一般ユーザーのクライアントとして公開 API の hello / status.get を利用し、電源操作・状態ファイルの直接読み取り・サービス起動は行わない。デーモン不在時も別インスタンスを起動せず接続不能を報告する。`dopa status` の別名は設けない。
- 終了コードは 0 が正常（明示解除・閉蓋による終了を含む）、1 が接続・操作・復元などの失敗、2 が CLI 構文エラー。`status` は接続不能または degraded なら 1。
- SIGINT / SIGTERM / SIGHUP / SIGQUIT は release を要求し、完了を待って終了する。確認できない場合は成功扱いにしない。待機上限は 10 秒で、期限到達時は状態未確認として 1 で終了する。切断による解除はデーモンが続行する。
- `start` / `stop` / `restart` の独自管理コマンドは設けない。サービスの管理は launchctl、導入と削除は管理コマンドが担当する。

## launchd と配置

初版は socket activation を導入せず、RunAtLoad / KeepAlive による常駐を採用する。セッション数が 0 なら電源設定を復元して待機し、アイドルを理由に終了しない。`run` は fork / setsid で自分自身をバックグラウンド化しない。

| パス | 用途・所有権 |
| --- | --- |
| `/Library/LaunchDaemons/dev.dopa.daemon.plist` | launchd 定義。root:wheel、0644 |
| `/Library/PrivilegedHelperTools/dev.dopa.daemon` | `dopa-daemon` の配置コピー。root:wheel、0755 |
| `/var/db/dopa/config.json` | 許可 UID と設定バージョン。root 専用 |
| `/var/db/dopa/lock`、`session` | 排他と既存形式の復元記録。ディレクトリ 0700、ファイル 0600 |
| `/var/db/dopa/management.lock` | install / uninstall の同時実行を直列化。root 専用。デーモンの排他とは別 |
| `/var/run/dopa/control.sock` | 公開 IPC。親は root:wheel、0755、ソケットは root:wheel、0666 |

ソケットの 0666 は UID 認証の代わりではない。接続直後に OS から得た UID を検査し、許可ユーザーと root 以外は JSON を処理せず切断する。書き換え可能なソケットファイルを利用者のディレクトリに置かない。クライアントは root 所有の親パス・ソケットと接続相手 UID 0 を検証する。ジャーナルへのアクセスはデーモンだけが持つ。

認証失敗・不正入力はその接続だけを終了し、他セッションやサービスを停止しない。未認証接続を保持せず、accept 処理にもバッチ上限を設ける。デーモンは復旧開始前から終了処理完了まで既存の flock を保持し、launchd 外からの二重起動も拒否する。古いソケットを除去できるのはロックを取得したデーモンだけである。macOS の `/var` など既知のシステムエイリアスは正規化し、その配下の管理ディレクトリについて所有権とリンクを検証する。

macOS 標準の `/private/var/run` は root:daemon（GID 1）、0775 の場合がある。この正確なパス・所有者・モードだけを祖先として許可し、権限は変更しない。`/var/run/dopa` 自体にはこの例外を適用せず、root 所有で group/world 書込み不可を要求する。既存の `/Library/LaunchDaemons` と `/Library/PrivilegedHelperTools` も所有者・書込み権限を検証し、sticky bit など OS 側の既存モードは維持する。

install は sudo の実行元 UID または `--user` から実在するアカウントを解決し、数値 UID を記録する。更新時は既存の許可 UID を保持し、暗黙に変更しない。ユーザー変更は uninstall / install で行う。

インストーラーは検証した通常ファイルのコピーを管理先に配置し、ユーザーが編集できるビルド成果物を launchd の実行パスにしない。管理先のシンボリックリンク・予期しない所有者を拒否し、配置は原子的に行う。管理処理で launchctl を直接実行することを許容する。電源操作では pmset / caffeinate / シェルを起動しない。

### 更新・削除

install の再実行は更新として扱う。更新・削除は既存セッションを終了させることをコマンドの仕様とヘルプに明示する。

1. root 専用の `admin.prepareShutdown` で新規 acquire を止め、セッションを終了し、表示 assertion と設定を復元する。
2. 完了応答を確認してから launchctl bootout を実行する。デーモンは応答後も draining のまま待機するため、bootout 前に KeepAlive で再起動されない。
3. 更新は配置して bootstrap、hello による準備完了確認まで行う。削除は bootout 成功後に管理ファイルを除去する。`dopa` CLI 自体は削除しない。

復元に失敗したら配置変更・削除を中断し、バイナリと復旧記録を保持する。デーモンが不在なら、既存バイナリのサービスを起動して復旧を試みてから同じ手順を実施する。旧 guardian がロックを保持している場合は新旧を同時運用せず、旧セッション終了を案内する。サービス切替失敗を成功扱いにせず、既存配置の復帰を試みる。

## ワイヤープロトコル v1

### フレーミングと入力

- AF_UNIX / SOCK_STREAM、UTF-8、1 行 1 JSON オブジェクト、末尾 LF。文字列内の改行は JSON のエスケープで表す。CRLF は受理しない。
- 1 メッセージは LF を除き最大 64 KiB。分割受信と複数行の一括受信を処理する。
- 空行、トップレベル配列、重複キー、不正 UTF-8、不正 JSON、32 段を超えるネストは拒否する。フレーム破損は可能なら protocol error を送り、接続を閉じる。
- 応答前に要求を重ねて送信できるが、同一接続の処理は受信順。要求 ID は接続内で重複しない 1〜64 バイトの ASCII 文字列。
- hello を 5 秒以内に完了する。フレーム先頭受信から LF までも最大 5 秒。認証済み接続は最大 64、1 接続の未処理要求は最大 16、送信待ちデータは最大 256 KiB。要求 ID の履歴を有限にするため、1 接続あたり最大 65,536 要求とし、超過時は limit_exceeded で切断する。この上限も hello で通知する。
- 制限超過・読み取りを進めないクライアントは切断する。他の接続や復元処理を待たせない。監視専用接続は idle timeout を設けない。

### エンベロープ

```json
{"id":"1","method":"hello","params":{"apiVersion":1,"client":{"name":"dopa","version":"0.2.0"}}}
{"id":"1","result":{"apiVersion":1,"daemonVersion":"0.2.0","instanceId":"opaque-instance-id","capabilities":["status.subscribe","session.update"],"limits":{"maxMessageBytes":65536,"maxSessions":32}}}
{"id":"2","method":"session.acquire","params":{"options":{"keepDisplayOn":false,"stopOnLidClose":false}}}
{"id":"2","result":{"sessionId":"opaque-session-id","revision":"1"}}
{"id":"3","error":{"code":"invalid_params","message":"keepDisplayOn must be a boolean"}}
{"event":"status.changed","data":{"instanceId":"opaque-instance-id","revision":"2","snapshot":{}}}
```

例の `snapshot: {}` は構造説明用の省略表記。実際には下記の完全な snapshot を送る。バージョン文字列も例示であり、リリース番号を決定するものではない。

- 応答は `result` / `error` のいずれか一方だけを持つ。通知には `id` を付けない。
- hello 以前は他の操作を認めない。v1 非対応なら `unsupported_version` と対応バージョンを返して切断する。
- 初版は `apiVersion: 1` の major 単位。破壊的変更は major を上げ、機能追加は capabilities で確認する。
- 応答・通知への追加フィールドはクライアントが無視する。要求パラメーターの未知フィールドは typo を検出するため拒否する。新クライアントは能力確認後に新パラメーターを使う。未知のイベントは無視する。
- client.name / version は表示用の自己申告であり、認証・認可に使わない。name は UTF-8 128 バイトまでで制御文字を禁止する。PID / UID は OS から取得する。
- instanceId は起動ごとに変わり、revision はその起動内で増加する十進文字列。ID と revision は JavaScript の数値精度に依存しない。

### 操作

| method | params | 結果・意味 |
| --- | --- | --- |
| `hello` | apiVersion、client | バージョン、instanceId、capabilities、limits |
| `status.get` | `{}` | 完全な snapshot。セッションを作らない |
| `status.subscribe` | `{}` | 完全な初期 snapshot を応答し、その後 `status.changed` を送る |
| `status.unsubscribe` | `{}` | 購読解除。所有セッションには影響しない |
| `session.acquire` | options（2 つの boolean を必須） | この接続のセッションを作成。適用完了後に sessionId / revision |
| `session.update` | sessionId、options（完全置換） | この接続のオプションを変更。適用完了後に revision |
| `session.release` | sessionId | この接続のセッションを解除。必要な復元完了後に revision |
| `admin.prepareShutdown` | `{}`、root 限定 | 新規抑制を禁止し、全セッションの終了と復元完了を確認 |

1 接続が同時に所有できるセッションは 1 つ、全体は最大 32。追加 acquire は `session_exists`。複数セッションを必要とするクライアントは接続を分ける。自分の接続で終了済みの sessionId への release は、復元が未確認の degraded 状態を除き成功扱いとし、接続ごとに直近 32 件を記憶する。復元失敗後の再要求は成功に見せず `recovery_failed` を返す。それ以外の不明・他接続の ID は `session_not_owned`。root の通常セッション操作にも同じ所有権規則を適用する。

### 状態と通知

snapshot は以下のフィールドを持つ。

| フィールド | 内容 |
| --- | --- |
| instanceId / revision | デーモン起動と状態の版を識別 |
| phase | `recovering` / `idle` / `active` / `draining` / `degraded` |
| desired | 有効なセッションを集約した systemSleepDisabled / keepDisplayOn |
| confirmed | systemSleepDisabled / keepDisplayOn の boolean または不明時 null、checkedAt（RFC 3339 UTC） |
| sessions | id、clientName、peerUID、peerPID、options、createdAt。認証済みユーザーと root に公開 |
| recoveryPending | 未完了の復元記録が存在するか |
| lastError | null または安定した code と表示用 message |

confirmed は IOKit の書き込み・読み戻しと assertion の取得・解除で最後に確認した状態であり、物理的に将来のスリープが起きないことの保証ではない。status.get と subscribe の初期取得では SleepDisabled を読み直し、接続が存在する間は約 1 秒間隔でも再確認する。外部ツールによる変更との協調はサポートしない。不一致・読み取り失敗は正常表示を続けず、degraded として復元処理へ移る。

subscribe は状態取得と購読登録を同じ直列処理内で実行し、初期応答より後の変更を取りこぼさない。各イベントは完全な snapshot を持ち、キューにある未送信 snapshot は最新のものに統合してよい。revision の欠番は正常。クライアントは新しい版で状態を置換する。checkedAt の更新だけではイベントを発生させない。

所有セッションがデーモン側で終了した場合は `session.ended` を所有接続へ送る。data は sessionId、reason（`lid_closed` / `daemon_shutdown` / `power_error` / `lid_error`）、cleanup（`confirmed` / `failed`）、revision。このイベントは統合しない。明示 release では応答が終了確認となり、session.ended を重複送信しない。

subscribe / unsubscribe は冪等。unsubscribe 応答後は新しい status.changed を送らない。セッション操作の応答を同じ操作で生じた status.changed より先に送る。所有者向け session.ended も対応する snapshot より先に送る。異なる接続間の到着順には依存しない。

安定したエラーコードは `unsupported_version`、`invalid_request`、`invalid_params`、`unknown_method`、`not_ready`、`session_exists`、`session_not_owned`、`limit_exceeded`、`lid_closed`、`lid_unavailable`、`power_conflict`、`power_failed`、`recovery_failed`、`shutting_down`、`permission_denied`。クライアントは message を分岐条件にしない。エラーが出たからといって設定不変とは推定せず、状態と cleanup を確認する。

## セッションと電源操作の不変条件

1. セッションの所有権は接続にあり、PID や clientName や sessionId 自体にはない。状態監視だけでは抑制を開始しない。
2. 1 つでも有効セッションがあれば本体を抑制し、keepDisplayOn が true のセッションが 1 つでもあれば表示 assertion を維持する。
3. 最後のセッション終了時に本体設定を復元する。1 つのセッションを解除しても他が残れば抑制は続く。release 成功は「自分の要求が除去され、集約結果が適用された」の意味。
4. stopOnLidClose は各セッションに適用し、約 0.3 秒間隔で確認する。閉蓋済みの acquire / 有効化 update は `lid_closed` とし、新規作成・変更を行わない。稼働中に閉じた場合は該当セッションを終了し、自動再開しない。蓋状態取得失敗時も該当セッションを終了し、理由を通知する。
5. 取得前の構文・認証・所有権・閉蓋チェック失敗は既存セッションを変更しない。電源操作後の失敗で、ロールバックによる原子性は約束しない。初版は全セッションを終了し、両方の解除を試みて degraded にする保守的な動作を採用する。
6. 電源操作・ジャーナル・セッション変更は単一の直列実行経路に集約する。電源 API が応答しない場合に、別スレッドから競合する復元操作を始めない。
7. 抑制開始前に復元記録を耐久保存し、書き込み後に読み戻す。元から SleepDisabled が有効なら `power_conflict` で開始せず、他ツールの設定を引き継がない。
8. 復元は表示 assertion の解除と SleepDisabled の復元を両方試みる。一方の失敗で他方を省略しない。復元確認前に記録を削除しない。

既存の `dopa-v1\noriginal=0\n` ジャーナルを読める状態を維持する。未知・破損記録で値を推測しない。設定が元から false の場合だけ開始するため、初版の復元値は false である。

## 切断・障害・復旧

- クライアントの終了・SIGKILL・ソケット切断で、その接続のセッションを解除する。所有者が消えても他クライアントは継続する。
- デーモンの SIGTERM は新規 acquire を拒否し、全セッションを解除・復元して終了する。復元失敗時は記録を保持し異常終了する。
- デーモンの異常終了後は launchd が再起動し、抑制受付前にジャーナルを復旧する。所有セッションをディスクから復活させない。
- 復旧不能ならプロセスを degraded で維持し、status と管理操作を受け付けるが acquire / update は拒否する。自動再起動の反復による電源設定の連続操作を避ける。
- クライアントの切断は「抑制解除を確認した」とは扱わない。CLI は状態未確認で異常終了する。外部クライアントも切断前の snapshot を現在の確認状態として扱わない。
- 初版では抑制セッションを自動再取得しない。CLI では再実行する。応答消失時の二重取得と、意図した停止後の再抑制を避ける。
- これは旧 CLI の guardian 異常終了時の自動再接続・再取得からの意図した変更である。新 API のテストでは自動再取得しないことを検証する。旧 guardian のテストは従来の復元機構の回帰確認として分離して維持する。
- request id は接続内の応答対応用であり、再接続をまたぐ exactly-once 実行は保証しない。操作の timeout 時は接続を閉じて所有セッションを失効させ、成功を推測しない。
- 全プロセスの強制終了・電源断・SDK 呼び出し停止時には即時復元を保証できない。API 利用側は接続状態と確認状態を区別する。

## 将来の外部クライアント

`dopa UI` は将来の別プロジェクトとして保留する。メニューバー、四隅の表示、操作パネル、表示設定、配布構成は今回の設計・実装・検証の対象に含めない。

公開 API の状態取得・購読、セッション所有権、要求と確認状態の分離は今回のスコープに残す。将来の UI を含む外部クライアントが利用できる通信契約として定義し、適合テストでは模擬クライアントを使用する。通常 API に全セッション停止は設けず、root の管理操作はサービス更新・削除に限定する。

## 検証すべき契約

実装時は模擬電源で以下を確認し、実際の SleepDisabled 書き込み・閉蓋試験は別の実機受入れとして行う。

- NDJSON の分割・結合、不正 UTF-8 / JSON / 重複キー、サイズ・深さ・接続数・キュー制限。
- 認証 UID、root サーバー検証、未知バージョン、異なるバージョンのクライアント共存。
- 監視接続だけでは抑制しないこと、複数所有者の集約、他接続 ID の拒否、切断時の解除。
- subscribe の初期状態とイベント順序、遅い監視者の分離、revision と instanceId の扱い。
- acquire / update / release の適用確認、閉蓋、電源 API 失敗、復元失敗、応答消失。
- SIGTERM / SIGKILL、launchd 再起動、旧ジャーナル復旧、破損記録の拒否、自動再取得しないこと。
- install / update / uninstall の排他・復元確認・途中失敗時の記録保持。管理処理の模擬テストと実機検証を分ける。

この一覧は検証する契約を示す。自動テストの成功は実機の root サービス導入や物理的な閉蓋試験の代わりにはならない。

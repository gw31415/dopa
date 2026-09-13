# Dopa 外部設計

この文書は CLI、メニューバーアプリ、デーモン、公開 API の設計契約である。電源操作は `dopa-daemon`、通常利用は非特権の `dopa` / `Dopa.app` に分離する。旧 guardian と 1 バイトの内部プロトコルは既存の復元回帰テスト用に残しているが、製品 CLI の起動経路では使用しない。実機のサービス導入・電源設定変更・閉蓋検証は `docs/acceptance.md` の手順で別途行う。

## 目的と境界

- `dopa-daemon` が root で電源操作、セッション管理、復元を行う。プロセスの起動・再起動は launchd が管理する。
- `dopa` CLI と `Dopa.app` は一般ユーザーで動き、デーモンに直接接続する。UIはmacOS 26以降のSwiftUI / Liquid Glass、CLIとデーモンはmacOS 13以降を対象とする。
- 公開 API は Unix domain stream socket 上の UTF-8 JSON。外部プロジェクトからも同じ API を利用できる。
- CLI の簡潔さを保ち、画面表示や UI 設定をデーモンに持ち込まない。
- 初版は macOS、インストール時に指定した単一ユーザー向け。リモート接続、複数ユーザーへの共有、デーモン側タイマー、OS 横断対応は範囲外。UIが期限を管理し、他クライアントの停止は管理者認証を伴う明示操作に限定する。

```text
一般ユーザー
  dopa CLI / Dopa.app ─── Unix domain socket / NDJSON
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
| `dopa-daemon` | `install` / `uninstall` / `start` / `stop` / `restart` / `run` / `status`。管理・状態確認コマンドとサービスの入口 |
| `dopa` | セッション開始、シグナルによる解除 |
| `Dopa.app` / `DopaUI` | メインウィンドウを持たないSwiftUIメニューバーパネル |
| `DopaUIModel` | 時間設定とdraft、接続所有権、期限、確認状態。ソケットは専用直列queueへ分離 |
| `DopaAuthorization` | Authorization Servicesで管理権限を取得・検証。資格情報はIPCの間だけ保持 |
| `DopaProtocol` | メッセージ型、NDJSON、入力制限、API バージョン。電源操作や UI への依存なし |
| `DopaClient` | 接続、hello、要求と応答の対応付け、購読、切断通知。CLI、UI、`dopa-daemon status` で共有 |
| `DopaCore` | `DaemonService` による認証、セッション集約、状態通知、電源操作、既存ジャーナルの再利用 |
| `CDopa` | 必要な POSIX / IOKit SPI の C ブリッジ。クライアントから電源操作を参照しない |

デーモンと CLI は個別に配布・更新できる。ビルドと検証の入口は `Makefile` に集約する。Swift を含むツールのバージョンと Swift が参照する Xcode SDK は `mise.toml` に集約し、すべて `mise exec --` から実行する。UIバンドルは `make app` から `scripts/build-app.sh` を呼び出して生成し、`dopa-ui` のリンク SDK が macOS 26 以降であることを検証した上で、`Contents/MacOS/dopa-ui` と、`Contents/Helpers/dopa`・`Contents/Helpers/dopa-daemon` を同梱する。補助実行ファイルを個別に署名してからAppを署名し、各実行権・署名・補助コマンドのヘルプ起動を検証する。UIは起動時にサービスが未導入なら導入確認を、導入済みだが初回接続できなければ起動確認を表示し、利用者が「続ける」を選んだ場合に限り管理者認証を要求する。管理ファイルが未導入の間はアウトライン月を表示し、導入完了後からUIの接続成立まではステータス項目内のスピナーを表示する。接続待ちは10秒、GUIから開始したdaemon管理コマンドは60秒で打ち切り、接続タイムアウト時は明示的なエラーを表示する。操作していない通常の導入済み停止中は従来どおり注意アイコンとする。管理ファイルを継続監視し、外部uninstall後も未導入表示へ更新する。起動中の切断後は自動表示せず、未導入ならアウトライン月、導入済み停止中なら注意アイコンを表示し、その左クリックを通常パネルより優先して対応する確認を表示する。右クリックは状態にかかわらず終了メニューを表示する。正常なアイドル状態は塗りつぶし月で表す。プロトコルの仕様と適合テストは言語非依存にし、Swift ライブラリの利用を外部クライアントに強制しない。

Dopa.appからのdaemon導入・起動は、制御端末を持つ `/usr/bin/sudo -k` に委譲し、端末の `/etc/pam.d/sudo` に構成されたPAMスタックとsudoersをそのまま利用する。Touch IDやApple WatchなどPAMモジュール自身のUIを優先し、PAMがターミナル文字入力を要求した場合はポリシーを別の認可経路で迂回せず操作を中止して、同梱daemonをTerminalから `sudo` で実行するよう案内する。DopaはPAM・sudoers・Authorization Databaseを書き換えず、管理者パスワードを自身で読み取り・保存・ログ出力しない。これは別UIDのセッション停止に用いるAuthorization Servicesの短期ExternalFormとは別の認可経路である。

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

# 導入済みサービスの安全な起動・停止・再起動
sudo dopa-daemon start
sudo dopa-daemon stop
sudo dopa-daemon restart

# launchd 用。フォアグラウンドでサービスを実行
dopa-daemon run
```

- `-d / --keep-display-on`、`-l / --stop-on-lid-close` の意味と既定値 false を維持する。
- `run` / `install` / `uninstall` / `start` / `stop` / `restart` は root 必須。`status` と `--help` は sudo 不要。権限の確認はサブコマンドごとに行う。
- `dopa` は自動 sudo、自動インストール、デーモンの子プロセス起動を行わない。未導入時は導入コマンドを案内する。
- `dopa-daemon status` はデーモン状態、設定の最終確認値、セッション一覧、障害を表示する。`--json` は公開 API の snapshot オブジェクトを 1 行で出す。一般ユーザーのクライアントとして公開 API の hello / status.get を利用し、電源操作・状態ファイルの直接読み取り・サービス起動は行わない。デーモン不在時も別インスタンスを起動せず接続不能を報告する。`dopa status` の別名は設けない。
- 終了コードは 0 が正常（明示解除・閉蓋による終了を含む）、1 が接続・操作・復元などの失敗、2 が CLI 構文エラー。`status` は接続不能または degraded なら 1。
- SIGINT / SIGTERM / SIGHUP / SIGQUIT は release を要求し、完了を待って終了する。確認できない場合は成功扱いにしない。待機上限は 10 秒で、期限到達時は状態未確認として 1 で終了する。切断による解除はデーモンが続行する。
- `start` は導入済み管理ファイルを検証してlaunchdサービスを起動し、正常応答まで確認する。`stop` は全セッションと電源設定の復元をdaemonから確認してからbootoutする。停止済みでもjournal復旧が必要な場合は一度起動して復元を完了する。`restart` は同じ管理lock内で安全な停止・起動・正常応答確認を行う。

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
| `session.stopSessions` | sessionIds（確認した1〜32件） | 要求元と同UIDの対象を接続をまたいで停止。別UIDが1件でもあれば全件拒否。stoppedSessionIds / revisionを返す |
| `admin.stopSessions` | sessionIds（確認した1〜32件）、authorization（ExternalFormのbase64、rootのみnull可） | 管理者権限を検証し、対象をまとめて停止。stoppedSessionIds / revisionを返し、新規セッションの受付を維持 |
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

所有セッションがデーモン側で終了した場合は `session.ended` を所有接続へ送る。data は sessionId、reason（`lid_closed` / `daemon_shutdown` / `user_stopped` / `power_error` / `lid_error`）、cleanup（`confirmed` / `failed`）、revision。このイベントは統合しない。明示 release では応答が終了確認となり、session.ended を重複送信しない。

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

## 管理停止と認可

`session.stopSessions` と `admin.stopSessions` はhelloの同名capabilityで交渉する。通常のrelease/updateの接続所有権を変更しない。確認したsessionIdを指定し、その後に作られた別IDへ作用させない。重複ID・不正パラメーター・認証の拒否はセッション変更前に検査する。終了済みIDは無視し、実際に停止したIDを返す。全停止も、確認時のID集合を1回のエンジン操作で処理する。

`session.stopSessions` は要求元と全live対象のカーネル取得UIDが一致すれば、接続をまたいで管理者認証なしに停止する。別UIDが混在した場合は変更前に全件を拒否し、rootにも同じUID制約を適用する。UIDはクライアントの自己申告から受け取らない。終了済みIDは無視し、同UIDの対象が確認後に一部終了しても認証経路へ切り替えない。UIはsnapshotのpeerUIDで停止可否を判断し、欠落したUIDを同UIDと推測しない。

別UIDまたは旧デーモンの管理停止には既存の `admin.stopSessions` を使う。この操作ではroot以外はmacOS Authorization Servicesの `system.privilege.admin` が必要。UIは停止直前に標準認証を要求し、ExternalFormをbase64で送る。デーモンはインポートした権限を非interactiveに検証し、対話による追加権限取得はしない。権限は一覧閲覧に不要。資格情報は保存・ログ出力せず、要求完了まで短命なgrantを保持してから破棄する。独自パスワード入力、特権コマンド実行、Authorization DBの書き換えは行わない。

どちらの停止操作も対象所有者には `session.ended(reason: user_stopped, cleanup: ...)` を通知する。復元が確認できればCLIは正常終了する。集約結果の適用が失敗した場合は `recovery_failed` を返し、確認状態を不明・phaseをdegradedにする。管理要求自体は指定外セッションを削除せず、degraded中の電源監視は状態の再確認だけを行う。以後の切断・閉蓋処理で集約の適用に再び失敗した場合は、既存の保守的な障害復旧経路が適用される。復元失敗を「他の使用元は正常継続」と表示しない。

## SwiftUIメニューバーアプリ

公開AppKitの `NSStatusItem` と `NSPopover` で操作パネルだけを持ち、WindowGroupなどのメインウィンドウは設けない。通常クリックでパネル、右クリックでアプリ終了メニューを開く。バンドルの `LSUIElement` を有効にし、Bundle Identifierは `dev.amas.dopa` とする。タブ、ボタン、入力、Toggle、popover、confirmationDialogは標準SwiftUIを使い、Liquid Glassの形状・配色・アクセシビリティ設定をOSに任せる。Webデモの色や寸法はコピーしない。操作仕様と配置の不変条件は `docs/ui-concept.md` を参照する。

両タブはこのアプリの操作に必要な共通サイズを使用し、一覧だけスクロールする。時間と終了時刻は同じ列・同じ入力サイズを使用する。無制限や日付表示、適用操作の切り替えでフォームやパネルを移動させない。フォームの実測高を状態へ書き戻さず、同じ自然サイズの領域を両タブで共有する。popoverの寸法は表示前に決定し、表示中にpreferredContentSizeを自動追従させない。メニューバー項目は固定幅とし、標準シンボルは自然サイズのまま使う。popoverは画像由来の高さが変わるボタンではなく、status windowの固定content領域へ位置を合わせる。接続案内・操作メッセージ・処理中は既存ヘッダーに収め、下部に可変の行を足さない。メッセージの詳細はヘッダー、入力エラーは該当欄のpopoverに表示する。全体管理の各行でkeepDisplayOnとstopOnLidCloseのオン／オフを閲覧できる。全体の消灯抑制は接続中の整合したconfirmed.keepDisplayOnから判断し、有効時だけヘッダーへ短い表示を出す。自分の未適用設定や一部の要求だけから有効と判断しない。

時間は1秒〜24時間または無制限。継続時間はAppKitの時・分・秒の3要素入力で、両入力を共通のAppKitコントロールで扱う。Tabは欄全体を選択し、Enterで左端の数値から編集へ入る。編集中のTabは右の要素へ進み、最後の要素から次の欄全体へ抜ける。マウスではクリックした数値を直接編集する。フォーカス枠は選択中・編集中とも欄全体に付ける。編集中は数字入力・左右移動・上下増減を提供し、24:00:00を日付へ変換しない。終了日時はSwiftUIに組み込んだ標準NSDatePickerからDate値として受け取り、日付・時刻を一体として編集する。過去の選択を翌日へ読み替えない。継続時間と終了日時は同じ期限の2表現であり、最後に値の変更を始めた入力を固定基準とし、対象の入力欄のすぐ左にピンアイコンだけを表示する。選択移動だけでは基準を変更せず、数字入力・削除・上下キー操作の開始時にその欄を固定する。開始・適用後は終了日時を固定基準とする。停止後は最後に適用した設定の種類（継続時間／終了日時）へ戻し、残り時間には変換しない。固定基準はdraft・実行状態・configから導出し、独立したフラグとして保存しない。実行中の手入力・基準変更は未確定draftになる。無制限では両方の表示値を空欄にし、入力と加算を無効にする。停止中の有効入力と無制限切り替え、加算、動作Toggleは即時操作する。実行中の無制限切り替えはキャンセル／適用の対象であり、適用までは元の期限と稼働状態を保持する。draftを適用するまで元の期限は変わらず、元の期限で停止した場合はdraftを破棄する。ソケット所有と期限処理はパネルの表示に依存しない。

起動や再接続では監視だけを開始し、スリープ防止を自動取得しない。ソケットはMainActor外の専用queueに閉じ込め、操作応答とsnapshotで確認済み状態を更新する。instanceIdをまたいで所有情報を持ち越さず、revisionを十進文字列のまま比較する。接続断・degraded・confirmed不一致を「オフ」と表示しない。終了時は進行中のdaemon管理認証をキャンセルして子プロセスの回収を待ち、自分のセッションの解除を試み、他接続を停止しない。

UIバンドルはローカル実行用ad-hoc署名で生成する。Developer ID署名、notarization、ログイン時自動起動の登録は別の配布作業とする。通常ビルドはroot所有ソケット・サーバーだけに接続する。UI受入れの専用コンパイルでは模擬電源の一時ソケットとダミー認可を明示注入できるが、この切り替えは製品ビルドに含めない。

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

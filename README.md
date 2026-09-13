# Dopa

macOS のシステムスリープと閉蓋スリープを抑制するCLIとメニューバーアプリです。root の `dopa-daemon` が電源操作を担当し、通常の `dopa` と `Dopa.app` は sudo なしで利用できます。

電源操作は IOKit を直接呼び、`pmset`、`caffeinate`、シェルを起動しません。サービスの登録・解除に限り、管理コマンドが `/bin/launchctl` を使用します。

## ビルドと導入

macOS 13 以上が対象です。セットアップには mise が必要です。開発ツールは `mise.toml` で Swift 6.3.3、Node.js 26.8.1、Python 3.14.7 を固定し、Swift には使用中の Xcode が持つ macOS SDK を `SDKROOT` として渡します。`mise.lock` には配布物の取得先とチェックサムを記録しています。外部パッケージへの依存はありません。

```sh
mise install --locked
```

CLI・デーモンのビルドには Xcode または Command Line Tools も必要です。App バンドルの生成には macOS 26 SDK を含む Xcode と、そこに含まれる SDK・`actool`・`codesign`・`plutil` を使います。SDK の選択も `mise.toml` に集約しており、`mise exec --` から外れてビルドしません。

```sh
make build
sudo .build/release/dopa-daemon install
```

`make build` は mise で選択した Swift を使い、CLI とデーモンを警告もエラーとして release ビルドします。Makefile はソースと生成物のタイムスタンプを比較し、変更のないビルドやテストは省略します。

`install` は実行元のユーザーを許可ユーザーとして記録し、root 所有のデーモンのコピーと LaunchDaemon を配置して起動します。root の直接実行など実行元が特定できない場合は `install --user USER` を使います。`dopa` CLI は自分の PATH 上など任意の場所に配置できます。

v0.2.0 で `managed directory is writable by others: /private/var/run` が出る場合は、v0.2.1 以降の `dopa-daemon` で install を再実行してください。macOS 標準ディレクトリの検証を修正しており、`/var/run` の権限を変更する必要はありません。

```sh
.build/release/dopa
.build/release/dopa -d
.build/release/dopa -l
.build/release/dopa -dl
```

| オプション | 動作 | 既定値 |
| --- | --- | --- |
| `-d`, `--keep-display-on` | 無操作による画面消灯も抑制 | OFF |
| `-l`, `--stop-on-lid-close` | 蓋を閉じたら、このセッションを終了 | OFF |
| `-h`, `--help` | ヘルプ表示 | — |

オプションなしでは画面消灯を許容し、閉蓋中も本体のスリープ抑制を続けます。Ctrl+C、SIGTERM、SIGHUP、SIGQUIT で自分のセッションを解除します。解除の応答を待ち、確認できない場合はエラーとして終了します。

複数の `dopa` は同じデーモンに接続します。最後のセッションが終了するまで本体の抑制を続けます。`-d` のセッションが一つでもあれば画面消灯を抑制します。画面消灯時間そのものは変更せず、閉じた内蔵画面を点灯させるものではありません。

`-l` は既に蓋が閉じていれば開始を拒否します。開始後は約 0.3 秒間隔で確認し、閉蓋時は指定したセッションだけを終了します。蓋を開けても自動再開しません。バッテリー残量による自動解除はありません。

## メニューバーアプリ

UIはmacOS 26以降とmacOS 26 SDKを含むXcodeが必要です。CLI・デーモンのmacOS 13対応は変わりません。

```sh
make app
open .build/Dopa.app
```

ビルドスクリプトは `dopa-ui`・`dopa`・`dopa-daemon` のreleaseビルドを作り、`dopa-ui` が macOS 26 以降の SDK でリンクされていることも検証します。`Resources/Dopa.icon` を `actool` で macOS 26向けにコンパイルして `Dopa.app/Contents/Resources/Assets.car` と `Dopa.app/Contents/Resources/Dopa.icns` を生成し、UIを `Dopa.app/Contents/MacOS/dopa-ui`、CLIとデーモンを `Dopa.app/Contents/Helpers/` に同梱します。各実行ファイルの権限・署名と、同梱CLI・デーモンのヘルプ起動を確認します。同梱だけではサービスの導入・更新は行いません。Appに含まれるデーモンを導入する場合は次を実行します。

```sh
sudo .build/Dopa.app/Contents/Helpers/dopa-daemon install
```

CLIは `.build/Dopa.app/Contents/Helpers/dopa` から直接使うか、PATH上へコピーできます。

`Dopa.app` はメニューバーに常駐し、メインウィンドウを持ちません。アイコンの通常クリックで操作パネルを開き、右クリックメニューからアプリを終了します。起動だけでは抑制を開始せず、パネルを閉じた後も実行中の期限を管理します。「このアプリ」で時間・終了時刻・無制限と動作設定を操作し、「全体管理」で各使用元の状態を確認できます。

同じユーザーの使用元は確認後、管理者認証なしで停止できます（デーモンの `session.stopSessions` capabilityが必要）。別ユーザーの対象や旧デーモンの管理停止では、従来の `admin.stopSessions` とmacOS標準の管理者認証を使います。全体管理の各行に「消灯抑制」「閉じたら停止」の設定を表示し、いずれかの使用元によるディスプレイ消灯抑制が確認されている間はヘッダーに「消灯抑制」を表示します。サービス未導入と導入操作中はアウトライン月、管理ファイルの導入完了後からUIの接続成立までは回転する進捗表示、操作していない通常の導入済み停止中は注意アイコン、正常なアイドル状態は塗りつぶし月で表示します。接続待ちは10秒、GUIから開始したdaemon管理コマンドは60秒で打ち切り、タイムアウト時は理由を表示して操作可能な状態へ戻します。管理ファイルの外部変更も監視するため、daemonをuninstallすると未導入表示へ更新されます。起動時と各状態アイコンの左クリック時に導入または起動の確認を出し、「続ける」が選ばれた場合に限って管理者認証を要求します。右クリックは状態にかかわらず終了メニューを開きます。Appからの導入・起動はそのMacの `sudo` PAM設定を使うため、構成済みのTouch IDやApple Watch等が優先されます。PAMがターミナル文字入力を要求する構成ではポリシーを迂回せず操作を中止し、同梱の `dopa-daemon` をTerminalから `sudo` で実行するよう案内します。更新する場合は新しいAppの同梱デーモン、または個別にビルドした `dopa-daemon` から `install` を再実行してください。更新時には進行中のセッションが終了します。

バンドルはローカル実行用のad-hoc署名です。一般配布には別途Developer ID署名とnotarizationが必要です。ログイン時の自動起動登録は行いません。

## 状態確認と削除

```sh
# sudo 不要。セッションは作らない
.build/release/dopa-daemon status
.build/release/dopa-daemon status --json

# 全セッションを終了・復元してサービスを削除
sudo .build/release/dopa-daemon uninstall

# 導入済みサービスの起動・安全な停止・再起動
sudo .build/release/dopa-daemon start
sudo .build/release/dopa-daemon stop
sudo .build/release/dopa-daemon restart
```

`status` は公開 API からデーモンの状態、セッション一覧、設定の確認値、障害を取得します。デーモンが不在でも自動起動・sudo は行いません。`dopa status` はありません。

`install` の再実行はデーモンの更新です。更新・削除では進行中の全セッションを終了します。設定の復元を確認してからサービスの登録解除とファイル操作へ進み、失敗した場合は復旧に必要なファイルを保持します。削除は `dopa` CLI 自体には影響しません。

`start` は導入済みサービスを起動して正常応答まで待ちます。`stop` は進行中のセッションを終了し、電源設定の復元を確認してからサービスを停止します。`restart` はこの安全な停止と起動を一続きで行います。いずれもroot権限が必要です。`dopa-daemon run` はlaunchd用のroot必須の入口で、フォアグラウンド動作し、自分自身をバックグラウンド化しません。OS再起動後もサービスを起動します。

| パス | 用途 |
| --- | --- |
| `/Library/LaunchDaemons/dev.amas.dopa.daemon.plist` | LaunchDaemon 定義 |
| `/Library/PrivilegedHelperTools/dev.amas.dopa.daemon` | root 所有の実行ファイル |
| `/var/run/dopa/control.sock` | 公開 Unix domain socket |
| `/var/db/dopa/config.json` | 許可 UID |
| `/var/db/dopa/lock` | 電源操作を行うプロセスの排他 |
| `/var/db/dopa/session` | 未完了の復元記録 |

旧版の `dev.dopa.daemon` サービスが導入済みの場合、新しい `dopa-daemon install` は設定済みユーザーを保持したまま旧サービスを安全に停止・削除し、`dev.amas.dopa.daemon` へ移行します。新旧のlaunchdサービスを同時には起動しません。

## 公開 API

Unix domain stream socket 上で UTF-8 の NDJSON（1 行 1 JSON オブジェクト）を使用します。ソケットへの接続だけでスリープを抑制することはありません。接続元を OS の UID で認証し、許可ユーザーと root のみ受け付けます。

```json
{"id":"1","method":"hello","params":{"apiVersion":1,"client":{"name":"example","version":"1.0"}}}
{"id":"2","method":"status.get","params":{}}
{"id":"3","method":"session.acquire","params":{"options":{"keepDisplayOn":false,"stopOnLidClose":false}}}
```

応答は同じ `id` と `result` または `error` を持ちます。セッションは取得した接続に所属し、切断時に解除されます。通常のrelease/updateは別接続からsessionIdを指定しても操作できません。

公開操作は `hello`、`status.get`、`status.subscribe`、`status.unsubscribe`、`session.acquire`、`session.update`、`session.release` です。管理者認証付きの `admin.stopSessions` は確認済みIDをまとめて停止し、サービスの受付を維持します。更新・削除用の `admin.prepareShutdown` は root に限定します。購読は初期状態と変更後の完全な snapshot を返します。

メッセージ上限は 64 KiB。フレーミング、互換性、応答・通知の順序、状態モデルとエラーの契約は [DESIGN.md](DESIGN.md) を参照してください。Swift 用の `DopaProtocol` と `DopaClient` もライブラリとして提供します。外部クライアントは別言語でも実装できます。

## 復元と障害

抑制前に復元記録をディスクへ同期し、設定の書き込み後に読み戻します。最後のセッション終了時は元の値 false へ戻し、確認後に記録を削除します。元からスリープ禁止、未知の設定値、壊れた記録は勝手に引き継ぎません。画面 assertion の解除とシステム設定の復元は両方を試みます。

クライアントの SIGKILL も接続断として解除します。デーモン異常終了後は launchd が再起動し、受付再開前に未完了記録から復旧します。復旧できなければ degraded として状態確認を提供し、新たな抑制を拒否します。

**デーモンとの接続が切れた CLI は自動で抑制を再取得しません。** 状態未確認としてエラー終了するため、状態を確認した上で再実行してください。旧 guardian 方式の自動再接続からの変更です。全プロセスの強制終了、電源断、SDK 呼び出しの停止では即時復元を保証できません。

旧版の `sudo dopa` が動作中なら、そのセッションを終了してから新サービスへ切り替えてください。既存の `dopa-v1` 復元記録は引き継ぎます。他の閉蓋抑制ツールとの同時変更はサポートしません。

## 電源管理 API

| 機能 | API |
| --- | --- |
| システム・閉蓋スリープ抑制 | IOKit SPI の `IOPMCopySystemPowerSettings` / `IOPMSetSystemPowerSetting`、`SleepDisabled` |
| 画面消灯抑制 | `IOPMAssertionCreateWithName` / `IOPMAssertionRelease` |
| 蓋状態 | `IORegistryEntryCreateCFProperty` の `AppleClamshellState` |

閉蓋抑制は公開 SDK だけでは保証できず、Apple の [pmset 実装](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.m) と同じ SPI を使います。`dlsym` で存在を確認し、利用できない場合に外部コマンドへフォールバックしません。SPI や蓋プロパティは将来の macOS で変更される可能性があります。Apple メニューのスリープにも影響します。

## 検証

```sh
make test
make check
```

`make test` は Swift とブラウザUI prototype のテストを実行します。`make check` はそれらに加えて、CLI とデーモンの厳格な release ビルドも行います。

テストは模擬電源と一時ディレクトリを使用します。通常のテストでシステムの SleepDisabled や LaunchDaemon 登録を変更しません。製品にはテスト用の電源切り替えオプションを含めません。

UIを実電源に触れず確認する場合は `mise exec -- scripts/run-ui-fixture.sh` を実行し、メニューバーのカップアイコンから検証用パネルを開きます。専用バンドル・一時ソケット・模擬電源・ダミー認可を使い、UI終了時に自身のテストプロセスと一時ファイルを片付けます。`build-app.sh --ui-test-fixture` は独立したビルド領域でUIのみの `Dopa-Test.app` を生成し、CLI・デーモンを同梱しません。実際の管理者認証画面を試すものではありません。

`PanelLayoutTests` は不可視のネイティブviewでタブ間の高さ、無制限切り替え、時間入力の整列を確認します。生成する `.build/ui-acceptance/panel.png` ではGlass素材を正しく描画できないため、素材と操作感の確認は実パネルで行います。

実際の root サービス導入・SleepDisabled 書き込み・閉蓋継続は [実機受入れ手順](docs/acceptance.md) で別途確認してください。

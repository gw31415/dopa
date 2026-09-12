# SwiftUIメニューバーアプリの実装計画

この計画は会話を参照せず再開できる実行計画である。作業ディレクトリは `/Users/ama/dopa`。2026-09-12のユーザー依頼で、完成したブラウザデモを基に本番のSwiftUI実装へ進むことが承認された。以前の「UIは未着手・範囲外」という決定はこの依頼で更新された。

最初にこの計画と完成したワイヤーフレームをコミットし、そのコミットの読み戻しが終わるまでSwiftの実装を開始しない。その後は実装・検証・`.app`生成まで続ける。

## 目的と成果物

- macOS 26以降で動く `Dopa.app` を生成する。メインウィンドウは作らず、メニューバーに常駐する。
- SwiftUIの `MenuBarExtra` と `.menuBarExtraStyle(.window)`、Info.plistの `LSUIElement=true` を使用し、Dockやアプリ切替にも通常ウィンドウを出さない。閉じるのは操作パネルだけで、セッションや監視は継続する。
- `prototypes/ui/` は完成済みのWebワイヤーフレームとして保存する。寸法・色・影・CSS・DOM構造をSwiftへ直訳しない。操作の意味と配置の不変条件を再現する。
- タブバーを含むアプリ全体をmacOS標準のLiquid Glassのデザイン体系で構成する。SwiftUI標準のTabView、フォーム、Toggle、TextField/DatePicker、Popover、confirmationDialogと標準glass/glassProminentボタンを使い、独自のガラス描画・ぼかし・色・角丸・アニメーションを作らない。
- CLI・デーモンのmacOS 13互換を維持する。Liquid Glassを必要とするUIだけをmacOS 26以上に限定する。
- 実際のDopaClient/daemon APIへ接続する。起動やパネル表示だけで抑制を開始しない。テスト・UI検証は明示的なテストハーネスと模擬電源を使う。

## 現状と再開に必要な情報

- ベースは `main` の `91f01b0`（v0.2.1）。既存のdaemon/API実装は `eef26e2`、インストールのmacOSパス修正は `91f01b0` に記録されている。以前の未追跡PLANS.mdはこの完了済みdaemon作業の記録だったため、本計画に更新する。
- `Package.swift` はSwift 6.0、macOS 13、外部パッケージなし。`DopaProtocol` / `DopaClient` / `DopaCore` / `DopaManagement`、CLIとdaemon、既存テストがある。
- UI仕様は `docs/ui-concept.md`、ブラウザの挙動は `prototypes/ui/{index.html,styles.css,app.js,schedule.mjs,schedule.test.mjs,validation-popover.mjs}`。ブラウザテストは18件。
- ホストはmacOS 26.6.2、XcodeのSwift 6.3.3、MacOSX26.5.sdk。SwiftUIのTabView `.tabBarOnly` / `.grouped` とglassボタンAPIがSDKにある。標準タブの適切なスタイルを実際のMenuBarExtraで確認して選ぶ。
- デーモンの配備済みコピーが稼働している。コードをビルドしてもそのコピーは更新されない。実デーモンのinstall/updateは進行中セッションを終了するため、今回の模擬検証とは分ける。
- `DopaConnection` は同期・ロック直列化された非Sendableクラス。MainActor上でソケット読み取りを行わず、専用の直列実行経路に閉じ込める。
- `status.subscribe` は全セッションを既に返す。`session.acquire/update/release` は接続所有者専用。`admin.prepareShutdown` はdrainingへ移行する更新・削除用なので、UIの全停止に流用してはいけない。
- リポジトリの `DESIGN.md` / `README.md` は旧スコープを記述している。実装に合わせて既存節を更新し、UI範囲外の記述を残さない。

## 確定したUIの契約

### 共通構造とサイズ

1. ヘッダー、上部の「このアプリ / 全体管理」タブ、タブ内容、必要最小限のアプリ終了操作を持つ。メニューバー常駐でメインウィンドウは作らない。
2. 上部タブは標準Liquid GlassのTabViewへ置き換える。Web風の独自セグメントや角丸背景を作らない。
3. どちらのタブでもパネルの位置・高さ・幅を変えない。サイズはSwiftUIのレイアウトと必要な内容の計測で決め、Webのpx値を複製しない。全体管理は一覧だけスクロールし、全停止を下部に固定する。
4. 時間と終了時刻の行は同じ高さで、ラベルと入力の縦位置を揃える。「今日 / 明日」は終了時刻ラベルの右に小さく添える。無制限で日付が消えてもラベル・入力・パネルを移動させない。
5. 2つの入力行の下に、無制限のチェックボックスと「＋15分 / ＋30分 / ＋1時間」を共通操作として置く。操作欄の高さも状態によらず保持する。
6. その下に時間の操作欄、余白を挟んで2つの動作Toggleを置く。HStack/VStack/Grid/標準余白、共通サイズの計測、必要ならLayoutで構成する。絶対座標やCSSの模倣は禁止。
7. 狭い幅やアクセシビリティの文字サイズでも切れない。非選択タブや隠れた操作はフォーカス・読み上げ対象から外す。

### 状態表示

選択タブによらず次の3状態を表示する。このアプリの実行中を優先する。

| 文言 | 条件 |
| --- | --- |
| スリープ防止中 | このアプリのセッションが有効。他プロセスも動作していてよい |
| 他プロセスで動作中 | このアプリは停止、ほかのセッションが有効 |
| オフ | 確認済みで全セッション停止 |

色はデモのRGBを再現せず、標準の意味的スタイルに任せる。接続断・degraded・未確認を「オフ」と偽らず、接続状態の案内として別に示す。通知やポーリングのたびに同じ状態を読み上げ直さない。

### 時間の編集と操作

- 初期値は1時間、範囲は1秒〜24時間。時間はHH:MM:SSで編集する。無制限を文字列で入力させない。
- 時間と終了時刻は同じ期限の2表現として連動する。今より前の時計時刻を入力した場合は翌日として「明日」を表示する。
- 停止中の有効な手入力は即時に設定へ反映する。開始はそのまま使える。不正入力中はエラーを示して開始を無効化し、直前の有効設定を壊さない。
- 実行中の手入力だけ、未確定draftを作って実際の期限を保持する。右端の「停止」を「キャンセル / 適用」に切り替える。通常の開始／停止と編集操作は同時に出さない。
- 実行中の時間入力を適用すると適用時点からその長さを数える。終了時刻入力はその絶対時刻を保持し、適用待ちで過ぎたらエラーにする。キャンセルは実際の期限へ戻す。
- 元の期限に達したら実行を終了し、未適用のdraftを破棄する。パネルを閉じていても期限の処理を続ける。
- ピルは停止中・実行中ともに即時適用する。実行中は既存期限へ加算する。有効な手入力draftがあれば表示値に加算して即時反映する。上限超過、不正値、期限切れの加算は無効にする。
- 無制限の切替は即時適用する。オン中は時間／終了時刻を無効にし、スリープ防止そのものは継続する。オフではオン直前の有限の時間長（実行中は残り時間）を復元し、その時点から数える。無制限からピルを押すと0分起点の有限時間へ戻る。
- 初期値・オプションは設定として保存してよいが、アプリ起動や再接続で抑制を自動取得しない。絶対時刻を保存する場合は有効性を再検査する。

### 動作設定、エラー、管理

- 「ディスプレイをスリープさせない」「ディスプレイを閉じたら停止」は標準Toggle。時間draftと独立して即時操作し、サーバー応答で確定する。失敗時に成功状態を残さない。
- 入力エラーは該当欄に標準popoverで表示する。一度に1つ、入力の修正を妨げず、修正で閉じる。閉じたエラーを毎秒の時計更新で勝手に開き直さない。
- このアプリの停止は確認なし。CLIなど他の使用元の停止と全停止は標準confirmationDialogを操作元に紐づけ、対象・結果を明記する。
- 全体管理で自分の行は「dopa / このアプリ」。他の使用元はclientNameとOS由来のPIDで区別する。自己申告名を認可に使わない。
- 管理確認をキャンセルしたら状態を維持する。行削除後は近い操作へフォーカスを移し、一覧のスクロール位置を大きく動かさない。
- 一覧閲覧は既存APIで非特権に可能なため、タブ表示のたびに管理者認証を求めない。他接続の停止に必要な権限は実際の停止直前にmacOS標準のAuthorization Servicesで取得し、デーモン側でも検証する。OSの認証画面を独自に模倣しない。

## 実装方針と変更先

### M1 — 計画を保存してコミット

`PLANS.md` と `docs/ui-concept.md` の現在フェーズを更新し、完成した `prototypes/ui/` を再開用ワイヤーフレームとして同じコミットに含める。Swiftコードは変更しない。許可パスだけstageし、差分・テスト結果を確認して `docs(ui): record native SwiftUI implementation plan` のコミットを作り、readbackする。

### M2 — セッション管理APIを安全に追加

- `Sources/DopaCore/DaemonService.swift` に、capabilityで交渉する `admin.stopSessions` を追加する。paramsは確認した `sessionIds` の配列とAuthorizationExternalFormのbase64表現。対象を1回のエンジン処理で終了し、サービスは受付可能のままにする。新たに開始された別IDを巻き込まない。
- 既存release/updateの接続所有権とsocket UID認証を維持する。rootか、macOS Authorization Servicesで有効な管理権限を確認できた呼び出しだけ許可する。Authorizationデータをログ・保存・エラー文へ出さない。無効な形や権限の拒否は一切のセッション変更より先に検査する。
- 既存の `terminate(reason:keys:)` を利用し、所有者へ `session.ended(reason: user_stopped, cleanup: ...)` を通知する。復元失敗時を成功扱いにしない。
- `DopaConnection` は交渉済みhello/capabilitiesを読み取れるようにする。旧デーモンでは管理停止を無効化し、更新が必要な理由を標準UIで表示する。
- `DopaCLI/main.swift` は管理操作で正常に終了したセッションを正常終了として扱う。
- Authorizationの小さな共有モジュールまたは明確なクライアント／サーバー境界を設け、テストに認可判定を注入できるようにする。特権実行やパスワード取得の独自コード、deprecatedなAuthorizationExecuteWithPrivilegesは使わない。

### M3 — ネイティブの状態モデルと通信

- `Sources/DopaUIModel/` 等にFoundation中心の時間設定・draft・無制限・状態snapshotの型と、MainActor外でDopaConnectionを所有する通信層を作る。
- 一つの接続で所有セッションと購読を管理する。読み取りは短い非ブロッキング／タイムアウト付きのポーリングを専用直列経路で行い、応答・所有者終了・snapshotをMainActorへ反映する。
- 再接続は監視だけを再開し、セッションを自動取得しない。request失敗で接続が無効になったときは所有セッション・期限の状態を未確認として扱う。
- ローカルタイマーはパネル表示に依存させない。開始・更新・終了の処理中を区別し、同じ操作を重ねて送らない。終了失敗、閉蓋による終了、daemon更新をUIに反映する。
- 型付きsnapshotは未知の追加フィールドを許容する。revisionは文字列の数値として桁落ちなく扱い、instanceIdが変われば以前の所有情報を持ち越さない。

### M4 — SwiftUIメニューバー操作パネル

- `Sources/DopaUI/` にApp、MenuBarExtra、共通ヘッダー、標準TabView、時間フォーム、全体管理一覧、入力popover、管理confirmationDialogを実装する。
- `.window` はメニューバーから開くパネルのスタイルであり、WindowGroupなどのメインウィンドウは追加しない。
- Liquid Glassは標準のナビゲーション／ボタン／プレゼンテーションに任せる。標準フォームの内容までガラスを重ねる独自背景を付けない。システムのReduce Transparency / Reduce Motion / Contrast / Dark Modeへ追従する。
- 手入力時の文字列と確定値を分け、時計更新でキャレットを動かさない。入力の高さ・横位置、タブや操作の切替での共通パネル寸法を実際のアプリで検証する。
- メニューバーのアイコンにはSF Symbolを使い、アプリを終了する標準操作を用意する。終了時は自身の解除確認を試み、他プロセスは継続する。

### M5 — `.app`バンドルと検証・引き渡し

- `Package.swift` にUI/model/必要な認可モジュールとテストを追加する。既存CLIの最低OSを上げない。
- `scripts/build-app.sh` と `Resources/Dopa-Info.plist` 等で `.build/Dopa.app` を再現可能に生成する。CFBundleExecutable / Identifier / PackageType APPL / LSUIElement / LSMinimumSystemVersion 26.0を設定し、ローカル実行用のad-hoc署名を検証する。
- 配布用Developer ID署名・notarization・自動起動登録・リリース公開は今回の明示依頼には含まれない。必要な設定や手順をREADMEに記録し、実行していないことを明確にする。
- `DESIGN.md` は現行のUI境界・認可API・セッション終了理由・障害時の契約へ更新する。「maintain-design」スキルを適用する。READMEにbuild/open/デーモン更新手順を追加する。
- 実際の電源設定や配備済みサービスを書き換えずに、模擬電源の一時ソケットを使う専用UI検証ハーネスで操作を受け入れる。製品バンドルの通常起動は常に信頼できるrootデーモンへ接続する。

## 検証と受入れ

作業ディレクトリはすべて `/Users/ama/dopa`。実行前は以下を期待結果とし、実行後に事実をこの計画へ追記する。

1. `/opt/homebrew/bin/mise exec -- node --test prototypes/ui/schedule.test.mjs` — 保存するワイヤーフレームの18テストが成功。
2. `/opt/homebrew/bin/mise exec -- swift test` — 既存のCLI・電源復元・socketテストと追加したUIモデル／管理権限テストがすべて成功。実際の電源設定・launchdを変更しない。
3. `/opt/homebrew/bin/mise exec -- swift build -c release --product dopa -Xswiftc -warnings-as-errors -Xcc -Wall -Xcc -Wextra -Xcc -Werror` と同じ `--product dopa-daemon` — 既存製品の厳格ビルドに成功。
4. `/opt/homebrew/bin/mise exec -- scripts/build-app.sh` — `.build/Dopa.app` を作成。`plutil -lint .build/Dopa.app/Contents/Info.plist` と `codesign --verify --strict .build/Dopa.app` が成功。
5. UIモデルテスト — 停止中の即時編集、実行中draftの適用／キャンセル、時刻の日跨ぎ／期限切れ、ピルの即時累積、無制限の復元、表示中断中の期限、切断時の未確認、3状態の優先順位。
6. APIテスト — 権限なし／無効Authorizationで不変、許可済み対象だけの停止、他セッション継続、全停止後の再取得、owner event順、cleanup失敗の伝播、旧capabilityの無効化。
7. 実UIをCUAで確認 — メニューバーのみ、独立メインウィンドウなし、標準Liquid Glassタブとボタン、両タブ同サイズ、時刻2行同高、日付の有無で位置不変、編集操作と通常操作の排他、エラーpopover、一覧スクロール、権限キャンセルで不変。テスト専用の模擬電源で開始／停止を確認する。
8. `git diff --check` — 空白エラーなし。成果物へのリンク・実行コマンド・実機で未検証の項目を最後に報告する。

## 進捗

- [ ] M1 計画・ワイヤーフレームのコミットとreadback。
- [ ] M2 管理停止API・認可・CLI通知・互換性の実装とテスト。
- [ ] M3 時間モデル・接続状態・タイマーの実装とテスト。
- [ ] M4 Liquid GlassのSwiftUIメニューバーパネルとレイアウト受入れ。
- [ ] M5 `.app`生成・署名検証・既存回帰・ドキュメント更新。

完了した作業は、検証事実を保持してからGitへアーカイブする。未達の受入れを完了として記録しない。計画コミットの後に実装を始め、実装のコミット／push／リリースの追加承認をこの計画から推定しない。

## 再実行と復旧

- `.build` 内のこのタスク専用バンドルとハーネス一時ディレクトリのみ再生成する。配備済みdaemonとユーザーの実セッションは変更しない。
- テストハーネスは所有するプロセスとソケットだけを終了・削除する。実daemonの不在や古いバージョンを理由に自動sudo・自動installをしない。
- 計画コミットは明示した8ファイルのみをstageする。既存の別作業がstageされていれば混ぜずに中断して状況を伝える。ユーザーの変更をreset/restoreしない。
- 失敗したビルド・UI検証の原因と残りの手順を本計画へ書き、次回は該当milestoneから続ける。スコープ変更は最新のユーザー指示を優先する。

## 参照

- [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [TabBarOnlyTabViewStyle](https://developer.apple.com/documentation/swiftui/tabbaronlytabviewstyle)、[GroupedTabViewStyle](https://developer.apple.com/documentation/swiftui/groupedtabviewstyle)
- [Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)
- [Authorization Concepts](https://developer.apple.com/library/archive/documentation/Security/Conceptual/authorization_concepts/02authconcepts/authconcepts.html)
- [Authorization Services Tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/authorization_concepts/03authtasks/authtasks.html)

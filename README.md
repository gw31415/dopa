# dopa

macOS のシステムスリープと閉蓋スリープを抑制する Swift 製 CLI です。電源操作はフレームワークAPIを直接呼び、`pmset`、`caffeinate`、`ioreg`、シェルは起動しません。配布するのは `dopa` バイナリ1個です。複数の dopa を同時に起動でき、各フロントが1つの一時的な監視プロセスを共有します。起動する実行ファイルは自分自身だけです。

## ビルドと実行

Swift 6.0 以上に対応の Xcode または Command Line Tools が必要です。外部パッケージへの依存はありません。パッケージの deployment target は macOS 13、ビルド・API検証は手元の macOS arm64 で行っています。

```sh
swift build -c release --product dopa
.build/release/dopa --help
sudo .build/release/dopa
```

| オプション | 動作 | デフォルト |
| --- | --- | --- |
| `-d`, `--keep-display-on` | 無操作による画面消灯を抑制 | OFF |
| `-l`, `--stop-on-lid-close` | 蓋を閉じたら、この起動分を終了 | OFF |
| `-h`, `--help` | ヘルプ表示。sudo不要 | — |

```sh
sudo .build/release/dopa -dl  # -ld または -d -l でも同じ
```

オプションなしでは、画面消灯を許容し、閉蓋中も本体のスリープ抑制を続けます。Ctrl+C、SIGTERM、SIGHUP、SIGQUITで、その起動分を終了します。1つでも起動していれば抑制を続け、最後の終了時に元の設定へ復元します。バッテリー残量のチェック・低残量での自動解除はありません。開始・終了・エラーはstderr、ヘルプはstdoutに出します。

`--keep-display-on` を指定した起動が1つでも残っていれば、画面消灯を抑制します。画面消灯時間の設定は変更しません。蓋を閉じた内蔵画面を点灯させるものではありません。`--stop-on-lid-close` は約0.3秒間隔で蓋状態を確認し、すでに閉じている場合も抑制を開始せず終了します。このオプションを指定していない起動分は継続します。蓋を開けても終了した起動分は自動再開しません。

## 電源管理API

| 機能 | 呼び出すAPI | 公開範囲 |
| --- | --- | --- |
| システム・閉蓋スリープ抑制 | `IOPMCopySystemPowerSettings` / `IOPMSetSystemPowerSetting` の `SleepDisabled` | **非公開SPI** |
| 画面消灯抑制 | `IOPMAssertionCreateWithName` / `IOPMAssertionRelease` | 公開IOKit API |
| 蓋状態の読み取り | `IOServiceMatching` / `IOServiceGetMatchingService` / `IORegistryEntryCreateCFProperty` | 公開IOKit API。ただし `AppleClamshellState` プロパティへの依存あり |

**閉蓋抑制まで公開SDKだけで保証できる構成ではありません。** Apple の `pmset` が利用している同じIOKit SPIを、小さなCブリッジから呼びます。関数は手元のIOKitにexportされていますが、公開SDKヘッダーには宣言がありません。`dlsym` で存在を確認し、使えないOSでは設定を変更せずエラーにします。コマンド呼び出しへのフォールバックは行いません。

SPIのABIや振る舞いは将来のmacOSで変わる可能性があります。`dlsym` はAPIの公開性や将来互換性を保証するものではありません。画面assertionはプロセスに紐づきますが、`SleepDisabled` は永続的なシステム設定なので、直接APIで書く場合も明示的な復元が必要です。

本体はSwiftで、`Sources/CDopa` のCコードはSPIの型宣言・シグナルフラグ・プロセス起動と一部POSIX関数のブリッジです。Foundationの`Process`は子をプロセスグループのリーダーにするため、監視側の`setsid`と衝突します。製品の監視プロセス起動には`posix_spawn`を使用しています。

根拠：[Apple pmset の実装](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.m)。コピーした実装コードはなく、APIの呼び方と所有権を参照しています。

## 多重起動と復元

各フロントは Unix domain socket `/var/db/dopa/control.sock` に接続します。開いている接続を起動中のセッションとして扱うため、PIDファイルや永続的な参照カウントは不要です。フロントをSIGKILLした場合も切断を検出し、残るセッションに合わせて抑制を更新します。

`/var/db/dopa/lock` の `flock` は、設定を書き換える監視プロセスを1つに決めるために残しています。フロントの多重起動は拒否しません。ソケットのパスは異常終了後も残るため、ロックを取得した監視側だけが古いソケットを削除して作り直します。ディレクトリは0700、ソケットは0600で、接続相手のUIDも確認します。

`dopa-v1` 形式の `/var/db/dopa/session` に復元情報を保存します。未完了の記録があれば監視プロセスの起動時に復旧を試みます。

監視側は設定変更前に記録をディスクへ同期し、書き込みと読み戻しを行います。最後のフロントとのソケット切断や終了要求で元の値へ戻し、復元を確認してから記録を削除します。通常の終了要求では、その起動分の解除完了を待ってフロントが終了します。画面assertionの解除とシステム設定の復元は、一方が失敗しても両方を試みます。

元からスリープ禁止の状態、未知の設定値、壊れた記録は勝手に引き継ぎません。復元に失敗した場合は記録を保持してエラー終了します。監視側だけが強制終了した場合、残っているフロントが再接続し、新しい監視プロセスが復旧して抑制を再開します。復旧中は一時的に抑制が解除されます。全プロセスの強制終了や電源断では設定が残る可能性があり、次回の `sudo dopa` 起動時に復旧を試みます。SDK呼び出し自体が応答しなくなった場合は、安全に中断するAPIがないため、その呼び出しの完了を待ちます。

他の閉蓋抑制ツールとの同時変更はサポートしません。Appleメニューのスリープにも影響します。

## テスト

```sh
swift test
swift build -c release --product dopa -Xswiftc -warnings-as-errors -Xcc -Wall -Xcc -Wextra -Xcc -Werror
```

通常のテストはファイルで模擬した電源設定を使い、実際のシステムスリープ設定を変更しません。既定値、ヘルプ、記録と排他、復元失敗、フロントへのSIGINT/SIGTERM/SIGHUP/SIGQUIT/SIGKILL、有効化途中の終了、復元完了までの終了待ち、監視プロセスのセッション分離、閉蓋時の終了、蓋取得失敗、画面抑制の解除を検証します。さらに、同時起動での監視共有、最後の終了時のみの復元、起動ごとの画面・閉蓋オプション、監視側の強制終了後の再接続、古いソケットと記録からの復旧、ソケットの権限と不正なパスの拒否を検証します。

実機APIの読み取りと一時的な画面assertionの作成・解除だけを確認する場合：

```sh
swift build --product DopaTestHarness
.build/debug/DopaTestHarness --native-probe
```

`DopaTestHarness` はテスト専用で、配布する必要はありません。テスト用の設定切り替えは製品CLIに含めていません。

実際の `SleepDisabled` 書き込み・閉蓋の継続・閉蓋時の解除は、[実機受入れ手順](docs/acceptance.md) で確認してください。物理的な閉蓋試験はまだ行っていません。

# リリース手順

## 初回設定

公開する macOS app は Developer ID Application 証明書で署名し、Apple の notary
service に送信します。証明書を password 付き `.p12` として書き出し、App Store
Connect の Integrations で notarization 用 API key (`.p8`) も作成します。次の 5 つを
`dopa` リポジトリの Actions secret に登録してください。

- `MACOS_CERTIFICATE_P12_BASE64`: `.p12` を base64 にした値
- `MACOS_CERTIFICATE_PASSWORD`: `.p12` の password
- `APPLE_NOTARY_KEY_P8_BASE64`: `.p8` を base64 にした値
- `APPLE_NOTARY_KEY_ID`: API key の Key ID
- `APPLE_NOTARY_ISSUER_ID`: API key の Issuer ID

ファイルは macOS 上で次のように登録できます。

```sh
base64 -i DeveloperIDApplication.p12 | \
  gh secret set MACOS_CERTIFICATE_P12_BASE64 --repo gw31415/dopa
base64 -i AuthKey_KEYID.p8 | \
  gh secret set APPLE_NOTARY_KEY_P8_BASE64 --repo gw31415/dopa
gh secret set MACOS_CERTIFICATE_PASSWORD --repo gw31415/dopa
gh secret set APPLE_NOTARY_KEY_ID --repo gw31415/dopa
gh secret set APPLE_NOTARY_ISSUER_ID --repo gw31415/dopa
```

さらに `HOMEBREW_TAP_TOKEN` を登録します。値には `gw31415/homebrew-tap` だけを
対象にした fine-grained personal access token を使い、Repository permissions は
次の 2 つだけを書き込み可にします。

- Contents: Read and write
- Pull requests: Read and write

作成した token は次のコマンドで secret として登録します。

```sh
gh secret set HOMEBREW_TAP_TOKEN --repo gw31415/dopa
```

リポジトリ標準の `GITHUB_TOKEN` は別リポジトリへ書き込めないため、この secret が
ない stable release は asset の公開後に tap 更新 job が失敗します。prerelease も署名・
notarization・配布 asset の添付までは行いますが、Homebrew tap は更新しません。
prerelease を後から stable に昇格した場合は、同じ tag で tap 更新まで再実行されます。
app の version 規約を保つため、prerelease の場合も tag 自体は接尾辞のない `vX.Y.Z`
形式にします。

## 公開

1. `Resources/Dopa-Info.plist` の `CFBundleShortVersionString` を、先頭の `v` を除く
   リリース番号へ更新します。
2. `make check app` を実行します。
3. 同じ番号の tag（例: `v0.3.0`）を push し、その tag から GitHub Release
   を publish します。
4. `Release` workflow の完了と、`gw31415/homebrew-tap` に作成された pull request
   の CI を確認します。

workflow は tag の source をもう一度テスト・ビルドし、配布物を生成して Release に
添付します。app と同梱 executable は hardened runtime と secure timestamp を有効にして
Developer ID 署名し、notarization ticket を staple します。stable release では生成した
Cask を macOS 26 runner の通常の Gatekeeper 経路で実際にインストールし、アプリの起動、
inventory に登録されたすべての CLI、アンインストールを確認してから tap の pull request
を作成します。失敗時は同じ workflow を再実行できます。完全に公開済みの asset set は
署名 timestamp が変わっても上書きせず、manifest、checksum、version、Developer ID 署名、
notarization ticket を再検証してそのまま使います。途中で止まった upload だけは一時 marker
を手掛かりに全体を再生成できるため、Cask が参照した asset の checksum は変わりません。
tap 更新 job は release asset の生成とは分離して直列化し、1 本の automation branch と PR
を最新版へ更新します。tap の main または未merge branch より古い Cask への更新も拒否します。

## 配布対象を追加・変更する場合

`release/artifacts.json` が配布対象の唯一の inventory です。SwiftPM の executable
product はすべて、単体コマンドまたは app の構成要素としてこのファイルで分類する
必要があります。パッケージ処理は `swift package dump-package` の結果と inventory を
比較するため、新しい product を追加したのに配布定義を更新しなければ失敗します。

app、同梱 helper、追加ファイルについても inventory から archive と
`release-manifest.json` を生成します。workflow は `dist/` に生成されたファイルを
まとめて upload し、GitHub Release 上の asset 名と完全一致することを確認するため、
workflow 側に別の添付リストを増やしてはいけません。

現在の配布物は次のとおりです。

- `Dopa-macos-arm64.zip`: `Dopa.app`。app 内に `dopa` と `dopa-daemon` を含む
- `dopa-macos-arm64.tar.gz`: CLI、daemon、shell completion、利用時に必要な文書
- `release-manifest.json`: version、構成要素、archive の SHA-256
- `SHA256SUMS`: 上記の検証用 checksum

変更後は最低でも次を実行します。

```sh
make release-check
make check app
```

将来 GitHub Actions 自身から Release を作る方式へ変更する場合は、Release 作成と tap
更新を同じ workflow に置きます。標準 `GITHUB_TOKEN` が作成した release event では、
別の `release.published` workflow は起動しません。

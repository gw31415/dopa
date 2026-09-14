# リリース手順

## 初回設定

公開する macOS app はApple Developer Programを必要としないad-hoc署名とhardened runtime
で配布し、notarizationは行いません。Apple Silicon上のコード署名構造は保ちますが、Appleによる
開発元・マルウェア検証済みという意味は持ちません。通常のquarantineを意図的に残し、
利用者自身が対象を確認してから実行を許可する設計です。

Homebrew tapへのPRは、GitHub ActionsのOIDC identityを
[Octo STS](https://github.com/octo-sts/app)で短命なGitHub App installation tokenへ
交換して作成します。PAT、deploy key、Actions secretは使いません。Octo STS GitHub Appは
Repository accessを `Only select repositories` とし、`gw31415/homebrew-tap` だけに
installします。Appのinstall時には広いpermission一覧が表示されますが、release workflowへ
発行できるtokenはtap側の `.github/chainguard/dopa-release.sts.yaml` が指定した次の3権限に
限定します。

- Contents: Read and write
- Pull requests: Read and write
- Commit statuses: Read and write

`dopa`には `homebrew-release` environmentを作成し、deployment branches and tagsを
`v*` tagだけに制限します。tap側ではGitHub Actionsを無効化し、workflowを置きません。
`main`はPR、1件の人間によるapproval、`dopa/release-verified` statusを必須にし、
Octo STS Appを保護ルールのbypass対象にしません。個人repositoryの所有者は初回設定と
手動保守のbreak-glassとしてadmin bypassを保持しますが、通常のreleaseでは使いません。

stable releaseでは、`id-token`権限を持たないjobでCaskの実インストール検証を完了します。
その後、新しいrunnerのpublication jobが検証済みCask本文とSHA-256だけを受け取り、OIDC tokenを
取得してtapのautomation branch、検証status、pull requestの作成に使います。このjobはsourceを
checkoutせず、release asset、tap script、配布binaryを実行しません。prereleaseもad-hoc署名した
配布assetの添付までは行いますが、Homebrew tapは更新しません。
prerelease を後から stable に昇格した場合は、同じ tag で tap 更新まで再実行されます。
app の version 規約を保つため、prerelease の場合も tag 自体は接尾辞のない `vX.Y.Z`
形式にします。

## 公開

1. `Resources/Dopa-Info.plist` の `CFBundleShortVersionString` を、先頭の `v` を除く
   リリース番号へ更新します。
2. `make check app` を実行します。
3. 同じ番号の tag（例: `v0.3.0`）を push し、その tag から GitHub Release
   を publish します。
4. `Release` workflow の完了後、`gw31415/homebrew-tap` に作成されたpull requestで、
   変更対象が `Casks/dopa.rb` だけであること、version、URL、
   `dopa/release-verified` が成功していることを確認してapproveします。SHA-256を人間が
   比較する必要はありません。auto-mergeが予約されているため、approval後にmergeされます。

workflow は tag の source をもう一度テスト・ビルドし、配布物を生成して Release に
添付します。appと同梱executableはすべてad-hoc署名かつhardened runtimeであることを検証します。stable release
では生成したCaskをmacOS 26 runnerへ通常インストールし、Caskに未notarizedである旨と
明示的な許可手順が含まれることを確認します。その後、利用者向けに記載したものと同じ
`xattr -dr com.apple.quarantine /Applications/Dopa.app` を対象appだけに実行し、アプリの
起動、inventoryに登録されたすべてのCLI、アンインストールを確認してからtapのpull request
を作成します。workflowやCaskがquarantineを暗黙に解除することはありません。

失敗時は同じworkflowを再実行できます。完全に公開済みのasset setは上書きせず、manifest、
checksum、version、ad-hoc署名を再検証してそのまま使います。途中で止まったuploadだけは
一時markerを手掛かりに全体を再生成できるため、Caskが参照したassetのchecksumは変わりません。
tap更新jobはrelease assetの生成とは分離して直列化し、1本のautomation branchとPRを
最新版へ更新します。tapのmainまたは未merge branchより古いCaskへの更新も拒否します。
PR branchのhead commitには、検証を実行したdopa workflow runへのリンクを持つ
`dopa/release-verified` statusを付けます。新しいreleaseでbranchが更新されれば古いapprovalと
statusはhead SHAに追従しないため、新しい内容の確認が必要です。Octo STSまたはGitHub APIが
利用できない場合はrelease assetを残したままtap更新だけが失敗し、同じworkflowを再実行できます。

## 配布対象を追加・変更する場合

`release/artifacts.json` が配布対象の唯一の inventory です。SwiftPM の executable
product はすべて、単体コマンドまたは app の構成要素としてこのファイルで分類する
必要があります。パッケージ処理は `swift package dump-package` の結果と inventory を
比較するため、新しい product を追加したのに配布定義を更新しなければ失敗します。
`macOSDistribution` もこのinventoryに固定し、ad-hoc署名・hardened runtime・未notarizedという配布方針と
実際のarchiveが異なる場合は公開を止めます。

app、同梱 helper、追加ファイルについても inventory から archive と
`release-manifest.json` を生成します。workflow は `dist/` に生成されたファイルを
まとめて upload し、GitHub Release 上の asset 名と完全一致することを確認するため、
workflow 側に別の添付リストを増やしてはいけません。

現在の配布物は次のとおりです。

- `Dopa-macos-arm64.zip`: `Dopa.app`。app 内に `dopa` と `dopa-daemon` を含む
- `dopa-macos-arm64.tar.gz`: CLI、daemon、shell completion、利用時に必要な文書
- `dopa.rb`: app archiveのSHA-256と全CLI・shell completion・未notarized警告を含むCask
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

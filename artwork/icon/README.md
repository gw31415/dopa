# Dopa icon

「夜を越えて灯る」を表す、淡い青の月と琥珀色の光。Caffeineのカップ、Amphetamineのカプセルとは異なる輪郭と色の組み合わせにした。

- `Dopa.svg`: 1024 × 1024の統合SVG原稿。背景・月・光の3グループ。
- `moon.svg` / `light.svg`: Icon Composerに渡す、透明背景の前景SVG。月は1つの短いパス、光は1つの円。2ファイル合計556 bytes。
- `../../Resources/Dopa.icon`: アプリに組み込む正式なIcon Composerドキュメント。`Assets/`内に同じSVGを保持する。
- `renders/`: Icon Composer同梱の`ictool`で出力したmacOSの確認用PNG。ビルドの入力には使用しない。
- `preview.html`: SVG原稿と各レンディションをブラウザで見比べるためのローカルプレビュー。

SVGは直接記述したベクターで、画像のトレース、埋め込みビットマップ、フォント、フィルターを含まない。原稿にシステムの角丸マスク、影、ガラスのハイライトは焼き込まない。プレビューページのSVG表示にだけCSSの角丸を適用している。

## Icon Composer

背景はインディゴのグラデーション。前景は独立した2グループとし、各SVGにLiquid Glassを適用した。月の透過は30%、光は12%、両方の影はNeutral 35%。Defaultの前景色は月が`#F0F9FF → #95CEFF`、光が`#FFE49B → #FF9B47`。DarkとMonoはIcon Composerの自動適応を使う。色を失っても、月と光は離れた輪郭として識別できる。

編集は`Resources/Dopa.icon`をIcon Composerで開く。形を変える場合は`moon.svg` / `light.svg`を編集し、`.icon/Assets/`内の対応ファイルと`Dopa.svg`内の形状も同時に更新する。原稿と`.icon`内のSVGは一致させる。ドキュメント構造や素材の変更はIcon Composerで保存する。

Icon ComposerのUIでDefault / Dark / Monoを確認済み。`ictool`でDefault / Dark / Clear Light / Clear Dark / Tinted Light / Tinted Darkを出力して確認した。プレビューPNGは固定の描画結果で、OS上では壁紙・色・照明・サイズなどに応じて描画が変わる。

```sh
# プロジェクトのルートから確認用PNGを再生成
mise exec -- bash artwork/icon/render.sh

# アイコンを含むアプリをビルド
mise exec -- scripts/build-app.sh
```

ビルドは`.icon`を`actool`でmacOS 26.0向けにコンパイルし、ベクターレイヤーを含む`Assets.car`と`Dopa.icns`をアプリへ配置する。アプリのInfo.plistには`CFBundleIconName` / `CFBundleIconFile`を設定する。メニューバーの状態表示用SF Symbolsは別用途のため既存のまま。

参考: [Apple Icon Composer](https://developer.apple.com/icon-composer/)、[Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)。

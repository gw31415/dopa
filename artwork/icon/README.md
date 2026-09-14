# Dopa icon

## 月とコーヒー

Dopaの正式なアプリアイコンは、カップから注いだコーヒーが三日月に向かって流れ、手前に長く垂れるシンボル。Caffeineのカップ単体やAmphetamineのカプセルとは異なり、月と注ぐ動作の組み合わせでDopaを表す。

`Dopa.svg`は形状と配色の統合原稿。背景・月・カップ・コーヒーを編集可能なグループに分け、画像トレース、埋め込みビットマップ、フォント、フィルターを含まない。`moon-coffee-preview.html`では原稿を大きな表示と128 / 64 / 32pxで確認できる。

## Icon Composer

正式なビルド入力は`../../Resources/Dopa.icon`。背景はIcon Composerのインディゴグラデーションで、前景は次の3グループ、4レイヤーで構成する。

1. `Coffee`
   - `coffee.svg`: カップ内の液面、注ぐ流れ、独立した滴
2. `Cup`
   - `rim.svg`: 白いリム
   - `cup.svg`: 陶器の胴体と取っ手
3. `Moon`
   - `moon.svg`: 三日月

各素材は1024×1024の共通viewBoxと透明背景を使う。`artwork/icon/`のSVGと`.icon/Assets/`内の対応ファイルは同一に保つ。背景矩形、システムの角丸、影、ぼかし、鏡面反射は素材へ焼き込まず、Icon Composerが描画する。

Defaultの色は、背景`#4C4DB3 → #171B53`、月`#E1F8FF → #8EBFFF`、陶器`#FFFAEF → #E8D7B9`、コーヒー`#70422D → #9C5E36`。CoffeeとCupは不透明度を保ちながらSpecularを有効にし、Moonには22%のTranslucencyを与える。Darkも同じレイヤー構造を使い、リムだけは背景色がGlassの縁へ混ざらないよう暖白色を明示する。

Mono / Tintedでは小さいDark表示でも形が重ならないよう、リム`1.00`、陶器`0.95`、月`0.72`、コーヒー`0.40`の専用グレースケールを使う。各グループの影は8%へ抑え、MoonのTranslucencyを無効にして、カップ、月、コーヒーの明度順を保つ。

Icon ComposerのUIでDefault / Dark / Monoと32pt表示を確認する。`ictool`でDefault / Dark / Clear Light / Clear Dark / Tinted Light / Tinted Darkを出力し、`preview.html`で比較できる。

```sh
# Icon Composerの6 Appearanceを再生成
mise exec -- bash artwork/icon/render.sh

# アイコンを含むアプリをビルド
mise exec -- scripts/build-app.sh
```

ビルドは`.icon`を`actool`でmacOS 26.0向けにコンパイルし、ベクターレイヤーを含む`Assets.car`と互換用`Dopa.icns`をアプリへ配置する。`.icns`を手作業で管理する必要はない。ビルドスクリプトが最終Info.plistへ`CFBundleIconName`と`CFBundleIconFile`を設定する。メニューバーの状態表示に使うSF Symbolsは別用途のため、現状のまま維持する。

参考: [Apple Icon Composer](https://developer.apple.com/icon-composer/)、[Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)。

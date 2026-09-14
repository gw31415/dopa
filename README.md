<p align="center">
  <img src="artwork/icon/renders/default.png" width="160" alt="Dopa のアイコン">
</p>

<h1 align="center">Dopa</h1>

<p align="center">
  <strong>必要なときだけ、Macをスリープさせない。</strong><br>
  Macの自動スリープや画面消灯を防止し、ふたを閉じた状態でも処理を継続できるようにするツールです。<br>
  メニューバーアプリとCLIの両方から操作できます。
</p>

<p align="center">
  <a href="https://github.com/gw31415/dopa/releases/latest">最新版をダウンロード</a>
</p>

## 🌟 主な機能

* **フレキシブルなスリープ防止**: 指定時間、終了日時、無制限のいずれかを選んでスリープを防止
* **クラムシェル対応**: MacBookのふたを閉じても処理をバックグラウンドで継続
* **ディスプレイ制御**: 必要なときだけ画面消灯（ディスプレイオフ）を防止
* **GUI / CLI両対応**: メニューバーパネルとターミナルコマンドから柔軟に操作
* **全体管理**: Dopaを使用中のアプリやCLIの動作状況を一括確認・停止可能

## 🖥 システム要件

| 種別 | 対応環境 |
| --- | --- |
| **メニューバーアプリ** | Apple Silicon搭載Mac / macOS 26以降 |
| **CLI** | Apple Silicon搭載Mac / macOS 13以降 |

## 📦 インストール

### Homebrewを使用する場合

```sh
brew install --cask gw31415/tap/dopa
```

### 手動インストール

Homebrewを使用しない場合は、[最新のダウンロードページ](https://github.com/gw31415/dopa/releases/latest)から入手できます。

## 🚀 使い方

### 1. メニューバーアプリ

1. アプリケーションフォルダから **Dopa** を開きます。
2. メニューバーに表示されたDopaアイコンをクリックします。
3. 継続時間または終了日時を選び、「開始」を押します。
   * **初回設定**: 初回起動時のみ、スリープ管理サービスのインストール確認が表示されます。「続ける」を選び、Macの認証を完了してください。
   * **時間の延長**: 「＋15分」「＋30分」「＋1時間」でいつでも防止時間を延長できます。
   * **バックグラウンド動作**: パネルを閉じた後も動作し続けます。
4. 止めるときは「停止」を押します。

#### 設定項目

| 設定 | オンにした場合の動作 |
| --- | --- |
| **ディスプレイをオフにしない** | 操作していない間も画面の消灯を防止します |
| **ふたを閉じたら停止** | MacBookのふたを閉じたときにスリープ防止を停止します |

> **全体管理機能**: 「全体管理」パネルから、DopaアプリやCLIで動いているスリープ防止をまとめて確認・停止できます。

### 2. CLI (コマンドライン)

ターミナルで `dopa` コマンドを実行します。

```sh
dopa
```

* 停止するには `Ctrl + C` を押します。

#### オプション一覧

| コマンド | 動作 |
| --- | --- |
| `dopa` | Macのスリープを防止（画面がオフになっても、ふたを閉じても継続） |
| `dopa -d` | ディスプレイのオフ（画面消灯）も防止 |
| `dopa -l` | ふたを閉じたら停止 |
| `dopa -dl` | ディスプレイのオフを防止し、ふたを閉じたら停止 |

※複数のDopaが動いている場合は、最後の1つを止めるまでスリープ防止が続きます。

## ⚠️ 注意事項

> [!WARNING]
> * **持ち運び時の注意**: 実行中のMacBookは、ふたを閉じても動き続けます。バッグに入れる前に必ずDopaを停止してください。
> * **バッテリー制限**: バッテリー残量低下による自動停止機能はありません。

## 🔧 サポート & 開発者情報

### サービス（デーモン）の管理

問題が発生した場合は、以下のコマンドでサービス（デーモン）の状態確認や再起動が行えます。

* **状態確認**:

  ```sh
  dopa-daemon status
  ```

* **サービスの再起動**:

  ```sh
  sudo dopa-daemon restart
  ```

### アンインストール方法

アンインストールするときは、先にサービスを削除します。

1. サービスの削除:

   ```sh
   sudo dopa-daemon uninstall
   ```

2. パッケージの削除:

   ```sh
   brew uninstall --cask dopa
   ```

### ソースからのビルド

ビルドにはmacOS 26 SDKを含むXcodeと[mise](https://mise.jdx.dev/)が必要です。

* **アプリのビルドと起動**:

  ```sh
  mise install --locked
  make app
  open .build/Dopa.app
  ```

* **CLIとデーモンのみをビルド・インストール**:

  ```sh
  make build
  sudo .build/release/dopa-daemon install
  .build/release/dopa
  ```

* **テスト・リリースビルドの確認**:

  ```sh
  make check
  ```

### ドキュメント & サポート

* 解決しない問題の報告: [GitHub Issues](https://github.com/gw31415/dopa/issues/new)
* [設計と公開API](DESIGN.md)
* [UIの仕様](docs/ui-concept.md)
* [実機での確認手順](docs/acceptance.md)
* [リソース使用量の計測](docs/resource-measurements.md)
* [リリース手順とHomebrew連携](docs/releasing.md)

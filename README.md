# Emacs 多言語Reader

Emacsで英語・日本語・その他の言語の書籍を読みながら、ローカルKokoroによる読み上げ、Google翻訳、Lookup辞書、読書メモを一つの専用フレームにまとめるプロジェクトです。

`my-read` は、通常のEPUB・テキストと、Kindle.appで表示中の英語本文を一つのフレームに統合します。Kindle本文はmacOS Accessibilityから直接取得するためOCRは不要です。どちらの本文も読み上げと翻訳の単位は1文です。

専用フレームは次の5領域で構成されます。

- 左: カーソル位置の単語を自動検索するLookup
- 中央: タブで切り替えるKindle OCR本文とEPUB・テキスト
- 右上: カーソル位置、または読み上げ中の1文のGoogle翻訳
- 右下: 読書メモ

## 主な機能

- `j` / `k` で1文ずつKokoro読み上げ
- 読み上げ中の文を本文上でハイライト
- 翻訳対象の1文を、テーマに合わせた半透明相当の薄いブルーで表示
- 読み上げ中は、カーソルが次の文へ移動しても翻訳を読み上げ中の文へ固定
- 中央にカーソルを置いたまま `l` / `;` でLookupの次・前の項目へ移動
- `my-read` / `my-read-k` 専用のLookup辞書セット
- 成功した翻訳を書籍ごとのMarkdownへ重複なしで記録
- Kindleでは前後2ページをメモリ上にキャッシュし、ページ境界をまたいで読み上げ
- Kindle本文の言語を自動判定し、OCR、翻訳方向、KokoroまたはmacOS音声を切り替え

## 必要環境

- Apple Silicon Mac
- macOS 13以降（Kindle OCRでApple Visionを使用）
- Emacs 29以降
- Python 3.11以上3.14未満
- [`uv`](https://docs.astral.sh/uv/)
- Swift 6以降（`my-read-k` を使う場合）
- Google Chrome（`my-read-k` を使う場合）
- Tesseract（日本語縦書きKindleを読む場合）
- macOSの `/usr/bin/curl` と `/usr/bin/afplay`
- Emacsパッケージ `google-translate` と `lookup`
- EPUBを読む場合は `nov.el`

Lookup本体、辞書エージェント、EPWING辞書などは、このプロジェクトとは別に利用できる状態へ設定しておいてください。

## 1. Python環境とKokoroの導入

リポジトリのルートで依存関係を作成します。`uv` は `pyproject.toml` のPython条件に合う環境を選びます。

```sh
cd ~/Sync/emacs.d/reader
uv sync
```

Kokoroサーバーは、最初の読み上げ時にEmacsから自動起動されます。先に手動起動して動作を確認する場合は次を実行します。

```sh
make run
```

別のターミナルからヘルスチェックできます。

```sh
curl --fail http://127.0.0.1:8000/health
```

既定では `127.0.0.1:8000` のみに接続し、モデル `mlx-community/Kokoro-82M-bf16`、音声 `bf_emma`、イギリス英語を使います。初回起動時はモデルの準備に時間がかかることがあります。

## 2. Emacs側の設定

`init.el` へ次のように追加します。パスは実際の配置先に合わせて変更してください。

```elisp
(add-to-list 'load-path
             (expand-file-name "~/Sync/emacs.d/reader"))

(require 'my-read)

;; 中央に開く通常書籍・ディレクトリと、右下の読書メモ。
(setq my/read-book-path "/path/to/books"
      my/read-note-file "~/Documents/english-reading.org")

;; Kokoro。
(setq kokoro-reader-server-directory
      (expand-file-name "~/Sync/emacs.d/reader")
      kokoro-reader-voice "bf_emma"
      kokoro-reader-lang-code "b"
      kokoro-reader-speed 1.0
      kokoro-reader-volume 1.0)

;; 日本語KindleページのKokoro音声。
(setq my-read-k-japanese-kokoro-voice "jf_nezumi"
      my/read-japanese-translation-target-language "en")

;; Kindleは自動言語判定。Kokoro対応言語の音声は必要に応じて変更できる。
(setq my-read-k-language "auto"
      my-read-k-kokoro-language-profiles
      '(("ja" "j" "jf_nezumi")
        ("zh" "z" "zf_xiaoxiao")
        ("es" "e" "ef_dora")
        ("fr" "f" "ff_siwis")
        ("hi" "h" "hf_alpha")
        ("it" "i" "if_sara")
        ("pt" "p" "pf_dora")))

;; Google翻訳。
(setq google-translate-default-source-language "en"
      google-translate-default-target-language "ja"
      my/read-translate-overlay-opacity 0.35)

;; 翻訳記録のルート。下に書籍名のディレクトリが自動作成される。
(setq my/read-translation-log-root
      "/Users/seijiro/Library/Mobile Documents/iCloud~md~obsidian/Documents/seijiro/001_read"
      my/read-translation-log-enabled t)

;; my-read / my-read-k の中だけで使うLookup辞書。
;; 完全な辞書IDのほか、nmacosのようなID前方一致も指定できる。
(setq my/read-lookup-dictionary-ids
      '("nmacos"
        "ndeb+~/Sync/004_dic/ee/:simpleen"
        "ndeb+~/Sync/004_dic/chujisnd/"
        "ndspell"))

;; EPUBをnov.elで開く場合。
(add-hook 'nov-mode-hook #'english-reading-mode)
```

`my/read-lookup-dictionary-ids` は通常のLookup設定を変更しません。専用フレームからの検索だけをこのリストへ限定します。空リストにすると専用フレーム内のLookupを無効にし、通常の全辞書へフォールバックしません。

現在利用できる辞書IDと選択状態は `M-x my/read-lookup-list-dictionaries` で確認できます。GUIから変更する場合は `M-x customize-option RET my/read-lookup-dictionary-ids` を使います。設定変更後の検索時に専用辞書モジュールが自動的に作り直されます。明示的に破棄する場合は `M-x my/read-reset-lookup-dictionary-module` を実行してください。

### Kokoroの主な設定項目

| 変数 | 既定値 | 用途 |
| --- | --- | --- |
| `kokoro-reader-endpoint` | `http://127.0.0.1:8000/v1/audio/speech` | 音声生成API |
| `kokoro-reader-health-endpoint` | `http://127.0.0.1:8000/health` | 起動確認API |
| `kokoro-reader-server-command` | `uv run python kokoro_server.py ...` | 自動起動コマンド |
| `kokoro-reader-server-directory` | `kokoro-reader.el` の配置先 | サーバー起動ディレクトリ |
| `kokoro-reader-backend` | `kokoro` | `kokoro` またはフォールバック用の `macos` |
| `kokoro-reader-voice` | `bf_emma` | Kokoro音声 |
| `kokoro-reader-lang-code` | `b` | `b`: イギリス英語、`a`: アメリカ英語 |
| `kokoro-reader-speed` | `1.0` | 読み上げ速度 |
| `kokoro-reader-volume` | `1.0` | `afplay` の再生音量 |
| `kokoro-reader-macos-rate` | `180` | macOSフォールバックの読み上げ速度 |

Kindleでは英語、日本語、中国語、スペイン語、フランス語、ヒンディー語、イタリア語、ポルトガル語をKokoroで読み上げます。それ以外のVision対応言語は、言語ごとのmacOSシステム音声へ自動的にフォールバックします。対応関係は `my-read-k-kokoro-language-profiles` と `my-read-k-macos-voice-alist` で変更できます。ヘッダーには判定言語、組方向、使用中の `Kokoro` / `macOS` が表示されます。

## 3. 統合読書フレームを開く

次を実行すると、新しい専用フレームが開きます。

```text
M-x my-read
```

中央は上下分割せず、同じ1ペインの `Kindle` / `EPUB` タブでKindle本文と `my/read-book-path` を切り替えます。タブはクリックでき、本文上の `C-c t` でも相互に切り替えられます。右下には `my/read-note-file` が開きます。Kindle.appで英語の本を開いてから実行してください。接続し直す場合はKindleタブで `r` を押します。`my/read-book-path` にディレクトリを指定した場合は、EPUBタブのDiredから書籍を選択できます。EPUBでは上記のhookにより `english-reading-mode` が有効になります。通常のテキストバッファでは `M-x english-reading-mode` を実行してください。

### 本文領域のキー

| キー | 動作 |
| --- | --- |
| `j` | 現在の1文を読み上げ、次の文へ進む |
| `k` | 前の1文へ戻って読み上げる |
| `p` | 現在の段落を読み上げる |
| `C-c C-k` | 合成または再生を停止する |
| `l` | 左のLookupで次の項目へ進む（Lookup側の `n`） |
| `;` | 左のLookupで前の項目へ戻る（Lookup側の `p`） |
| `C-c t` | 中央のKindle／EPUBタブを切り替える |

`l` / `;` は左ペインでコマンドを実行したあと、フォーカスを中央本文へ戻します。

このほか、`my-read.el` を読み込むと次のグローバルキーも設定されます。既存のキーと衝突する場合は、`init.el` で好みのキーへ再設定してください。

| キー | 動作 |
| --- | --- |
| `C-c p` | 段落を読み上げる |
| `C-c n` | 現在の文を読み上げ、次へ進む |
| `C-c k` | 合成または再生を停止する |

専用フレームを使わず、任意のバッファでKokoroだけを利用する場合は `M-x kokoro-reader-mode` を有効にします。この場合は上表の `C-c p` / `C-c n` / `C-c k` を使用できます。1文単位の `j` / `k` も必要なら、そのバッファで `M-x english-reading-mode` を有効にしてください。

## 4. Kindle Web Readerを読む（旧バックエンド）

現在の `M-x my-read` はKindle.appバックエンドを使用します。この節は旧Chrome/CDPバックエンドの構築資料です。Kindle.app側のセットアップは `README-my-read-k2.md` を参照してください。

### 4.1 OCRブリッジをビルドする

Swift製の常駐ブリッジをリリース構成でビルドします。

```sh
make my-read-k-build
```

実行ファイルがない場合は `my-read-k` が `swift run` へフォールバックしますが、あらかじめリリースビルドしておく方が起動は速くなります。

日本語縦書きKindleも読む場合は、Tesseract本体と公式の縦書き日本語モデルを一度だけ導入します。モデルはリポジトリへ入れず、`~/Library/Caches/my-read-k/tessdata/` に置かれます。

```sh
brew install tesseract
scripts/install-my-read-k-vertical-ocr.sh
```

通常はApple Visionが使われます。日本語または自動判定で、Visionの結果が12文字未満、あるいは縦書きと判定された場合だけ `jpn_vert` を試し、Visionより十分多く日本語を認識できたときだけ採用します。インストール後のOCR処理にネットワーク接続は不要です。実行ファイルとモデルの場所は、必要なら `MY_READ_K_TESSERACT` と `MY_READ_K_TESSDATA` で変更できます。

### 4.2 デバッグポート付きChromeを起動する

通常のChromeとは別の専用プロファイルを、ループバックのCDPポート `9000` で起動します。

```sh
scripts/launch-kindle-chrome.sh
```

初回はこのChromeでAmazonへログインし、Kindle Web Readerで対象書籍を開きます。横書き・縦書きの英語／日本語本文を自動判定します。OCR領域を安定させるため、1ページ表示が推奨です。

別ポートを使う場合は、ChromeとEmacsの値を揃えます。

```sh
MY_READ_K_CDP_PORT=9010 scripts/launch-kindle-chrome.sh
```

```elisp
(setq my-read-k-cdp-port 9010)
```

CDPはブラウザを強力に操作できるため、`my-read-k-cdp-host` とChromeのデバッグアドレスは `127.0.0.1` のまま使用してください。

### 4.3 Emacsから接続する

旧バックエンドの実装と診断コマンドは `my-read-k.el` に残していますが、標準の `M-x my-read` からは起動されません。

### Kindle本文領域のキー

| キー | 動作 |
| --- | --- |
| `j` | 1文読み上げ。ページ末尾では次ページを取得して続ける |
| `k` | 前の1文を読み上げ。ページ先頭では前ページを取得して続ける |
| `↓` / `C-n` | 1表示行下へ。バッファ末尾では次ページへ |
| `↑` / `C-p` | 1表示行上へ。バッファ先頭では前ページへ |
| `C-v` / `C-c ]` | 次のKindleページを直接取得 |
| `M-v` / `C-c [` | 前のKindleページを直接取得 |
| `C-c g` | 現在ページを再OCR |
| `r` | Swiftブリッジを再起動してChrome・Kindleへ再接続 |
| `l` / `;` | Lookupの次／前の項目 |

既定では次の2ページを先読みし、通過した前の2ページも保持します。いずれもメモリ内キャッシュで、再OCR、接続先変更、切断時に破棄されます。

### Kindle OCRの主な設定項目

| 変数 | 既定値 | 用途 |
| --- | --- | --- |
| `my-read-k-cdp-host` | `127.0.0.1` | Chrome CDPホスト |
| `my-read-k-cdp-port` | `9000` | Chrome CDPポート |
| `my-read-k-url-pattern` | `read.amazon.co.jp/?asin=` | 対象タブのURL判定 |
| `my-read-k-crop` | `(0.08 0.06 0.84 0.88)` | 画面左上原点の正規化OCR範囲 |
| `my-read-k-language` | `auto` | Vision対応言語を自動判定。固定する場合は `en-US` / `ja-JP` / `fr-FR` など |
| `my-read-k-japanese-kokoro-voice` | `jf_nezumi` | 日本語ページのKokoro音声 |
| `my-read-k-kokoro-language-profiles` | 7言語（英語は通常設定を継承） | Kokoroの言語コードと音声の対応 |
| `my-read-k-macos-voice-alist` | 言語別音声 | Kokoro非対応言語のmacOS音声 |
| `my-read-k-prefetch-count` | `2` | 先読みページ数（現在の最大値も2） |
| `my-read-k-history-count` | `2` | 戻り用の保持ページ数 |
| `my-read-k-settle-timeout-ms` | `4000` | ページ切り替え安定待ちの上限 |

Kindleのヘッダー、操作ボタン、余白までOCRされる場合は `my-read-k-crop` を調整してください。

## Google翻訳と翻訳記録

中央本文でカーソルを動かすと、カーソルを含む1文だけをGoogle翻訳へ送信します。日本語Kindleでは日本語から英語へ、それ以外の言語では判定言語から通常の翻訳先（既定は日本語）へ自動的に切り替えます。日本語側の翻訳先は `my/read-japanese-translation-target-language` で変更できます。読み上げ中は、カーソルが先へ進んでも読み上げ中の1文を翻訳対象として固定します。読み上げが終了または停止すると、再びカーソル位置の1文へ追従します。

翻訳対象は本文領域へ薄いブルーで重ねて表示されます。Emacsのfaceでは透過色が安定しないため、`LightSkyBlue` と現在のテーマ背景色を混ぜて半透明相当の色を作っています。濃さは0から1で変更できます。

```elisp
(setq my/read-translate-overlay-opacity 0.35)
```

成功した翻訳は、既定では次の形で追記されます。

```text
/Users/seijiro/Library/Mobile Documents/iCloud~md~obsidian/Documents/seijiro/001_read/
└── 書籍名/
    └── google-translate.md
```

通常書籍ではファイル名またはディレクトリ名、Kindleではタブの書籍名を使用します。Kindleの一般的なタイトルしか取れない場合は `Kindle-<ASIN>` を使用します。記録には日時、原文、訳文、`Sentence` または `Kokoro` のモードが入り、同じ原文・訳文の組み合わせはEmacs再起動後も重複記録しません。

翻訳記録を止める場合は次のように設定します。

```elisp
(setq my/read-translation-log-enabled nil)
```

注意: Kokoro読み上げはローカル処理ですが、Google翻訳の対象となる1文はGoogleのサービスへ送信されます。

## 状態確認とトラブルシューティング

### Kokoroから音が出ない

```sh
curl --fail http://127.0.0.1:8000/health
```

自動起動に失敗した場合は `*kokoro-server*` バッファを確認します。`kokoro-reader-server-directory` がこのリポジトリを指していること、`uv sync` が完了していることも確認してください。新しい読み上げを始めると、前の合成・再生は自動停止します。

### Lookupが出ない、辞書を確認したい

```text
M-x my/read-lookup-status
M-x my/read-lookup-list-dictionaries
```

設定した辞書IDが実際のLookup辞書IDまたはその前方一致になっているか確認してください。

### 翻訳が読み上げ文へ固定されているか確認したい

```text
M-x my/read-translation-lock-status
```

### Kindleへ接続できない、OCRできない

```text
M-x my-read-k-status
M-x my-read-k-show-last-error
```

次を順に確認してください。

- デバッグポート付きChromeが起動している
- Chrome側と `my-read-k-cdp-port` が一致している
- 対象書籍のURLが `my-read-k-url-pattern` に一致している
- Kindle本文が画面に表示されている
- `my-read-k-crop` が本文を含む有効な範囲になっている
- 縦書き日本語の場合は `tesseract --version` が成功し、`~/Library/Caches/my-read-k/tessdata/jpn_vert.traineddata` がある

Chromeを後から起動した場合や接続が切れた場合は、中央の `Kindle` タブへ移動して `r` を押します。Swiftブリッジを再起動して、設定済みCDPポートとKindleタブを再探索します。フレームを閉じるか `M-x my-read-k-detach` を実行すると、Swiftブリッジとメモリ内キャッシュを終了します。

## テスト

SwiftブリッジとEmacs ERTテストをまとめて実行します。

```sh
make my-read-k-check
```

個別には `make my-read-k-test` と `make my-read-k-ert` を使用できます。`my-read-k-ert` は現在 `/Applications/Emacs-takaxp/Emacs.app` を使用します。別のEmacsを使う場合は `Makefile` の実行パスを環境に合わせて変更してください。

## ファイル構成

| ファイル | 役割 |
| --- | --- |
| `kokoro_server.py` | ローカルKokoro HTTPサーバー |
| `kokoro-reader.el` | 非同期音声生成・`afplay` 再生・読み上げハイライト |
| `english-reading-mode.el` | 1文単位の `j` / `k` と読み上げ状態通知 |
| `my-read.el` | 専用フレーム、Lookup、Google翻訳、翻訳記録 |
| `my-read-k.el` | Kindle OCRバッファ、ページ移動、キャッシュ管理 |
| `my-read-k/bridge/` | Chrome CDP、スクリーンショット、Apple Vision／Tesseract OCRのSwiftブリッジ |
| `scripts/launch-kindle-chrome.sh` | 専用Chromeプロファイルの起動 |
| `scripts/install-my-read-k-vertical-ocr.sh` | 公式の縦書き日本語OCRモデルをキャッシュへ導入 |
| `test/my-read-k-tests.el` | Emacs ERTテスト |

Kokoro API単体の詳細と手動リクエスト例は [`README-kokoro-emacs.md`](README-kokoro-emacs.md)、Kindleブリッジの内部動作は [`README-my-read-k.md`](README-my-read-k.md) にあります。

## ライセンス

[MIT License](LICENSE)

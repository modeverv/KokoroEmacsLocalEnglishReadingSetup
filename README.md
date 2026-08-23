# Emacs 多言語Reader

Emacsで書籍を読みながら、ローカルKokoroによる読み上げ、ローカル翻訳、Lookup辞書、読書メモを一つの専用フレームにまとめるプロジェクトです。

`my-read` は、通常のEPUB・テキスト、DocViewで読むPDF、EWWで読むarXiv、Kindle.appで表示中の英語本文を一つのフレームに統合します。Kindle本文はmacOS Accessibilityから現在表示中のページだけを取得します。スクリーンショット取得、OCR、Kindleファイルの復号は行いません。

専用フレームは次の4領域で構成されます。

- 左: カーソル位置の単語を自動検索するLookup
- 中央: タブで切り替えるKindle本文、EPUB・テキスト・PDF、EWW
- 右上: カーソル位置、または読み上げ中の1文のローカル翻訳
- 右下: 読書メモ

## 主な機能

- `j` / `k` で1文ずつKokoro読み上げ
- 読み上げ中の文を本文上でハイライト
- 読み上げ中は翻訳対象を読み上げ中の1文へ固定
- `l` / `;` でLookupの次・前の項目へ移動
- Kindleでは前後2ページをメモリ上だけにキャッシュ
- Kindle本文をファイルへ保存しない
- Google翻訳を既定とし、必要に応じてローカル翻訳へ切り替え可能
- `u` で単語や選択フレーズを例文・意味・日本語訳とともにOrgへ蓄積
- 通常の自動翻訳は記録・保存しない

## 必要環境

- Apple Silicon Mac
- macOS 13以降
- Emacs 29以降
- Python 3.11以上3.14未満
- [`uv`](https://docs.astral.sh/uv/)
- Swift 6以降
- macOSの `/usr/bin/curl` と `/usr/bin/afplay`
- ローカル翻訳を使う場合はOllamaと `translategemma:4b`
- Emacsパッケージ `google-translate` と `lookup`
- EPUBを読む場合は `nov.el`
- PDFを読む場合はPopplerの `pdftotext`
- EWWでarXiv数式を画像表示する場合はTeX Liveの `latex` と `dvisvgm`

Kindle.appの本文取得にはmacOSのアクセシビリティ権限が必要です。Lookup本体、辞書エージェント、EPWING辞書などは別途設定してください。

## 1. Python環境とKokoroの導入

```sh
cd ~/Sync/emacs.d/reader
uv sync
```

Kokoroサーバーは最初の読み上げ時にEmacsから自動起動されます。手動起動とヘルスチェックは次の通りです。

```sh
make run
curl --fail http://127.0.0.1:8000/health
```

既定では `127.0.0.1:8000` のみに接続し、モデル `mlx-community/Kokoro-82M-bf16`、音声 `bf_emma`、イギリス英語を使います。

## 2. Emacs側の設定

```elisp
(add-to-list 'load-path
             (expand-file-name "~/Sync/emacs.d/reader"))

(require 'my-read)

(setq my/read-book-path "/path/to/books"
      my/read-note-file "~/Documents/english-reading.org"
      my/read-vocabulary-file "~/my-read/vocabulary.org"
      my/read-eww-url "https://arxiv.org/"
      my/read-eww-line-spacing 0.5
      my/read-eww-math-enabled t
      my/read-eww-math-image-scale-multiplier 1.5
      my/read-eww-math-inline-scale-multiplier 1.25
      my/read-eww-math-image-vertical-margin 0
      my/read-eww-math-svg-stroke-width 0.18
      my/read-eww-math-svg-padding 1.0
      my/read-eww-enable-automatic-lookup nil)

(setq kokoro-reader-server-directory
      (expand-file-name "~/Sync/emacs.d/reader")
      kokoro-reader-voice "bf_emma"
      kokoro-reader-lang-code "b"
      kokoro-reader-speed 1.0
      kokoro-reader-volume 1.0)

(setq google-translate-default-source-language "en"
      google-translate-default-target-language "ja"
      my/read-translation-backend 'google
      my/read-local-translation-model "translategemma:4b"
      my/read-google-translation-fallback t
      my/read-translate-overlay-opacity 0.35)

(setq my/read-lookup-dictionary-ids
      '("nmacos"
        "ndeb+~/Sync/004_dic/ee/:simpleen"
        "ndeb+~/Sync/004_dic/chujisnd/"
        "ndspell"))

(add-hook 'nov-mode-hook #'english-reading-mode)
```

`my/read-lookup-dictionary-ids` は通常のLookup設定を変更しません。空リストにすると専用フレーム内のLookupを無効にします。

## 3. Kindle.appの準備

1. Kindle.appで英語の本を開きます。
2. 「システム設定 → プライバシーとセキュリティ → アクセシビリティ」でEmacsを許可します。
3. Emacsで `M-x my-read` を実行します。

最初の実行時に、必要であれば `my-read-k2/bridge` のSwiftブリッジをリリース構成でビルドします。先にビルドする場合は次を実行します。

```sh
make my-read-k-build
```

ブリッジは現在表示中のページを読み、先読み時だけ最大2ページ先まで一時的に移動した後、元のページへ戻します。全冊クロールや本文のファイル保存は行いません。

Kindleの正式な書名は、Kindle自身のローカル `BookData.sqlite` から接続時に
読み取り専用で自動取得します。OCRやネットワーク送信は行いません。この書名は
単語帳の `BOOK` プロパティと用例見出しに使われます。自動判定を上書きしたい場合
だけ、次のように指定してください。

```elisp
(setq my-read-k2-book-name "任意の書名")
```

## 4. 統合読書フレーム

```text
M-x my-read
```

中央は同じ1ペインの `Kindle` / `EPUB` / `EWW` タブで切り替えます。EWWタブでは `g` で初期URL（既定はarXiv）、`G` で任意のURLを開けます。EWW全体の行間は `my/read-eww-line-spacing` の既定値 `0.5` により通常のおよそ1.5倍です。追加分は行の下側へ置かれます。arXiv HTMLのTeX注釈はバックグラウンドでSVGへ変換され、変換中もEmacsの操作を妨げません。SVGは式・表示形式・文字色・輪郭幅・内部余白ごとにキャッシュされます。表示倍率は既定フォントへ合わせた値のさらに1.5倍が既定で、インライン数式だけはそこから1.25倍します。それぞれ `my/read-eww-math-image-scale-multiplier` と `my/read-eww-math-inline-scale-multiplier` から調整できます。数式の太さは `my/read-eww-math-svg-stroke-width`、SVG端の余白は `my/read-eww-math-svg-padding` で調整できます。既定では四辺に1ptを加え、字形や輪郭線が `viewBox` で切れないようにします。`j` / `k` の文単位読み上げと `l` / `;` のLookup項目移動もEPUB・Kindleと同様に使えます。EWWのページ読み込み中に表示される `Loading` などを同期型辞書へ送るとEmacs全体を止めることがあるため、EWWタブでは自動Lookupだけを既定で停止します。自動翻訳と通常のEWW表示は有効です。必要なら `my/read-eww-enable-automatic-lookup` を `t` にしてください。接続し直す場合はKindleタブで `r` を押します。

中央でPDFを開くと `doc-view-mode` と `english-reading-mode` が連携し、PDF画像を表示したまま `pdftotext` の抽出本文を裏側で文単位に移動します。`j` / `k` はページ境界でDocViewの表示ページも自動的に進めたり戻したりし、翻訳とLookupも同じ抽出本文を参照します。読み上げ中は `pdftotext -bbox-layout` の単語座標を使って該当箇所をPDF画像上へ半透明表示し、読み上げ終了時に通常画像へ戻します。色と透明度は `english-reading-mode-pdf-highlight-color` と `english-reading-mode-pdf-highlight-opacity` で変更できます。ページ番号など英字を実質的に含まない断片は読み飛ばします。テキストレイヤーを持たないスキャンPDFはOCR対象外です。

| キー | 動作 |
| --- | --- |
| `j` | 現在の1文を読み上げ、次の文へ進む |
| `k` | 前の1文へ戻って読み上げる |
| `p` | 現在の段落を読み上げる |
| `↓` / `C-n` | 1表示行下へ。末尾では次のKindleページへ |
| `↑` / `C-p` | 1表示行上へ。先頭では前のKindleページへ |
| `C-v` / `C-c ]` | 次のKindleページ |
| `M-v` / `C-c [` | 前のKindleページ |
| `C-c g` | 現在ページを再取得 |
| `C-c C-k` | 合成または再生を停止 |
| `l` / `;` | Lookupの次／前の項目 |
| `u` | 単語、または選択中のフレーズを語彙Orgファイルへ保存 |
| `C-c t` | Kindle／EPUB／EWWタブを順に切り替える |
| `r` | Kindle.appへ再接続 |

## 単語・フレーズの保存

中央のKindle／EPUB／PDF／EWW読書ペインで `u` を押すと、覚えておきたい
単語やフレーズを `my/read-vocabulary-file` のOrgファイルへ保存します。このキーは
`my-read` の読書ペイン内だけで有効で、通常のEmacsバッファの `u` には影響しません。
同じ操作は `M-x my/read-vocab-capture` でも実行できます。

- リージョンが有効な場合: 選択範囲全体をフレーズとして保存
- リージョンがない場合: カーソル位置の単語を保存
- 選択範囲内の改行や連続空白は1個の空白へ正規化
- 大文字小文字と周辺の句読点を無視して既存項目を検索
- 同じ単語・フレーズを再登録すると、見出しを増やさず新しい用例を追加

既定の保存先は次のファイルです。ファイルと親ディレクトリは初回保存時に
自動作成されます。

```elisp
(setq my/read-vocabulary-file "~/my-read/vocabulary.org")
```

各項目には、次の情報を保存します。

- 単語またはフレーズ
- 既存のmy-read Lookupで得られた英英辞書の定義
- 既存のmy-read Lookupで得られた英和辞書の定義
- 単語または選択フレーズ自体のGoogle翻訳
- 遭遇日時
- Kindleの書名、EPUB／PDFのファイル名、またはEWWのページタイトル
- 単語・フレーズを含む英語の1文
- 既存のmy-read翻訳バックエンドによる日本語訳
- 安価に取得できる場合は、ファイルパスやURLなどの参照元

Orgファイルでは、正規化後の単語・フレーズごとにトップレベル見出しを1個だけ
作ります。再登録時は `COUNT` と `UPDATED` を更新し、`Examples` の下へ用例を
追加します。

```org
* anxiety
:PROPERTIES:
:TYPE: word
:CREATED: [2026-08-23 Sun 07:20]
:UPDATED: [2026-08-23 Sun 07:26]
:COUNT: 2
:END:

** Meaning
English-English [English]:
anxiety | a feeling of worry, nervousness, or unease.

English-Japanese [Japanese - English]:
名詞 不安、心配。

Google Translate:
不安

** Examples

*** [2026-08-23 Sun 07:20] Some Light Novel Vol. 1
:PROPERTIES:
:BOOK: Some Light Novel Vol. 1
:END:

English:
She felt a strange anxiety about what would happen next.

Japanese:
彼女は次に何が起こるのか、妙な不安を感じていた。
```

Lookupや翻訳が利用できない場合も登録自体は中止せず、取得できた情報だけを
保存します。カーソル位置に単語がなく、リージョンもない場合は何も書き込まず
`No word or phrase at point` と表示します。既存項目の `COUNT` や `Examples` が
壊れていて安全に更新できない場合も、元のファイルを変更せずエラーを報告します。

英英・英和辞書はLookupの辞書タイトルから判定します。辞書タイトルが既定の
`English`、`Japanese - English`、`英語辞典`、英和・和英を含むタイトルと異なる
場合は、次の正規表現を環境に合わせて変更できます。

```elisp
(setq my/read-vocab-english-dictionary-title-regexp
      "\\`English\\'\\|英英\\|英語辞典"
      my/read-vocab-japanese-dictionary-title-regexp
      "Japanese[[:space:]]*-[[:space:]]*English\\|英和\\|和英")
```

例文の日本語訳は `my/read-translation-backend` の設定に従いますが、Meaning内の
単語・フレーズ訳は常にGoogle翻訳を使います。既存項目を再登録した場合は、用例の
追加と同時にMeaningの3ブロックも最新結果へ置き換えます。

## Google翻訳とローカル翻訳

既定ではGoogle翻訳を使います。ローカルのOllamaでTranslateGemma 4Bを
使いたい場合は、最初に次を実行してください。

```sh
brew install --cask ollama
ollama pull translategemma:4b
```

そのうえで、次の設定に変更します。

```elisp
(setq my/read-translation-backend 'local)
```

ローカル翻訳では、カーソルを含む1文だけを
`http://127.0.0.1:11434/api/chat` へ送ります。読み上げ中は対象を
読み上げ中の1文へ固定し、終了するとカーソル位置へ戻ります。

Ollamaが未起動、タイムアウト、または不正な応答を返した場合だけGoogle翻訳へ
自動的にフォールバックします。Googleへ送信したくない場合は
`my/read-google-translation-fallback` を `nil` にしてください。既定のGoogle翻訳へ
戻す場合は `my/read-translation-backend` を `google` に設定します。

通常の自動翻訳は画面に表示するだけで、原文・訳文ともファイルには記録しません。
ただし、読書ペインで `u` を押して明示的に語彙登録した場合は、その用例の
英語原文と日本語訳を `my/read-vocabulary-file` へ保存します。

## 状態確認

```text
M-x my-read-k-status
M-x my-read-k-show-last-error
M-x my/read-lookup-status
M-x my/read-lookup-list-dictionaries
M-x my/read-translation-lock-status
```

Kindle.appへ接続できない場合は、Kindle.appで英語本文が表示されていることと、Emacsへアクセシビリティ権限が付与されていることを確認してください。

## テスト

```sh
make my-read-k-check
```

`make my-read-k-test` はKindle.app AccessibilityブリッジのSwiftテスト、`make my-read-k-ert` はEmacs ERTテストを実行します。

## ファイル構成

| ファイル | 役割 |
| --- | --- |
| `kokoro_server.py` | ローカルKokoro HTTPサーバー |
| `kokoro-reader.el` | 非同期音声生成・再生・ハイライト |
| `english-reading-mode.el` | 1文単位の移動と読み上げ状態通知 |
| `my-read.el` | 専用フレーム、Lookup、翻訳、語彙Orgファイルへの保存 |
| `my-read-k.el` | Kindle本文バッファ、ページ移動、メモリキャッシュ |
| `my-read-k2.el` | Kindle.app Accessibilityバックエンド |
| `my-read-k2/bridge/` | macOS Accessibilityを読むSwiftブリッジ |
| `test/my-read-k-tests.el` | 共有Reader UIのERTテスト |
| `test/my-read-k2-tests.el` | Kindle.appバックエンドのERTテスト |

詳細は [README-my-read-k2.md](README-my-read-k2.md) と [README-kokoro-emacs.md](README-kokoro-emacs.md) を参照してください。

## ライセンス

[MIT License](LICENSE)

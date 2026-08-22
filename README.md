# Emacs 多言語Reader

Emacsで書籍を読みながら、ローカルKokoroによる読み上げ、ローカル翻訳、Lookup辞書、読書メモを一つの専用フレームにまとめるプロジェクトです。

`my-read` は、通常のEPUB・テキストと、Kindle.appで表示中の英語本文を一つのフレームに統合します。Kindle本文はmacOS Accessibilityから現在表示中のページだけを取得します。スクリーンショット取得、OCR、Kindleファイルの復号は行いません。

専用フレームは次の4領域で構成されます。

- 左: カーソル位置の単語を自動検索するLookup
- 中央: タブで切り替えるKindle本文とEPUB・テキスト
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
- 翻訳結果を記録・保存しない

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
      my/read-note-file "~/Documents/english-reading.org")

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

## 4. 統合読書フレーム

```text
M-x my-read
```

中央は同じ1ペインの `Kindle` / `EPUB` タブで切り替えます。接続し直す場合はKindleタブで `r` を押します。

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
| `C-c t` | Kindle／EPUBタブを切り替える |
| `r` | Kindle.appへ再接続 |

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

翻訳は画面に表示するだけで、原文・訳文ともファイルには記録しません。

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
| `my-read.el` | 専用フレーム、Lookup、ローカル翻訳とGoogleフォールバック |
| `my-read-k.el` | Kindle本文バッファ、ページ移動、メモリキャッシュ |
| `my-read-k2.el` | Kindle.app Accessibilityバックエンド |
| `my-read-k2/bridge/` | macOS Accessibilityを読むSwiftブリッジ |
| `test/my-read-k-tests.el` | 共有Reader UIのERTテスト |
| `test/my-read-k2-tests.el` | Kindle.appバックエンドのERTテスト |

詳細は [README-my-read-k2.md](README-my-read-k2.md) と [README-kokoro-emacs.md](README-kokoro-emacs.md) を参照してください。

## ライセンス

[MIT License](LICENSE)

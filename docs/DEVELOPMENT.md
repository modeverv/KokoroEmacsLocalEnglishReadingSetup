# Reader development

全体の責務とcallback所有関係は [docs/architecture.md](architecture.md)、
設定・状態変数は [docs/state-inventory.md](state-inventory.md) を参照してください。

## ディレクトリとロード

実装は [my-read/](../my-read/README.md) の概念別ディレクトリに置きます。
新しい概念のディレクトリを追加したら `my-read/reader-load-path.el` の一覧へ登録してください。
既存ディレクトリにファイルを追加するとcompile検証には自動で含まれます。
ルートの `my-read.el` に業務ロジックを追加しないでください。

compile出力は元のディレクトリ構造を保ちます。切り離したbytecodeのテストでも
runtime資産はcheckout側のbootstrapで解決し、compiled側のmoduleを優先します。

## Document backendを追加する

1. `reader-document` をrequireし、backend名・current-buffer predicate・操作plistを登録します。
2. 表示テキストをそのまま読む媒体は `text` を親にして、相違する操作だけ実装します。
3. ページ/章境界は `:continue`、位置は `:location` / `:restore`、抽出bufferを持つ場合は
   `:owns-speech` / `:resume` / `:speech-range` を実装します。
4. Readerの固定タブに追加する場合は `my-read/ui/my-read-ui.el` のtab登録・表示名・frame parameterを
   追加します。文取得や媒体位置の分岐をUIやSpeechへ書き戻さないでください。
5. fake bufferでdispatch、終端、前後移動、位置復元、文書切替を検証します。

```elisp
(require 'reader-document-text)
(reader-document-register
 'example
 (lambda () (derived-mode-p 'example-mode))
 '(:source example-document-source
   :title example-document-title
   :persistent-type (lambda () 'text))
 'text)
```

`:source` / `:title` はoptional frame引数を受け取ります。保存可能なsourceには安定した
file pathを返してください。remote documentの位置を新たに永続化する場合は、現行の
file-based keyとの互換性を別途設計します。未対応操作は `reader-document-has-p` で検出し、
別backendへ暗黙にフォールバックしません。

## Speech backendを追加する

Readerの操作は `:speak` → `kokoro-reader--speak-bounds` に合流します。新しい合成backendは
`reader-speech-queue-transport` の `:prepare` / `:key` 操作を登録します。
`:prepare` は `:start` callbackとpayload・接続先を持つ要求を返します。
callbackは `reader-speech-queue-attach-process` / `reader-speech-queue-request-finished` で
生成processの開始・完了を通知します。queueの追加・削除は直接行いません。
再生接続は `reader-speech-queue-connect-functions`、追加の接続eventは
`reader-speech-queue-event-functions` へ登録します。言語別設定は `my-read/speech/backend-selection/my-read-speech-settings.el`、HTTP経由の
合成は `companion-implementations/speech_http/server.py` に実装します。新しい合成方式をReaderの文送りに混ぜません。

守る契約:

- cache keyに正規化後text・backend・voice・rate/speed・volume・接続先を反映する。
- 発話とprefetchで同じsentence/chunkを生成する。PDFのページ境界を跨がない。
  Kindleの次ページを一時バッファで分割する場合も、元バッファの音声backend・
  文数設定・syntax tableを引き継ぐ。macOS固定の複数文チャンクを作ると、
  Kokoro/HTTP経由の1文再生とキーが一致せず、ページ境界で停止・再生成が起きる。
- reserve/chunk/loadedは再生完了ではない。実deviceのfinishedだけが正常な文送りを許可する。
- stop後のqueue entryと古いsession/processからの結果を破棄する。
- remote playbackのsession、delivery capability、chunk順序・重複拒否を維持する。

HTTPの認証/timeout/不正応答は既存のerror bufferと停止経路へ伝えます。失敗sentinelから
停止済みserverを自動再起動したり、成功扱いで次の文へ進んだりしないでください。

## Translation backendを追加する

`my-read/translation/my-read-translation.el` のrequest生成とresponse解析へ追加します。Googleの既定値と
明示指定したlocal backendからのfallback契約を維持します。request sentinelはprocessと
文書のidentityを確認し、停止時はprocess変数を先に無効化します。

## コマンド・状態の置き場所

- interactive commandと設定の名前を安易に変更しません。内部関数は `--` を使用します。
- キーは各minor-modeのmapに置き、Readerのpane predicateを維持します。
- 文書ごとの位置・言語・cacheはbuffer-local、windowとtabの所有関係はframe parameterです。
- 出力装置を共有する単一音声sessionは `my-read/core/english-reading-state.el`、接続queueは
  `my-read/speech/synthesis/reader-speech-queue.el`、Kindleの接続とページcacheは `my-read/document/kindle/my-read-k.el` が所有します。
- 遅延読み上げ処理は `english-reading-mode--session-timer` を使用し、既存generationを
  無視した `run-at-time` を追加しません。
- import cycleの代わりにhook・document operation・`declare-function` を使います。
  moduleをロードした順序だけで外部変数がdynamic bindingになることを期待しません。

## 検証

```sh
make reader-check            # check-parens + 全Elispの警告をエラー扱いでcompile
make reader-ert              # Reader全体（make my-read-k-ertも同じ）
make reader-ert READER_SUITE=speech  # 音声だけ。分類一覧はtest/README.md
make speech-http-test       # HTTP Python + ERT
make speech-playback-test   # playback Python + ERT
make speech-native-test    # macOS実機device：無音PCMで再生順序・音声長を確認
make reader-python-test     # test/ と scripts/ の全Python unittest
make my-read-k-test         # Swiftのpure logicテスト
make reader-test            # 上記をまとめて実行
```

`EMACS=/path/to/emacs` で実行ファイルを変更できます。`reader-check` はインストール済み
ELPA依存を読みます。通常は一時ディレクトリにbytecodeを生成し、作業中の実行環境を
上書きしません。ソースERTはcheckout内の `.elc` / native cacheを使わず、外部packageの
通常のロード方式を維持します。

bytecode経路も検証する場合:

```sh
READER_COMPILE_DIR=/tmp/reader-compiled make reader-check
READER_TEST_COMPILED=1 make my-read-k-ert speech-http-test speech-playback-test \
  READER_ELISP_DIR=/tmp/reader-compiled
```

Swiftの標準ビルドが `Unknown error parsing property list` で停止する環境では、検証済みの
回避経路を利用できます。`native` 指定自体には現行Swiftから非推奨警告が出ます。

```sh
make my-read-k-test \
  SWIFT_TEST_FLAGS='--build-system native --scratch-path /tmp/reader-swift-test'
```

実機Accessibility、音声deviceの可聴性、LAN越しの認証と遅延はunit testとは別に確認します。
検証結果は実行した経路ごとに報告し、実機未確認を成功へ置き換えません。

## 大規模更新の反映

今回のようにrequire構成とhook所有moduleが変わった更新では、`M-x my-read-end` で終了し、
Emacsを再起動して `M-x my-read` を実行してください。読み込み済みfeatureがある状態で
`my-read.el` だけを再評価しても、依存moduleの再読み込みにはなりません。

bytecodeは上記の一時出力先で検証します。ルートを入口だけに保つため、
`READER_COMPILE_DIR="$PWD"` でルートへbytecodeを生成しないでください。
古いルートの各moduleを直接loadする設定は、先に `(require 'my-read)` を行う形へ更新します。
音声サーバーやGUIも移動前から動いている場合は停止し、新しいMakefileから再起動します。

履歴用ソースはGitにあります。`old/`へ動作する実装を複製したり、`.elc`をcommitしたり
しないでください。

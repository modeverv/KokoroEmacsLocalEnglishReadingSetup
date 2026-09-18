# Refactor validation — 2026-09-18

ブランチ: `codex/reader-architecture-refactor`。変更前の基準は `master` の
`4905928cbdfbf2b409a06510beb679e82c54cfab` です。

## 構造と互換性

| ファイル | Before | After |
| --- | ---: | ---: |
| `my-read.el` | 3,222行 | 74行 |
| `english-reading-mode.el` | 2,480行 | 199行 |

単なるファイル移動に加え、文の取得・移動・連続送り・chunk再開・位置復元・metadataを
document operationへ移行しました。Speech本体からPDF/EPUBの媒体分岐を除き、PDFの
highlight/recenterはhookへ分離しています。位置とEWW履歴はatomic I/Oを共有します。

元の2ファイルの関数・設定・状態変数・keymap・minor-modeの定義名は、それぞれ
225/225、158/158を保持しました。主要キー、言語別速度、Google既定、org-noter、Lookup、
Vocabulary、HTTP transport、remote playbackの既存テストは削除していません。

起動時の絶対パスloadも、entry自身のディレクトリをload-pathへ加えて維持します。
旧 `old/` の複製実装とテスト `.elc` を除去し、設定・保存データの移動はしていません。
構成は [architecture.md](architecture.md)、変更方法は [DEVELOPMENT.md](DEVELOPMENT.md) を
参照してください。

## Before / After

成功・失敗・skipは実行されたテストの件数です。Swift基準ではテストが開始されず、
成功扱いにしていません。

| 検証 | Before: passed / failed / skipped | After: passed / failed / skipped |
| --- | --- | --- |
| Reader ERT | 211 / 2 / 0 | 231 / 0 / 0 |
| HTTP speech ERT | 5 / 0 / 0 | 5 / 0 / 0 |
| HTTP settings ERT | 1 / 0 / 0 | 1 / 0 / 0 |
| remote playback ERT | 7 / 0 / 0 | 7 / 0 / 0 |
| HTTP/playback Python | 29 / 0 / 0 | 29 / 0 / 0 |
| その他Python（Irodori・配布物検証） | 基準時は未実行 | 7 / 0 / 0 |
| Swift | ビルド初期化失敗・未実行 | 5 / 0 / 0 |

最終のERTは合計244件。ソース経路と新規生成bytecode経路の両方で同じ244件が成功しました。
Pythonは `test/` の33件、`scripts/` の3件で計36件です。
新しいReader境界テスト18件ではdispatch/継承/再登録、文終端、text/PDF/EPUB位置、
文書切替、kill、古いtimer/process、翻訳終了競合、atomic rename失敗を検証しました。

## 基準時の失敗と修正

- 読書位置の既定値はcommit `aaf4a9d` で `read` から `read-log` へ変更されていました。
  実装と既存保存先を維持し、古い期待値のテストを更新しました。noterの `read` は維持します。
- Kindle bridge設定テストではローカルの `.elc` / native cacheがロードされていました。
  checkoutのソースを明示的にロードするテスト起動処理を追加すると元のテストが成功しました。
  実行可能ファイルの選択仕様やテストのassertionは変更していません。
- Swiftの標準ビルドは `Unknown error parsing property list` で初期化に失敗しました。
  `--build-system native --scratch-path /tmp/reader-refactor/swift-build` で5件が成功しました。

## 実装中に修正した問題

- stop後に遅延した連続送り/warmup/prefetch callbackが新sessionへ作用しないよう、
  timerにgenerationを保持させました。
- 同じEWW bufferでURLが変わった場合も、連続読み上げと翻訳completionが旧文書を拒否します。
- translation processをdeleteする前に所有変数をnilへし、中止sentinelからのfallbackを防ぎます。
- 古い音声/Kindle bridge processのfilter出力を新接続のJSON fragmentへ混ぜません。
  callbackからfilterへ再入した場合や、同じbatchの途中でreconnectした場合も検証しました。
- bufferのkill/disableで自身の音声を解放し、無関係な文書の再生を止めないようにしました。
- frame終了で該当音声session、文書の保存timer、最後のframeのnoter同期timerを停止します。
- text文書の最終文からの連続送りが、point-maxで直前の文を再読しないようにしました。
- 外部Lookup変数のdynamic bindingを宣言し、module分離後もコンパイル時のスコープを明確にしました。

古いテストがcallbackの関数名そのものを比較していた箇所は、generationを保持するclosureを
実行し、実際に文送りが呼ばれることを検証する形へ変更しました。遅延0とprefetch間隔の
assertionは維持しています。

## 実行と品質確認

```sh
READER_COMPILE_DIR=/tmp/reader-refactor/compiled make reader-test \
  SWIFT_TEST_FLAGS='--build-system native --scratch-path /tmp/reader-refactor/swift-build'
READER_TEST_COMPILED=1 make my-read-k-ert speech-http-test speech-playback-test \
  READER_ELISP_DIR=/tmp/reader-refactor/compiled
```

29 Elisp moduleの `check-parens` とbyte compileを実行し、warningをerror扱いにして成功。
トップレベルrequireの循環もありません。`git diff --check` と新規文書の相対リンクを確認しました。
macOS speech bridgeは `clang -Wall -Wextra` で隔離先へビルドしました。
作業ディレクトリの無視対象 `.elc` も全29moduleを現在のソースから再生成しました。

## Remaining limitations

Kindle.appの実際のAccessibility読取り、GUIのPDF/EPUB描画、Lookupの実辞書、Google/localの
実ネットワーク、実音声の可聴性、LAN越しの再生は、このリファクタリングでは実機再検証していません。
既存のfake/stubとserver/device境界のテストを維持しています。

現行SDKでは未変更のnative speech bridgeにAVFoundation APIの非推奨警告が2件あります。
Swiftのnative build指定にも非推奨警告があり、初回のlinkにはTesting.frameworkのdeployment
target警告が出ました。Elispの新規warningやテストskipへ置き換えていません。

更新の反映にはReader終了後のEmacs再起動を推奨します。実行中のsessionへ大規模な
require/hookの差し替えは行っていません。

## 概念別ディレクトリへの移行（同日追補）

29個のElisp実装を `my-read/` のCore・UI・Document・Speech・Translation・Lookup・
Notes・Vocabulary・Position・Integrationsへ移動しました。
DocumentにはPDF/EPUB/EWW/TEXT/Kindle、Speechにはbackend selection/synthesis/HTTP/
prefetch/playbackの実ディレクトリがあります。
ルートには11個の公開互換入口と `reader-load-path.el` を置き、実装は複製していません。
Python/Swift/native/GUI runtimeの配置・起動コマンドは維持しました。

- 構文検査と厳格compile: 実装29 + 互換入口11 + bootstrap1 = 41ファイル、警告0。
- Reader ERT: 234/234。HTTP/settings/playback ERT: 13/13。
  ソースと、ディレクトリ構造を保つ別出力先のbytecodeの双方で成功。
- Python: `test/` 33/33、`scripts/` 3/3。
- 新規検証: 定義元のconcept path、runtime資産のroot、別working directoryの
  新しいEmacsからの絶対パスload（Reader/Kokoro/HTTP transport）。
- PDF Toolsのページ取得マクロがcompile時に展開されるケースに合わせ、既存3テストで
  `image-mode-window-get` も置換。ページ移動・選択・位置保存のassertionは維持。
- 古いルートの実装bytecodeを削除し、新構成で手元のbytecodeを再生成。
- 今回Swift/native実装は未変更。実機のGUI・音声再生・Kindle AX・LAN操作は未再確認。

反映には `M-x my-read-end` 後にEmacsを再起動してください。

## 補助実装の集約と単一入口への移行（同日追補）

ルートはREADMEの配置一覧にある項目とGit管理情報だけに整理しました。
Python・Swift・Objective-C・app・音声assets・Python環境は
`companion-implementations/` 配下です。`pyproject.toml` も同配下に置き、
`uv.lock` はルートを正本として相対symlinkで参照します。
既存のルート転送ファイルは除去し、`my-read.el` を唯一のEmacsライブラリ入口にしました。
bootstrapは `my-read/reader-load-path.el`、runtimeの基準位置は
`reader-companion-directory` です。既存の文書移動を保持し、相対リンクも更新しました。

検証結果:

- check-parens / 警告をエラー扱いにしたcompile: 31ファイル成功。
- ERT: ソース・別出力先のbytecodeともに247/247。
- Python: `test/` 33/33 + `scripts/` 7/7。
  ルートの許可項目、lockfile正本、app/serviceのパス、GUI再ビルド経路を追加検証。
- Swift: 新しいpackage pathと空のscratch directoryで5/5成功。
  この環境の既知の制約により `--build-system native` を使用。
- native speech bridgeとSpeech Server appを新しいパスで再ビルド。
  appのInfo.plistが新しいruntime rootとPythonを指すことを確認。
- 移動済みPlayback appの静的互換性検証成功（今回の再ビルド・GUI実操作は未実施）。
- `uv lock --directory companion-implementations --check --offline` 成功。
  移動後のvenvのPython・CLI実行を確認。
- Markdownのローカルリンクと `git diff --check` 成功。

native buildには既存SDK由来の非推奨警告があります。音声再生・Kindle AX・LANの実操作は
今回未確認です。Emacsと、移動前から動いている音声サーバー・GUIは再起動が必要です。
旧ルートの個別Elispを直接loadする設定は、先に `(require 'my-read)` を行う設定へ変更します。

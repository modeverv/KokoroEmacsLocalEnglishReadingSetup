# ソースの入口

機能を調べるときは、このディレクトリから対応する概念を選んでください。
ファイル名と公開feature名は従来どおりです。

```text
my-read/
├── core/                       # 起動・終了、Reading State、公開mode
├── ui/                         # frame・window・tab・paneのキー
├── document/                   # 文書操作API
│   ├── pdf/                    # 抽出・仮想cursor・表示
│   ├── epub/                   # 文境界・章送り
│   ├── eww/                    # HTML・履歴・文書adapter
│   ├── text/                   # TEXT / Markdown
│   └── kindle/                 # 本文・AX接続・ページcache
├── speech/
│   ├── backend-selection/      # 言語別backend・voice・rate
│   ├── synthesis/              # 合成要求・常駐bridgeとのqueue境界
│   ├── http/                   # HTTPコマンド・transport
│   ├── prefetch/               # 先読み・補充
│   └── playback/               # 再生session・文送り・remote再生
├── translation/                # 翻訳要求・表示・追従
├── lookup/                     # 辞書pane・追従
├── notes/                      # org-noter連携
├── vocabulary/                 # 語彙capture・Orgへのmerge
├── position/                   # 位置保存・復元・atomic file I/O
└── integrations/               # EWW数式・独立した旧TTS補助
```

起動は `core/my-read.el` → `ui/my-read-ui.el`、文書操作の共通契約は
`document/reader-document.el`、音声sessionは `speech/playback/english-reading-speech.el`
から追えます。状態の宣言は `core/english-reading-state.el` にあります。
`speech/synthesis/reader-speech-queue.el` が予約queue・要求の取消・プレイヤー通知を所有し、
`kokoro-reader.el` は発話範囲・合成payload・ネイティブ接続を担当します。
`core/reader-diagnose.el` の `M-x reader-diagnose` で接続先と待機状態を確認できます。

リポジトリのルートにある `my-read.el` が唯一のエントリーポイントです。
先に `(require 'my-read)` を実行すると、内部moduleもfeature名でrequireできます。
`my-read/reader-load-path.el` が各ディレクトリを登録します。
UIを読み込まず単独のmoduleだけ使う開発時は、このbootstrapを絶対パスでloadします。

別プロセスのruntimeは `companion-implementations/` にあります。

| 関連する概念 | runtimeのソース（リポジトリルートから） |
| --- | --- |
| Speech / synthesis | `companion-implementations/kokoro_server.py`, `companion-implementations/irodori_backend.py` |
| Speech / HTTP・playback | `companion-implementations/speech_http/` |
| Speech / native playback | `companion-implementations/macos-speech-bridge/` |
| Document / Kindle | `companion-implementations/my-read-k2/bridge/` |
| Supporting integrations / GUI | `companion-implementations/speech-http-app/`, `companion-implementations/playback-app/` |

これらの実行場所は `reader-companion-directory` に固定し、現在のbuffer、移動先のElisp、
`default-directory` に依存させません。詳細は
[architecture](../docs/architecture.md) と [development](../docs/DEVELOPMENT.md) を参照してください。

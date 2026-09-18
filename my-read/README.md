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
`kokoro-reader.el` は合成要求と常駐playerの予約queueを結ぶ境界を引き続き所有します。

リポジトリのルートにある同名 `.el` は、既存init.elの `require` と直接 `load` を
維持するための入口だけです。修正はこのディレクトリ内の実装に行ってください。
`reader-load-path.el` が明示した各ディレクトリを登録します。内部moduleだけを使う場合も
先に `(require 'reader-load-path)` を実行します。

別プロセスで動くruntimeは、既存の起動・配布パスを維持しています。

| 関連する概念 | runtimeのソース（リポジトリルートから） |
| --- | --- |
| Speech / synthesis | `kokoro_server.py`, `irodori_backend.py` |
| Speech / HTTP・playback | `speech_http/` |
| Speech / native playback | `macos-speech-bridge/` |
| Document / Kindle | `my-read-k2/bridge/` |
| Supporting integrations / GUI | `speech-http-app/`, `playback-app/` |

これらの実行場所は `reader-root-directory` に固定し、現在のbuffer、移動先のElisp、
`default-directory` に依存させません。詳細は
[architecture](../docs/architecture.md) と [development](../DEVELOPMENT.md) を参照してください。

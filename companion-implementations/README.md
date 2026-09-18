# Companion implementations

Emacs Lispから呼び出すPython・Swift・Objective-C実装、アプリ、音声assetsをまとめています。

| パス | 役割 |
| --- | --- |
| `kokoro_server.py`, `irodori_backend.py` | ローカル音声合成 |
| `speech_http/` | HTTP生成・転送・再生・launchd管理 |
| `macos-speech-bridge/` | 常駐native音声合成・再生 |
| `my-read-k2/bridge/` | Kindle Accessibilityを読むSwift package |
| `speech-http-app/` | 生成サーバーを操作するmacOS app |
| `playback-app/` | 再生専用のmacOS app |
| `assets/` | ローカル参照音声（asuka.wavはGit対象外） |
| `pyproject.toml`, `requirements-playback.txt` | Python依存関係 |
| `uv.lock` | ルートのlockfileへの相対リンク（正本は一つ） |

リポジトリルートから:

```sh
uv sync --directory companion-implementations --locked --inexact --extra japanese
make run
make speech-server
make speech-gui
make speech-playback-setup
make speech-playback
make my-read-k-build
make my-read-speech-build
```

直接 `python -m speech_http...` を実行する場合は、このディレクトリを作業場所にします。
`.venv/` と各 `build/`・`.build/` もこの配下に作成します。MakefileのPython実行は
この配下の環境を使い、Python module検索先も設定します。

移動前から起動している生成サーバーとGUIは一度終了し、上のコマンドで再起動してください。
Emacsの入口はルートの `my-read.el`、各moduleの検索設定は `my-read/reader-load-path.el` です。
詳細は [開発手順](../docs/DEVELOPMENT.md)、[HTTP音声](../docs/http-speech.md)、
[remote playback](../docs/remote-playback.md) を参照してください。

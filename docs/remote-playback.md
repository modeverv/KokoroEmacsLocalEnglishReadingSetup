# 生成サーバーと再生サーバーを分ける

Emacsが本文を送り、生成サーバーがWAVを手元の再生サーバーへ直接転送します。
Emacsには音声データを戻さず、再生開始・終了・エラーだけをWebSocketで通知します。
読み上げ言語・音声・速度、先読み、文送りは既存のmy-read設定を使います。

| 役割 | 必要なもの |
| --- | --- |
| 読書・操作 | my-readを導入したEmacs、Python、aiohttp |
| 音声生成 | 既存のHTTP音声サーバー（macOS / Apple Silicon） |
| 音声再生 | Python、aiohttp、sounddevice / PortAudio、スピーカー |

再生サーバーにはEmacs、Kindle、MLX、音声モデル、ffmpegは不要です。
macOS・Windows・Linuxで利用できるライブラリを使用しています。
実機で確認したOSはmacOSです。Windows/Linuxの実オーディオ出力は未検証です。
Kindleの本文取得には、Emacs側のMacにKindle.appとAccessibilityで読めるGUIセッションが必要です。

## 手元の再生サーバーを導入

このリポジトリ、または `speech_http/` と `requirements-playback.txt` を手元に置きます。
Python 3.11〜3.13を使用してください。モデル用の `uv sync` は不要です。

macOS / Linux:

```sh
python3 -m venv .playback-venv
.playback-venv/bin/python -m pip install -r requirements-playback.txt
.playback-venv/bin/python -m speech_http.playback
```

Windows PowerShell:

```powershell
py -3 -m venv .playback-venv
.playback-venv\Scripts\python -m pip install -r requirements-playback.txt
.playback-venv\Scripts\python -m speech_http.playback
```

LinuxでPortAudioが見つからない場合は、OSのパッケージを導入します（Debian/Ubuntuでは `libportaudio2`）。
既存のReader用 `.venv` を使う場合は `make speech-playback-setup` の後、`make speech-playback` で起動できます。

既定は `127.0.0.1:8768` で待ち受けます。終了は起動したターミナルでCtrl-Cです。
出力デバイスや先読み秒数を変更できます。

```sh
python -m speech_http.playback --list-devices
python -m speech_http.playback --device "出力デバイス名" --prebuffer 2
```

## SSH先のEmacsから手元へ再生する

手元で上記の再生サーバーを起動し、次のようにSSH接続します。
`remote-mac` はKindleとEmacsと生成サーバーを動かすMacです。

```sh
ssh -o ExitOnForwardFailure=yes -R 18768:127.0.0.1:8768 user@remote-mac
```

SSH先の `127.0.0.1:18768` が手元の再生サーバーにつながります。
このポートは、SSH先のEmacsからも生成サーバーからも使います。
生成サーバーが別のホストにある場合は、そのホストから到達できる転送経路も必要です。

SSH先の生成サーバーへ、再生先の名前とURLを登録します。

```sh
export READER_SPEECH_PLAYBACK_TARGETS='{"desktop":"http://127.0.0.1:18768"}'
# 既存サーバーが稼働中なら、読み上げを止めて設定を再読み込みします。
.venv/bin/python -m speech_http.service stop
make speech-server
```

この環境変数はlaunchdのサービス定義へ引き継がれます。既に稼働しているサーバーには、
環境変数を設定しただけでは反映されないため再起動してください。
WebSocket制御用のaiohttpもEmacs側のPythonに導入します。
既存Reader環境なら `make speech-playback-setup`、制御専用環境なら `pip install 'aiohttp>=3.10,<4'` を使えます。

SSH先のEmacsで設定します。

```elisp
(require 'reader-http-speech-transport)
(setq reader-http-speech-endpoint "http://127.0.0.1:8765")
(reader-http-speech-set-playback-server "http://127.0.0.1:18768" "desktop")
```

通常の `SPC` / `s` で読み上げます。音声は手元で鳴り、実際の再生終了がEmacsへ届いて文送りが進みます。
このモードではEmacsホストのネイティブ音声ブリッジを起動せず、WAV一時ファイルも作りません。
先読み済みの次の区間は、前の区間の再生終了を待たずに生成・転送されます。

対話的には `M-x reader-http-speech-set-playback-server` から変更できます。
Emacs側での従来の再生へ戻すには、同じコマンドでURLを空欄にします。

```elisp
(reader-http-speech-set-playback-server nil)
```

この設定は通常のReader操作に適用します。独立コマンド `reader-http-speech-speak` は、
引き続き要求元のEmacsホストでFFplay再生します。

## LANで直接接続する

再生サーバーを `--host 0.0.0.0` で起動し、上記URLを手元のLANアドレスに置き換えます。
生成サーバー側の `desktop` のURLと、Emacs側の再生URLは、各ホストから同じ再生サーバーへ
到達するよう設定します。SSH経由とLAN経由など、URL表記が異なっても構いません。

再生制御を認証する場合は、再生サーバーとEmacsのプロセス環境へ同じ `READER_PLAYBACK_TOKEN` を設定します。
実行中のEmacsでは `(setenv "READER_PLAYBACK_TOKEN" "設定したトークン")` の後、再生先を選び直してください。
生成サーバーへの認証には従来の `READER_SPEECH_TOKEN` を使います。
手元へ届くWAVは、制御接続ごとに発行した一時トークンで認証します。

再生サーバーは一度に一つのEmacs接続が操作します。別接続は409で拒否し、既存の読み上げを奪いません。
HTTP/WSをLAN外へ直接公開せず、SSHトンネルまたはHTTPS/WSSを利用してください。

## 通信仕様

- Emacs → 再生サーバー: `/v1/control` のWebSocket。`reserve`、`hold`、`play`、`stop` を送信。
- 再生サーバー → Emacs: `ready`、`queued`、`loaded`、`started`、`finished`、`stopped`、`error`。
- Emacs → 生成サーバー: `POST /v1/speech/deliver`。既存の音声設定と次の `playback` を送信。

```json
{
  "text": "こんにちは。",
  "language": "ja",
  "backend": "macos",
  "rate": 300,
  "playback": {
    "target": "desktop",
    "session": "readyで受け取ったセッションID",
    "delivery_token": "readyで受け取った一時トークン",
    "id": 1
  }
}
```

`reserve` の `queued` を確認してから生成を要求します。
生成サーバーの応答はNDJSONの `start`、`delivered`（連番付き）、`done` / `error` で、
WAVを含みません。この `done` は**転送完了**であり、再生終了ではありません。

生成サーバー → 再生サーバーの転送先:

- `POST /v1/sessions/{session}/audio/{id}/{index}`: 24kHz・モノラル・PCM16のWAV
- 同じパス末尾の `done`: `{"count": チャンク数}`
- 同じパス末尾の `check`: 予約がまだ有効かの確認

再生側は一つの出力ストリームへPCMを連結します。開始・終了通知はPortAudioのDAC時刻に合わせ、
最後のサンプルの出力予定時刻を過ぎてから `finished` を送ります。これは受信完了や
オーディオバッファ投入完了の通知とは区別しています。機器・ドライバーが報告する時刻に依存します。

停止は出力をabortし、全予約と遅延通知を破棄します。同じ接続でIDを再利用せず、
停止後の古いWAVや重複・順序違いのチャンクは拒否します。制御接続の切断も再生を停止します。
生成モデルの計算中断は行いませんが、その結果を古い再生キューへ入れることはありません。
生成先URLはリクエストで自由指定できず、サーバー管理者が登録した名前だけを使います。

再生側の上限は予約32件、PCMバッファ64MiB、WAV転送1回16MiBです。
生成が再生に追いつかない場合は待ちが発生します。先読みはその待ちを減らすためのもので、
遅いモデルでも無条件に連続再生できる保証ではありません。

## 検証結果・トラブル確認

2026-09-18にmacOSで、生成・再生を別プロセスにして以下を確認しました。

- 実行中のEmacsから日本語を送り、手元のスピーカーで再生、`finished` を受信。
- EmacsにWAV一時ファイルを作らず、生成サーバーから再生サーバーへ直接転送。
- 先読みした2区間の、前区間の終了DAC時刻と次区間の開始DAC時刻が一致。
- 生成中に停止した後、古い音声の再生や文送りが起きないこと。

この実機確認は同じMac内の別プロセス間です。別マシン間のSSH接続とWindows/Linux実機は未検証です。
自動テストではWAV転送、認証、排他接続、停止・切断、順序、デバイス時刻での完了通知を検証します。
HTTP・分離再生関連の38件が成功しています。既存Reader全体は211/213件成功で、
Accessibilityブリッジ設定と読書位置の保存先設定の2件が失敗しています。

```sh
make speech-playback-test speech-http-test
```

Emacs側では `*HTTP Playback Errors*`（制御接続）と `*HTTP Speech Errors*`（生成・転送）、
生成側では `~/Library/Caches/ReaderSpeechServer/8765/server.log` を確認してください。
再生サーバー停止中は自動起動・別端末への代替再生をせず、読み上げを止めます。

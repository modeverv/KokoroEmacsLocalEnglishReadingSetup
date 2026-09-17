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

## macOSの単体アプリ（Intel / Apple Silicon）

`Reader Playback Server.app` はmacOS Monterey（12）以降を対象にしたUniversalアプリです。
Intel版とApple Silicon版のPython 3.12・PortAudio・必要なライブラリを同梱し、
利用先でPython、Homebrew、Emacs、音声モデルをインストールする必要はありません。

1. `ReaderPlaybackServer-macOS12-universal.zip` を再生するMacへコピーして展開します。
2. `Reader Playback Server.app` をApplicationsなど任意の場所へ移動して開きます。
3. SSH経由なら「このMacのみ」、LAN直接接続なら「LANから接続」を選択します。
4. 「サーバースタート」を押します。既定ポートは8768です。
5. 以下の手順でEmacsに再生先URLを設定します。生成サーバーへの事前登録は不要です。

音声出力デバイスは空欄でシステム既定を使います。「停止」またはアプリ終了でサーバーも停止します。
認証トークンは任意で、設定した場合はEmacsの `READER_PLAYBACK_TOKEN` に同じ値を設定します。
設定値・トークンは終了時に保存しません。ログは `~/Library/Logs/ReaderPlayback/server.log` です。

開発用のアドホック署名を付けていますが、Appleの公証は未実施です。
転送先で確認を求められた場合は、macOSの「セキュリティとプライバシー」からこのアプリの起動を許可してください。

ソースから作るには、ビルドするMacにXcode Command Line Tools、Python 3.11以降、uvが必要です。
初回は両CPUのランタイムと依存パッケージをダウンロードします。

```sh
make speech-playback-app
```

成果物は `playback-app/build/` に作成します。`compatibility-report.json` に全Mach-OのCPU・最低OS・リンク先を記録します。
ビルドはmacOS 12を指定し、外部Python/Homebrewへの絶対参照や、macOS 12より新しいOSを要求するバイナリを拒否します。

確認済み: Apple Silicon上で、作業フォルダー外へ移動したアプリのGUI起動・停止、WAV実デバイス出力、
再生開始・終了通知、署名の検証。同梱46スライスの静的互換性検査も成功しました。
**Intel Mac / Monterey実機では未検証です。** 静的検査だけで、古いOSの全実行時動作までは保証できません。
音声生成は引き続き別の生成サーバーで行うため、Intel側にMLXは不要です。

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

生成サーバーは通常どおり起動します。転送先の環境変数設定や、転送先変更のたびの再起動は不要です。
WebSocket制御用のaiohttpもEmacs側のPythonに導入します。
既存Reader環境なら `make speech-playback-setup`、制御専用環境なら `pip install 'aiohttp>=3.10,<4'` を使えます。

SSH先のEmacsで設定します。

```elisp
(require 'reader-http-speech-transport)
(setq reader-http-speech-endpoint "http://127.0.0.1:8765")
(reader-http-speech-set-playback-server "http://127.0.0.1:18768")
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
Emacsで指定したURLを生成リクエストにも含めます。両ホストから到達できるURLを指定してください。
異なるURLが必要な場合は、第3引数に生成サーバーから見たURLを指定します。

```elisp
(reader-http-speech-set-playback-server
 "http://127.0.0.1:8768" nil "http://192.168.1.20:8768")
```

第2引数の転送先名は旧設定との互換用です。新しい生成サーバーはリクエストのURLを優先します。

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
    "endpoint": "http://127.0.0.1:8768",
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
転送先はリクエストの `playback.endpoint` で指定します。HTTP(S)のホスト・ポートのみを受け付け、
認証情報・パス・クエリを含むURLやHTTPリダイレクトを拒否します。生成前に、転送先でセッションと予約IDを確認します。
生成APIへのアクセス権があるクライアントは転送先を指定できるため、共有ネットワークでは
既存の `READER_SPEECH_TOKEN` で生成APIを認証してください。
旧クライアントの `playback.target` と `READER_SPEECH_PLAYBACK_TARGETS` も引き続き利用できます。

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

### 接続時にHTTP 409になる場合

再生サーバーは一度に一つのEmacsだけが操作します。別のGUI/SSH Emacsの接続が残っている場合は、
そのEmacsで `(reader-http-speech-set-playback-server nil)` を評価して解放してください。
読み上げを停止するだけでは制御接続は残ります。
また、CLI版とGUIアプリを同じポートで重複起動しないでください。
macOSではループバックと全インターフェースへの待ち受けが併存し、接続先が意図と異なることがあります。
`lsof -nP -iTCP:8768` で確認し、不要な検証用サーバーを終了します。

HTTP 401は再生側の認証トークン不一致、404は接続先ポートなどの誤りを確認します。
旧サーバーで `unknown playback target` が出る場合は生成サーバーを更新し、一度再起動してください。
更新後はEmacsのURL指定だけで転送でき、`READER_SPEECH_PLAYBACK_TARGETS` は不要です。

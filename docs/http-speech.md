# HTTP読み上げサーバー

Emacsの本文・言語・音声・速度をHTTPで送り、生成されたWAVチャンクを順番に再生します。
GUIはmacOSのネイティブAppKitアプリです。Web GUIと8766番の管理HTTPサーバーは廃止しました。

## 起動と停止

通常はサーバーを先に起動する必要はありません。Emacsから読み上げを始めると、
ローカルサーバーが停止中なら自動起動し、受付可能になってから本文を送ります。
同時に複数の先読み要求が来ても、ロックと起動後の再確認で二重起動を防ぎます。

既定の待受は **0.0.0.0:8765** です。0.0.0.0は待受アドレスで、ポート番号は8765です。
同じMac上のEmacsの接続先は **http://127.0.0.1:8765**。
別端末からはこのMacのLANアドレスを指定します。

GUIは次のいずれかで開きます。

- `M-x reader-http-speech-open-gui`
- リポジトリで `make speech-gui`
- Finderから `scripts/speech-server-gui.command` をダブルクリック
- ビルド済みの `speech-http-app/build/Reader Speech Server.app` を開く

GUIには「サーバースタート」「停止」と稼働状態を表示します。
Emacsの自動起動とGUIは、同じlaunchdサービスを操作します。
GUIやEmacsを終了してもサーバーは継続します。停止時は読み上げを止めてからGUIの「停止」を使います。
停止後でもEmacsで新しく読み上げると再度自動起動します。
ログイン項目には登録せず、次回ログイン後は最初の読み上げで起動します。

コマンドラインで同じサービスを操作する場合:

```sh
make speech-server
.venv/bin/python -m speech_http.service status
.venv/bin/python -m speech_http.service stop
```

launchdの起動定義・ログは `~/Library/Caches/ReaderSpeechServer/8765/` に置きます。
サーバーが起動しない場合は同ディレクトリの `server.log`、リクエスト失敗はEmacsの
`*HTTP Speech Errors*` を確認してください。手動で直接 `python -m speech_http.server` を起動した場合は、
そのプロセスの停止は起動したターミナルで行います。

## 必要な環境

既存の `.venv`（Python 3.11以上）を使います。音声合成側に `ffmpeg`、
独立した再生クライアントには `ffplay` が必要です。通常のEmacs読書は既存の常駐音声ブリッジで再生します。
Kokoro/Irodoriは既存のMLX環境・モデル、macOS音声は `/usr/bin/say` を使用します。

ネイティブアプリのビルドにはAppleのCommand Line Toolsが必要です。
`make speech-app-build` でビルドでき、`make speech-gui` は未ビルド・ソース更新時に自動ビルドします。
アプリはこのチェックアウトと `.venv` を参照するランチャーです。
別の場所へリポジトリを移動した場合は `make speech-app-build` で再ビルドしてください。

## 通常のEmacs読書を接続

```elisp
(add-to-list 'load-path "/Users/seijiro/Sync/emacs.d/reader")
(require 'reader-http-speech-transport)
(reader-http-speech-transport-mode 1)
```

通常の `s` / `SPC` と先読みがHTTP経由になります。有効化時は一度停止するので `s` で再開します。
再起動後も有効にするにはこのブランチ用のEmacs設定で上記を読み込みます。

Emacsのネイティブ音声ブリッジは、ダウンロードしたWAVの連続再生を担当します。
文の完了通知・ハイライト・PDF/EPUB/Kindleの既存の送り処理は維持します。
各読書チャンク内のWAVを受信し終えてから常駐プレイヤーへ渡し、複数の先読み枠を順番に再生します。

### 言語・音声・速度はEmacsから指定

既存の以下の関数が、そのまま次のHTTPリクエストへ反映されます。

```elisp
(my-read-set-speech-language 'ja)   ; 日本語で読む
(my-read-set-speech-language 'en)   ; 英語で読む
(my-read-set-speech-language nil)   ; 自動判定に戻す
(my-read-change-japanese-speed 300) ; 日本語macOS音声: 語/分
(my-read-change-english-speed 1.2)  ; 英語Kokoro: 倍率
```

言語変更は読書本文ペインで行います。設定変更時に古い先読みを破棄し、`s` / `SPC` で再開すると
新しい設定を送ります。macOS音声は `rate` に語/分をそのまま送るため、540なども変換せず反映します。
Kokoro/Irodoriは `speed` に0.5〜2.0の倍率を送ります。声・バックエンド・英語の発音言語コードも
バッファの設定を毎回取得します。日本語Irodoriは既存の [Irodori手順](../README-irodori.md) を参照してください。

サーバー側はユーザーごとの言語・速度を固定保持せず、リクエストの値で合成します。
複数クライアントの言語設定が混ざることはありません。

## 独立した文字列の読み上げ

```elisp
(require 'reader-http-speech)
(reader-http-speech-speak "こんにちは。続けて読みます。" "ja")
(reader-http-speech-speak "Hello. Read this in English." "en")
```

`M-x reader-http-speech-read-japanese` / `reader-http-speech-read-english` は選択範囲、
未選択ならカーソルからバッファ末尾を読みます。`reader-http-speech-stop` で停止します。
my-readがロードされていれば、これらのコマンドも言語別のmy-read速度・音声設定を使います。
my-readなしで使う場合は `reader-http-speech-japanese-speed` 等の独立設定を使います。

独立クライアントは先読み後に1つのFFplayへPCMを流します。既定先読みは8秒で、
`reader-http-speech-prebuffer` で変更できます。独立コマンドは章送りやハイライトには接続しません。
通常の読書機能を使う場合は上記transport-modeを使います。

## 外部API

```sh
curl -N http://127.0.0.1:8765/v1/speech/stream \
  -H 'Content-Type: application/json' \
  -d '{"text":"こんにちは。","language":"ja","backend":"macos","rate":300}'
```

| パラメーター | 内容 |
|---|---|
| `text` | 本文、1〜24,000文字 |
| `language` | `ja` / `en` |
| `backend` | `macos` / `kokoro` / `irodori`。既定は日本語macos、英語kokoro |
| `voice` | 省略時はKyoko / bf_emma / jf_alpha / asukaを言語と方式に応じて選択 |
| `rate` | macOS専用の正の整数（語/分）。指定時はspeedより優先 |
| `speed` | 0.5〜2.0の倍率。既定1.0 |
| `lang_code` | 英語 `a` / `b`、日本語 `j`。省略可能 |

応答は `application/x-ndjson`（1行1JSON）です。

```json
{"type":"start","protocol":1,"sample_rate":24000}
{"type":"audio","index":0,"wav":"BASE64_ENCODED_COMPLETE_WAV"}
{"type":"audio","index":1,"wav":"BASE64_ENCODED_COMPLETE_WAV"}
{"type":"done"}
```

各wavをBase64デコードすると単独のWAVになります。形式は24kHz・モノラル・PCM16です。
WAVヘッダーを除いたPCMを順に再生してください。実装例は `speech_http/client.py`。

```sh
printf '%s' '{"text":"Hello. A speech test.","language":"en","speed":1.2}' \
  | python3 -m speech_http.client --auto-start --endpoint http://127.0.0.1:8765
```

本文は最大240文字の文章単位に分けて合成します。モデル内部の真のストリーミング生成ではありません。
合成速度やネットワークが再生速度を継続して下回る場合は、バッファ不足が起こり得ます。
入力エラーは400、認証エラーは401、受付上限超過は503。
HTTP 200後の合成失敗は `error` イベントを返し、`done` 前の切断も失敗として扱います。

## 別マシンへの移動

```elisp
(setq reader-http-speech-endpoint "http://server-host:8765")
```

リモート接続先が停止中の場合、手元のMacに代替サーバーを起動することはありません。
自動起動はlocalhost・127.0.0.1のローカル接続専用です。
SSHトンネルを使う場合もローカルの同ポートに別サービスを起動しないよう注意してください。

現在の合成実装はmacOS/Apple Silicon用です。Linux/GPUへ移す場合はサーバーの合成アダプターを
差し替え、HTTP/WAV仕様を維持すればEmacs側を変更せず使えます。
任意の `READER_SPEECH_TOKEN` をサーバー起動時とクライアントに設定するとBearer認証を使えます。
LAN外で使用する際はHTTPSプロキシ等で暗号化してください。

## 検証

`make speech-http-test` はHTTP配信・WAV連結・停止・起動制御・Emacsの設定反映を検証します。
2026-09-17に、ネイティブGUIの起動・停止、サーバー停止状態からEmacsの通常の読み上げによる
自動起動、0.0.0.0での待受、日本語の連続再生を実機で確認しました。
言語切替と速度変更の既存関数を実際に呼び、次のリクエストが日本語540語/分・英語1.4倍へ
変わることをERTで確認しています。
Python 18件、ERT 6件が成功しました。同じ日本語文章の実音声生成では300語/分で3.804秒、
540語/分で2.227秒となり、語/分の指定が合成結果に反映されました。

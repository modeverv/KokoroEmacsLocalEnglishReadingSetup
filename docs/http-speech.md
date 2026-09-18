# HTTP読み上げサーバー

Emacsの本文・言語・音声・速度をHTTPで送り、生成されたWAVチャンクを順番に再生します。
GUIはmacOSのネイティブAppKitアプリです。Web GUIと8766番の管理HTTPサーバーは廃止しました。

Emacsと別端末で音を出す場合は、[生成・再生サーバーの分離](remote-playback.md)を利用できます。
既存の `/v1/speech/stream` は要求元へWAVを返し、追加の `/v1/speech/deliver` は登録済みの再生先へ直接転送します。

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
- ビルド済みの `companion-implementations/speech-http-app/build/Reader Speech Server.app` を開く

GUIには「サーバースタート」「停止」と稼働状態を表示します。
Emacsの自動起動とGUIは、同じlaunchdサービスを操作します。
GUIを閉じてもサーバーは継続します。Emacsを通常終了すると、そのEmacsから利用したローカルの
launchd音声サーバーを停止します。共有サーバーとして残す場合は
`(setq reader-http-speech-stop-server-on-exit nil)` を設定してください。
リモート接続先や、ターミナルから直接起動したサーバーは終了しません。
復旧には `M-x reader-http-speech-restart-server`、停止には
`M-x reader-http-speech-stop-server` を使えます。
HTTP 503（同時受付の混雑）は最大30秒待って再試行し、途中まで受信した音声は再送しません。
停止後でもEmacsで新しく読み上げると再度自動起動します。
ログイン項目には登録せず、次回ログイン後は最初の読み上げで起動します。

コマンドラインで同じサービスを操作する場合:

```sh
make speech-server
(cd companion-implementations && .venv/bin/python -m speech_http.service status)
(cd companion-implementations && .venv/bin/python -m speech_http.service stop)
```

launchdの起動定義・ログは `~/Library/Caches/ReaderSpeechServer/8765/` に置きます。
サーバーが起動しない場合は同ディレクトリの `server.log`、リクエスト失敗はEmacsの
`*HTTP Speech Errors*` を確認してください。手動で直接 `python -m speech_http.server` を起動した場合は、
そのプロセスの停止は起動したターミナルで行います。

## 必要な環境

既存の `companion-implementations/.venv`（Python 3.11以上）を使います。音声合成側に `ffmpeg`、
独立した再生クライアントには `ffplay` が必要です。通常のEmacs読書は既存の常駐音声ブリッジで再生します。
Kokoro/Irodoriは既存のMLX環境・モデル、macOS音声は `/usr/bin/say` を使用します。

ネイティブアプリのビルドにはAppleのCommand Line Toolsが必要です。
`make speech-app-build` でビルドでき、`make speech-gui` は未ビルド・ソース更新時に自動ビルドします。
アプリはこのチェックアウトと `companion-implementations/.venv` を参照するランチャーです。
Emacsを起動せず、Finderからこの `.app` を開いて「サーバースタート」だけで利用できます。
アプリ画面にLAN接続先を表示します。このMacのPython環境を使用するため、別Macへ `.app` だけを
コピーして使う配布形式ではありません。
別の場所へリポジトリを移動した場合は `make speech-app-build` で再ビルドしてください。
本と音声波形の[アプリアイコン・生成記録](../companion-implementations/speech-http-app/ICON.md)を同梱しています。

## 通常のEmacs読書を接続

```elisp
(add-to-list 'load-path "/Users/seijiro/Sync/emacs.d/reader")
(require 'my-read)
(require 'reader-http-speech-transport)
(reader-http-speech-transport-mode 1)
```

通常の `s` / `SPC` と先読みがHTTP経由になります。有効化時は一度停止するので `s` で再開します。
再起動後も有効にするにはEmacsの設定ファイルで上記を読み込みます。

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
バッファの設定を毎回取得します。日本語Irodoriは既存の [Irodori手順](README-irodori.md) を参照してください。

サーバー側はユーザーごとの言語・速度を固定保持せず、リクエストの値で合成します。
複数クライアントの言語設定が混ざることはありません。

## 独立した文字列の読み上げ

```elisp
(require 'my-read)
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
| `language` | `auto` / `ja` / `en`（省略時は従来どおり `en`） |
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
WAVヘッダーを除いたPCMを順に再生してください。実装例は `companion-implementations/speech_http/client.py`。

```sh
printf '%s' '{"text":"Hello. A speech test.","language":"en","speed":1.2}' \
  | python3 -m speech_http.client --auto-start --endpoint http://127.0.0.1:8765
```

本文は最大240文字の文章単位に分けて合成します。モデル内部の真のストリーミング生成ではありません。
合成速度やネットワークが再生速度を継続して下回る場合は、バッファ不足が起こり得ます。
入力エラーは400、認証エラーは401、受付上限超過は503。
HTTP 200後の合成失敗は `error` イベントを返し、`done` 前の切断も失敗として扱います。

### 英語・日本語の自動判定

`language: "auto"` は本文全体を一度判定してから生成します。ひらがな・カタカナ・漢字が
あれば日本語、それ以外で英字があれば英語です。半角カナ・全角英字も判定します。
数字・記号だけなら `fallback_language`（`en` / `ja`、既定 `en`）を使います。
判定のための文字正規化は本文を変更しません。混在文は日本語優先、ローマ字日本語は英語扱いです。
これは英語・日本語の2択用で、他言語の識別は行いません。

```json
{"text":"日本語のAPI説明です。","language":"auto"}
```

既定は英語がKokoro / bf_emma / 1.0倍、日本語がmacOS / Kyoko / 250語毎分です。
声や速度を言語別に指定する場合:

```json
{
  "text": "Hello. This is a reading test.",
  "language": "auto",
  "fallback_language": "en",
  "language_options": {
    "en": {"backend": "kokoro", "voice": "bf_emma", "speed": 1.0},
    "ja": {"backend": "macos", "voice": "Kyoko", "rate": 540}
  }
}
```

`auto` では `voice` / `rate` / `lang_code` を上位に置かず、`language_options.en` / `.ja` に
入れてください。誤った言語の設定の使い回しはHTTP 400で防ぎます。共通の `backend` / `speed`
は上位にも指定でき、言語別設定が優先します。判定後の設定にも既存の検証が適用されます。
`ja` / `en` の明示指定は本文に関係なく優先し、従来の声・速度の指定方法を維持します。

`/v1/speech/stream` と `/v1/speech/deliver` の両方で利用できます。先頭の `start` イベントに
判定後の `language`・`backend`・`voice`・`speed`・`rate` を返します。
`rate` が `null` のmacOS音声は、従来どおり `250 × speed` の毎分語数を使います。
EmacsのKindle・PDF・EWWは、手動指定がなければ `auto` を送り、両言語の声・速度を
`language_options` に含めます。`my-read-set-speech-language` の `ja` / `en` は優先されます。
EPUB・TEXTは従来のEmacs側の判定を維持します。数字だけの区間はEmacs側の推定言語を
`fallback_language` として送ります。翻訳や文の分割に使うEmacs側の推定言語は維持します。
Kindleのヘッダーには `AUTO/Server`、`reader-diagnose` には言語指定の方針を表示します。

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

## 連続読み上げの生成待ち対策

macOS音声は短い文を最大240文字までまとめて生成し、`say` の起動回数を減らします。
同時に2件まで生成できる専用ワーカーを使い、Kokoro/Irodoriのモデル処理は従来どおり直列です。
すでに24kHz・モノラルPCM16のWAVは再変換せず、そのまま転送します。
Emacsの表示・ハイライト区間と読み上げ速度は変更しません。

ネイティブ再生は、先読みが空になったらプレイヤーを一時停止してから再開準備を待ちます。
これにより再生開始通知より先に音声だけが流れることを防ぎます。
macOSの音声デバイスが使える環境では `make speech-native-test` で、
先読み切れの後も開始・終了通知が順番に揃うことを無音PCMで検証できます。

## 検証

別のLANマシンへ `scripts/check_speech_server.py` をコピーし、Python 3だけで確認できます。

```sh
python3 check_speech_server.py http://192.168.11.30:8765 --backend kokoro --language en
python3 check_speech_server.py http://192.168.11.30:8765 --backend kokoro --language ja
python3 check_speech_server.py http://192.168.11.30:8765 --backend irodori --language ja
```

IPアドレスはアプリに表示された現在のアドレスを使います。正常時はWAV形式・順序・完了を検証して
`ok: true` と音声秒数を出力します。この確認スクリプトはサーバーを自動起動しないため、
GUIだけで起動したサーバーの検証にも使えます。

2026-09-17に実サーバーで以下を確認しました。

| 方式 | 言語・声 | 実WAV生成 |
|---|---|---|
| Kokoro | 英語 / bf_emma | 成功、4.22秒 |
| Kokoro | 日本語 / jf_alpha | 成功、5.53秒 |
| Irodori | 日本語 / asuka | 成功、4.72秒 |
| macOS | 日本語 / Kyoko | LANアドレスへのPOSTで成功、2.19秒 |

Irodoriは現在日本語のみ、参照音声は `companion-implementations/assets/asuka.wav` です。英語はKokoroまたはmacOSを使います。
待受は `*:8765`。同じMacからLANアドレス `192.168.11.30` 経由のHTTP/WAV取得は成功しました。
登録済みの別LANマシン3台はSSH接続がタイムアウトしたため、別マシンからの到達確認は未完了です。
同じMacのLANアドレスに接続できることだけでは、別端末側の経路・ファイアウォールまでは検証できません。
Emacsの読み上げを停止してGUIだけでサーバーを起動した後も、LANアドレス経由でWAV取得に成功しました。
サーバーの親プロセスはlaunchd（PID 1）で、起動・音声生成はEmacsのプロセスに依存しません。

`make speech-http-test` はHTTP配信・WAV連結・停止・起動制御・Emacsの設定反映を検証します。
2026-09-17に、ネイティブGUIの起動・停止、サーバー停止状態からEmacsの通常の読み上げによる
自動起動、0.0.0.0での待受、日本語の連続再生を実機で確認しました。
言語切替と速度変更の既存関数を実際に呼び、次のリクエストが日本語540語/分・英語1.4倍へ
変わることをERTで確認しています。
Python 18件、ERT 6件が成功しました。同じ日本語文章の実音声生成では300語/分で3.804秒、
540語/分で2.227秒となり、語/分の指定が合成結果に反映されました。

# HTTPチャンク読み上げ

Emacsから文字列と言語をPOSTし、独立したWAVチャンクを順次受信して再生する追加機能です。
Emacs以外のプログラムも同じAPIを利用できます。既存のKokoroサーバー（8000番）と
既存の `s` / `SPC` の動作はそのままで、新サーバーは8765番、管理GUIは8766番を使います。

## 起動

既存の `.venv` を使用します。必要なのはPython 3.11以上、サーバー側の `ffmpeg`、
再生するマシン側の `ffplay` です（Homebrewなら `brew install ffmpeg`）。
Kokoro/Irodoriは既存プロジェクトのMLX環境とモデルを使用します。
macOSバックエンドだけならサーバー本体にPython追加パッケージは不要です。

リポジトリのディレクトリで:

```sh
make speech-gui
```

またはFinderから `scripts/speech-server-gui.command` をダブルクリックします。
ブラウザーに表示される「サーバースタート」「停止」で操作します。
Emacsを起動する必要はありません。ブラウザーを閉じても管理プロセスは動き続けます。
管理プロセスをCtrl-Cで終了すると、それが起動したサーバーと合成子プロセスも停止します。
停止すると処理中のリクエストは失敗します。再開後、クライアントから再送してください。

GUIなしで動かす場合は `make speech-server`。
GUIの「稼働中」はHTTP受付可能を意味し、モデルは最初の合成時にロードします。
モデルの初回ダウンロード・ロード中は最初の音声まで時間がかかります。

## Emacsから使う

このブランチをチェックアウトした状態で評価します。

```elisp
(add-to-list 'load-path "/Users/seijiro/Sync/emacs.d/reader")
(require 'reader-http-speech)
(reader-http-speech-mode 1)
```

| コマンド | 内容 | mode有効時のキー |
|---|---|---|
| `reader-http-speech-read-english` | 選択範囲、未選択ならカーソルからバッファ末尾を英語で読む | `C-c h e` |
| `reader-http-speech-read-japanese` | 同じ範囲を日本語で読む | `C-c h j` |
| `reader-http-speech-read` | バッファの `reader-http-speech-language` で読む。`C-u` で選択 | `C-c h r` |
| `reader-http-speech-sentence` | 現在の1文を読む | — |
| `reader-http-speech-speak` | 任意文字列と言語を入力して読む | — |
| `reader-http-speech-stop` | 受信とローカル再生を停止 | `C-c h s` |
| `reader-http-speech-open-gui` | サーバー管理GUIを開く | `C-c h g` |

プログラムからも `(reader-http-speech-speak "こんにちは。次の文です。" "ja")` のように呼べます。
HTTP読み上げを始める際は既存の連続読み上げを停止し、音声の重複を防ぎます。
HTTPの停止には新しい停止コマンドを使ってください。
`*HTTP Speech*` に再生開始・完了、`*HTTP Speech Errors*` に失敗理由が出ます。

設定例:

```elisp
(setq reader-http-speech-endpoint "http://127.0.0.1:8765"
      reader-http-speech-prebuffer 8
      reader-http-speech-english-backend "kokoro"
      reader-http-speech-japanese-backend "macos"
      reader-http-speech-english-speed 1.0
      reader-http-speech-japanese-speed 1.0)
```

英語は `bf_emma`、日本語macOSは `Kyoko`（250 words/min × speed）が既定です。
日本語は `"kokoro"`（`jf_alpha`）、`"irodori"`（`asuka`）にも変更できます。
Irodoriの準備は既存の [Irodori手順](../README-irodori.md) を参照してください。
速度は0.5〜2.0。従来の読み上げ設定とは独立しています。

今回の追加コマンドはテキストをまとめて送る方式です。EPUBは現在の章が対象で、
章の自動送り、既存の文単位ハイライト・翻訳追従とはまだ接続していません。
PDF画像バッファの本文抽出もこのモジュールでは行いません。PDFの場合は抽出済みテキストを渡してください。
リクエスト上限は24,000文字です。長い文書は選択範囲を区切って利用してください。

## 外部プログラムのAPI

```sh
curl -N http://127.0.0.1:8765/v1/speech/stream \
  -H 'Content-Type: application/json' \
  -d '{"text":"こんにちは。順番に読み上げます。","language":"ja","speed":1.0}'
```

リクエストは `text`、`language`（`en` / `ja`）、任意の `backend`、`voice`、`speed`。
既定バックエンドは英語 `kokoro`、日本語 `macos`。`irodori` は日本語のみ対応します。

応答は `application/x-ndjson`（1行1JSON）です。

```json
{"type":"start","protocol":1,"sample_rate":24000}
{"type":"audio","index":0,"wav":"BASE64_ENCODED_COMPLETE_WAV"}
{"type":"audio","index":1,"wav":"BASE64_ENCODED_COMPLETE_WAV"}
{"type":"done"}
```

`wav` をBase64デコードすると、それぞれ単独で有効なWAVです。
全チャンクを **24kHz / モノラル / PCM16 little endian** に統一します。
WAVファイル全体をそのまま結合せず、ヘッダーを外したPCMフレームを順に音声出力へ送ります。
実装例は `speech_http/client.py` にあります。こちらは標準ライブラリのみで動きます。

```sh
printf '%s' '{"text":"Hello. This is a streaming test.","language":"en"}' \
  | python3 -m speech_http.client --endpoint http://127.0.0.1:8765 --prebuffer 8
```

リクエスト検証エラーはHTTP 400、認証エラーは401、同時受付上限超過は503。
HTTP 200開始後の合成失敗は `{"type":"error","message":"..."}` で通知します。
`done` より前の切断は失敗として扱ってください。自動再送すると音声が重複するため、
クライアントは勝手にリトライしません。`GET /health` で受付状態を取得できます。

## 先読みと連続出力

サーバーは句点等で文章を最大240文字に区切り、合成できたWAVから逐次返します。
MLX処理は同一の専用スレッドで直列実行し、モデルを再利用します。
これは文章単位のチャンク配信で、モデル内部の真のストリーミング生成ではありません。

クライアントは受信スレッドと再生処理を分け、既定で8秒分（短文なら全文）を蓄えて開始します。
受信キューは最大8チャンク。WAVからPCMを取り出し、全体を **1つのFFplayプロセス** へ流すため、
チャンクごとにプレイヤーを起動する空白が入りません。サーバー由来の自然な文間休止は残ります。

合成速度やネットワークが継続して再生速度を下回る場合はバッファ不足が起こり得ます。
その場合は `reader-http-speech-prebuffer` / `--prebuffer` を増やすか、速いバックエンドを選んでください。
受信中の停止では接続が閉じます。サーバーで既に実行中のモデル合成はそのチャンクが完了するまで残る場合があります。
サーバー停止ボタンはプロセスごと停止します。

## 将来の別マシンへの移動

Emacs側で `reader-http-speech-endpoint` を変更するだけでAPI接続先を移せます。
モデル・音声・合成依存ライブラリはサーバー側、FFplayはクライアント側に配置します。
現実装のKokoro/IrodoriはMLX（Apple Silicon）、KyokoはmacOS依存です。
Linux/GPUサーバーに移す場合は `speech_http.server.synthesize` のバックエンド実装を差し替えます。
その際もWAVとHTTPの仕様を維持すればEmacs側は変更不要です。

まずは別Mac上でループバックのままサーバーを起動し、SSHトンネルを使えます。

```sh
ssh -N -L 8765:127.0.0.1:8765 your-server
```

LANへ直接公開する場合は `python -m speech_http.server --host 0.0.0.0`、
GUIなら `python -m speech_http.gui --host 0.0.0.0` とします。
任意の共有トークンを `READER_SPEECH_TOKEN` 環境変数に設定するとBearer認証が有効になります。
クライアント側にも同じ環境変数を設定するか、外部プログラムでAuthorizationヘッダーを付けます。
Emacsでは `(setenv "READER_SPEECH_TOKEN" "...")` で補助プロセスへ渡せます。
HTTP自体は平文なので、外部ネットワークではSSHトンネルまたはHTTPSのリバースプロキシを使ってください。
管理GUIは常に127.0.0.1だけで待ち受けます。

## 検証

```sh
make speech-http-test
```

HTTP経由の順序・言語・WAV形式・認証・入力検証・同時受付制限・エラーと切断、
1つのプレイヤーへのPCM全フレーム連結、GUI操作の保護、Emacsの言語パラメーターを検証します。

2026-09-17の実機確認では、GUIの起動・停止とEmacsからの英語Kokoro／日本語Kyokoの
受信・FFplay再生完了を確認しました。8チャンクの受信計測では、日本語32.40秒分を17.72秒、
英語37.00秒分を4.11秒で受信しました。8秒先読み開始を仮定した最小残量はそれぞれ
5.96秒、8.82秒でした。これはこのMacでのサンプル計測で、すべての文書・接続環境の無停止を保証するものではありません。

追加テストはPython 12件、ERT 3件が成功しました。既存の `make my-read-k-ert` は
213件中206件成功・7件失敗でした。この全体テストは新しいHTTPモジュールを読み込んでおらず、
失敗は既存のPDFテスト、読書フレーム終了、Accessibilityブリッジ設定、位置保存先、
日本語エンジン再起動のテストです。全体が成功したとは扱っていません。

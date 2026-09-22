# 読み辞書

## 登録する

1. `make speech-dictionary` または `M-x reader-http-speech-open-dictionary` で開きます。
   生成サーバーが稼働中なら [読み辞書](http://127.0.0.1:8767/) を直接開けます。
2. 「単語」に本文の表記、「よみ」にひらがなを入力します。長音「ー」も使えます。
3. 必要に応じて「読みを試聴」で確認し、「登録する」を押します。

同じ単語の再登録は更新です。検索・編集・削除も画面で行えます。
IPAの入力、方式の選択、外部アカウントやAPIキーの用意は不要です。
本文・翻訳対象・表示上のハイライトは変更しません。
保存する読みはひらがなのまま、合成時だけカタカナに変換します。
例えば「葉山→はやま」は「ハヤマ」と渡し、語頭の「は」を助詞として解釈する誤読を避けます。
試聴とIPA候補の基準音声にも同じカタカナ読みを使います。

辞書はプロジェクトルート直下の `pronunciations.json` に保存します。
辞書本体・ロックファイル・保存時の一時ファイルは `.gitignore` で除外します。
`READER_SPEECH_DICTIONARY` で別ファイルを指定できます。HTTPサーバーと直接合成ブリッジを
同じ辞書にする場合は両方に同じ環境変数を渡します。Web UIは生成サーバーのMacで開きます。
デフォルトでは、このMacでのHTTP合成と直接合成が同じ辞書を参照します。

起動時に読み込み、以後も合成直前に変更を読み直します。保存はプロセス間ロック付きの
原子的置換で行います。すでに生成・先読み済みの音声は変更されないので、辞書を編集した後は
読み上げを停止して再開してください。既存のブリッジプロセスへのコード更新は、Emacsを再起動して反映します。

## IPAの自動判定

登録時、ひらがなからローカルの変換規則でIPA候補を作ります。Kyokoで「入力した読みをカタカナにした基準音声」と
「元の単語にIPA属性を付けた音声」を、単独と「これは〜です。」の2通りで生成します。
音声長とメルスペクトルのDTW距離を比較し、両方が保守的な一致基準を満たす候補だけ採用します。
候補が作れない場合、一致が弱い場合、IPA合成に失敗した場合は、入力したひらがなを使います。
利用者がIPAの可否を判断する必要はありません。外部サービスやLLMには送信しません。

この判定は音響的一致の検査であり、言語学的な正解や文脈ごとのアクセントを保証するものではありません。
判定が不確かなときはIPA採用率より入力した読みを優先します。試聴は入力したひらがなの基準音声です。
採用結果はJSONの `strategy`、`ipa`、`verification`、`score` に記録します。
IPAは検証した音声ID・macOSバージョンに限定して適用し、他の日本語音声やOS更新後はかな読みに戻します。
日本語以外の音声にはこの日本語辞書を適用しません。Kokoro/Irodoriへの辞書適用は今回の対象外です。

一致は元の文字列上で長い単語を優先し、置換した読みへの再置換をしません。
ASCII英数字の語は長い英単語の一部に一致させません。通常の日本語文字列は部分一致です。
単語・読みは各100文字、辞書は2000語までです。

## Kyoko実機検証（2026-09-22）

このMacで選択された音声は `com.apple.voice.compact.ja-JP.Kyoko`、
OSは macOS 27.0 / 26A428 です。

- 通常の「東京」を2回生成すると、WAVのSHA-256は同一でした。
- 同じ「東京」に `ne.ko` のIPA属性を付けると、生成時間長は約0.861秒から約0.542秒になり、波形も変化しました。
- したがってこの音声では、IPA属性は無視されず生成に反映されます。
- 一方、かなの「ねこ」とIPA指定は完全一致せず、`sa.kɯ.ɾa` もかなの「さくら」と差がありました。
  属性の反映だけを理由に「どんなIPAも正しく発音できる」とは判断しません。
- 「東京→ねこ」「重複→ちょうふく」「固有名詞→こゆうめいし」の登録実験では、現行の保守的な基準では
  いずれもかな読みが自動選択されました。IPAを強制して誤読を増やさないための意図した挙動です。

再検証してWAV・音声ID・ハッシュ・判定結果を保存するには:

```sh
PYTHONPATH=companion-implementations companion-implementations/.venv/bin/python \
  scripts/verify_kyoko_ipa.py /tmp/reader-kyoko-verification
```

AppleのAPI仕様: [AVSpeechSynthesisIPANotationAttribute](https://developer.apple.com/documentation/avfaudio/avspeechsynthesisipanotationattribute)。

## 構成と検証

FastAPIは生成サーバーの同一プロセス内で起動・停止し、`127.0.0.1:8767` にだけ待ち受けます。
生成ポートを変えると辞書UIは生成ポート+2になります。`--dictionary-port` で上書きできます。
クロスオリジンの更新と不正Hostを拒否し、保存前に辞書を再読込して同時編集による欠落を防ぎます。
辞書ファイルが壊れている場合はエラーにし、空の辞書で上書きしません。

```sh
make my-read-speech-build
PYTHONPATH=companion-implementations companion-implementations/.venv/bin/python \
  -m unittest discover -s test -p test_pronunciation.py -v
READER_NATIVE_AUDIO_TESTS=1 PYTHONPATH=companion-implementations companion-implementations/.venv/bin/python \
  -m unittest discover -s test -p test_pronunciation.py -v
make speech-native-test
```

起動済みの旧サーバーは `M-x reader-http-speech-restart-server` で再起動してください。

# asuka2 MLX TTS比較

実行日: 2026-09-22 / Apple M4 Max・128GB / Python 3.11.9 / mlx-audio 0.4.7 / MLX 0.32.2

## 条件

- 参照: assets/asuka2.wav の先頭0〜4.8秒。70.5秒の原本から最初の自己紹介を抽出し、左右平均でモノラル化。両モデルで同一WAVを使用。
- Qwen3-TTS-12Hz-1.7B-Base-8bit: 参照音声とASR由来の文字起こし（固有名詞を補正）を使うICL方式。Japanese、temperature=0.9、repetition_penalty=1.5。
- Irodori-TTS-500M-v3-8bit: 参照音声、24 steps、sway=-1、duration_scale=1。
- seed=42。モデルを順番に実行。短文初回の後、短文3回・長文3回。各回の参照処理を含む生成時間を測定し、MLX同期・配列取得完了まで計時。WAV書込は別計時。
- ダウンロード完了後、HF_HUB_OFFLINE=1で測定。モデル読込時間は別計測。プロセス起動・Python import時間は含まない。通常の常駐アプリが動作中で、専有ベンチマークではない。
- 両モデルは規模・方式・出力サンプルレートが異なる。今回の設定の比較であり、系列全体の順位を示すものではない。

## 処理時間（warm 3回の中央値）

|モデル|文章|生成秒（最小〜最大）|音声秒|RTF|
|---|---|---:|---:|---:|
|qwen|short|6.53 (6.49–7.38)|6.96|0.94|
|qwen|reading|15.61 (14.88–15.82)|15.70|0.99|
|irodori|short|7.11 (7.07–7.68)|8.08|0.88|
|irodori|reading|14.93 (14.31–15.21)|19.08|0.78|

RTF = 生成秒 / 音声秒。1未満なら実時間より速い。

- qwen: モデル読込 2.39秒、短文初回生成 8.71秒。
- irodori: モデル読込 2.26秒、短文初回生成 7.22秒。

## 試聴

比較WAVは **Qwen → 1秒無音 → Irodori**。48kHz・16bit・mono。全体RMSを揃え、ピークが−1dBFSを超えない共通音量に調整（LUFS合わせではない）。元の生成WAVも保存。時間伸縮・無音除去は行っていない。

### short
こんにちは。今日は、音声合成の聞き比べをします。窓の外には青い空が広がっています。

- [連続比較](compare-short-qwen-then-irodori.wav)
- [Qwen原音](qwen-01-short.wav)
- [Irodori原音](irodori-01-short.wav)

### reading
午後三時、駅前の小さな喫茶店で友人を待っていました。温かいコーヒーを一口飲むと、雨に濡れた街の景色が、少しだけ明るく見えました。「お待たせ。久しぶりだね」と、懐かしい声が聞こえます。

- [連続比較](compare-reading-qwen-then-irodori.wav)
- [Qwen原音](qwen-04-reading.wav)
- [Irodori原音](irodori-04-reading.wav)

声の似方、抑揚、読み間違い、文末や息継ぎを試聴で比較してください。数値検査とASRは主観的な声質評価を代替しません。

## 再実行

```sh
HF_HUB_OFFLINE=1 /Users/seijiro/.cache/asuka2-mlx-benchmark-venv/bin/python benchmark.py irodori
HF_HUB_OFFLINE=1 /Users/seijiro/.cache/asuka2-mlx-benchmark-venv/bin/python benchmark.py qwen
/Users/seijiro/.cache/asuka2-mlx-benchmark-venv/bin/python package_results.py
```

環境: environment.txt、設定・全計測値: *-metrics.json、原本ハッシュ・切出条件: reference-metadata.json。

## 生成後の確認

代表4本のWAVを再読込して、有限値・非無音・長さを確認。Whisper smallによる文字起こしはaudio-check.jsonに保存。長文は両モデルとも概ね本文に一致。短文では「音声合成」が両方「音声合声」、Irodoriの「聞き比べ」が「危機比べ」と認識されたが、ASR誤認か発音差かはこの検査だけでは確定できない。声の類似度や自然さの聴感評価は未実施。

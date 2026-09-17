# 日本語Irodori MLX音声

`assets/asuka.wav`を参照して声を再現するローカル音声合成です。
追加学習は行いません。参照WAVは`.gitignore`で除外しています。

## 導入

```sh
make my-read-irodori-setup
```

uvと、このプロジェクト対応のPythonが必要です。`uv.lock`のMLX環境を同期し、
モデル・コーデックをHugging Faceから取得します。
既存Kokoroと同じ仮想環境で動き、追加のPyTorchサーバーは不要です。
参照音声と本文はローカルで処理します。

- モデル: `mlx-community/Irodori-TTS-500M-v3-8bit`
- ランタイム: `mlx-audio`（検証版0.4.7、`uv.lock`で固定）
- 生成設定: 24ステップ、sway sampling、sway係数−1.0
- 音声: `asuka` = このプロジェクトの`assets/asuka.wav`

Tomokoの`v1/server/shared/inference/tts/irodori_mlx.py`で使われた構成を採用しています。
短い文節へ強制分割せず、モデルの発話時間予測を使います。

## Emacs

`M-x my-read-set-japanese-speech-backend`で`irodori`を選択し、本文で`s`を押します。

閉じかぎ括弧`」`はEmacs側で音声送信前に除去します。表示本文は変更せず、
先読みにも同じ処理を適用します。除去後に空になる区間は送信せず、
連続読み上げでは音声の完了を待たずに次へ進みます。
`M-x my-read-change-japanese-speed`は0.5〜2.0倍を受け付けます。
Apple音声へ戻すときは同じバックエンド選択で`macos`、Kokoroは`kokoro`を選びます。
英語の音声と速度には影響しません。

再起動後もIrodoriを既定にする場合:

```elisp
(setq my/read-japanese-speech-backend 'irodori
      my/read-japanese-irodori-speed 1.0)
```

日本語Irodoriの速度は`my/read-japanese-irodori-speed`で独立管理します。
既定値は1.0です。モデルには逆数の`duration_scale`を渡します。
Appleの毎分語数やKokoroの倍率は保持します。

## 動作経路と確認

Emacs → 既存のローカルAPI（8000番）→ MLXでIrodori生成 →
WAV → 既存のネイティブ再生・ハイライト・先読み処理。
KokoroとIrodoriのモデルロード・推論は同じ専用スレッドで直列化します。
Irodoriモデルは初回リクエストで読み込み、以後再利用します。

このMacでは「こんにちは。今日は本を読みます。」の3.88秒の音声生成に、
キャッシュ済みモデルの読込を含む初回が約14秒、2回目が約4.1秒でした。
長文や速度設定によって待ち時間は変わります。モデル内部のストリーミングは
使わず、文単位の生成と既存の先読み処理を利用します。

`assets/asuka.wav`がない場合は生成を中止します。
エラーはEmacsの`*kokoro-server*`バッファで確認できます。

```sh
.venv/bin/python -m unittest discover -s test -p test_irodori_backend.py
make my-read-k-ert
git check-ignore -v assets/asuka.wav
```

資料:
- [mlx-audio](https://github.com/Blaizzy/mlx-audio)
- [Irodori MLXモデル](https://huggingface.co/mlx-community/Irodori-TTS-500M-v3-8bit)

# 次の機能計画：Windows標準音声による音声生成

調査日: 2026-09-18  
記録先ブランチ: `codex/remote-audio-playback`

## 結論

自宅のWindows 11へSSH接続し、Windows標準の日本語音声をWAVへ出力できた。
ユーザーによる試聴で通常速度の品質は問題ないとの評価を得た。
WinRTのMicrosoft Ayumiでは2倍速・3倍速の生成にも成功した。

今回の短文では、通常速度で約13〜15秒の音声を約0.05〜0.15秒で生成できた。
音声生成サーバーのWindowsバックエンドとして、まずWinRTを採用する方針が有力。
クラウドAPIや大型の音声生成モデルを使わず、手元の端末へWAVを配信する構成を目指す。

この調査で実施したのは、独立したPowerShellサンプルによる生成・SSH経由の回収まで。
以下の統合項目は今後の計画であり、Windows音声生成バックエンドとしての組み込み完了を意味しない。
同じブランチで進行中の再生サーバー実装とは分けて、この文書に調査結果を記録する。

## 検証環境と実施内容

| 項目 | 確認結果 |
| --- | --- |
| サーバーOS | Windows 11 |
| コンピューター名 | `DELL2025` |
| SSH接続 | `modev@192.168.11.112` |
| 認証 | Mac側の `~/.ssh/id_rsa` |
| 実行環境 | Windows PowerShell `5.1.26100.9444` |
| 操作 | Macでサンプル作成 → SCP転送 → SSHで実行 → WAVをSCPで回収 |
| GUI操作 | 音声生成の実行には不要だった |
| 追加音声・モデル | 今回の検証ではインストールしていない。既存の音声を使用 |

最初は接続先のホスト鍵と保存済みの鍵が一致せずSSHが停止した。
ユーザーが `known_hosts` をメンテナンスした後、通常のホスト鍵検証を維持して接続に成功した。
ホスト鍵チェックを無効にする運用は採用しない。

サンプルはプロセス単位の `-ExecutionPolicy Bypass` を指定して実行した。
Windows全体の実行ポリシー、音声設定、サービス設定は変更していない。

## 音声APIと列挙結果

### System.Speech / SAPI

`System.Speech.Synthesis.SpeechSynthesizer` を使用する。
`GetInstalledVoices()` で列挙し、`SelectVoice()` で選択する。
`SetOutputToWaveFile()` と `Speak()` で、スピーカーを鳴らさずWAVへ出力できた。

実機で列挙された音声:

- 日本語: `Microsoft Haruka Desktop`
- 英語: `Microsoft Zira Desktop`（今回、英語の音声生成は未検証）

### WinRT

`Windows.Media.SpeechSynthesis.SpeechSynthesizer` を使用する。
`AllVoices` から選び、`SynthesizeTextToStreamAsync()` の出力をファイルへ保存する。
PowerShellからは `System.Runtime.WindowsRuntime` の `AsTask` を介して非同期処理を待つ。

実機で列挙・生成できた音声:

- `Microsoft Ayumi`
- `Microsoft Haruka`
- `Microsoft Ichiro`

SAPIとWinRTで見える音声一覧は同一ではなかった。
設定画面で選べる声やナレーターの「自然な音声」を、これらのAPIから無条件に使えるとは扱わない。
実行アカウントで列挙できた音声を基準にする。

## 通常速度の実測

すべて同じ日本語文章を使用した。

> こんにちは。これは、ウィンドウズ標準の音声合成による日本語の読み上げテストです。自宅のサーバーで音声を生成し、手元の端末で再生します。

| API | 音声 | 音声の長さ | 生成時間 | WAV形式 |
| --- | --- | ---: | ---: | --- |
| SAPI | Haruka Desktop | 13.09秒 | 0.112秒 | 22,050Hz / mono / PCM16 |
| WinRT | Ayumi | 14.94秒 | 0.147秒 | 16,000Hz / mono / PCM16 |
| WinRT | Haruka | 13.10秒 | 0.051秒 | 16,000Hz / mono / PCM16 |
| WinRT | Ichiro | 14.51秒 | 0.097秒 | 16,000Hz / mono / PCM16 |

生成時間はサンプル内で計測した合成・ファイル出力の所要時間。
SSH接続、PowerShell起動、音声オブジェクトの初期化、WAVのMacへの転送時間は含まない。
各条件1回の短文テストであり、長文・並列処理・長時間稼働の性能保証ではない。

回収したWAVはMacでヘッダー、フレーム数、データ長、非無音のサンプルを確認した。
ユーザーから通常速度の品質について「問題ない」との評価を得た。

## 高速読み上げ

WinRTでは合成前に倍率を指定できる。

```powershell
$synth.Options.SpeakingRate = 2.0  # 2倍速。3倍速は3.0
```

公式仕様の範囲は0.5〜6.0倍。今回はAyumiの1.0・2.0・3.0を実測した。
4〜6倍や、他の声での高速生成は未検証。

| Ayumiの設定 | 音声の長さ | 生成時間 | ファイル名 |
| --- | ---: | ---: | --- |
| 通常速度 | 14.94秒 | 0.147秒 | `winrt-Microsoft_Ayumi.wav` |
| 2倍速 | 7.495秒 | 0.095秒 | `winrt-Microsoft_Ayumi-2x.wav` |
| 3倍速 | 4.995秒 | 0.102秒 | `winrt-Microsoft_Ayumi-3x.wav` |

生成後の再生速度変更ではなく、WinRTへ速度を指定して生成したWAVである。
2倍速・3倍速ともMacへ回収し、形式とデータ長を検証済み。
高速音声の品質については、まだユーザーの評価を記録していない。

SAPIにも `Rate` プロパティがあるが、範囲は−10〜＋10の段階指定で、倍率ではない。
SAPIの高速設定は今回未検証。
macOSの語/分とWinRTの倍率は直接対応しないため、同じ数値を使い回さない。

## サンプルと成果物の保存場所

Mac側の保存先（この調査を実施した端末のローカルパス）:

```text
/Users/seijiro/Downloads/windows-speech-sample-20260918-BupIgM/
  windows-speech-sample.ps1       # SAPI・WinRTの音声列挙と通常速度生成
  ayumi-speed-sample.ps1          # WinRT Ayumiの2倍速・3倍速生成
  verified-audio.json            # 通常速度WAVの形式・長さの検証結果
  output/
    manifest.json                # 通常速度の音声一覧・生成時間・エラー
    sapi-Microsoft_Haruka_Desktop.wav
    winrt-Microsoft_Ayumi.wav
    winrt-Microsoft_Haruka.wav
    winrt-Microsoft_Ichiro.wav
  ayumi-2x/
    manifest.json
    winrt-Microsoft_Ayumi-2x.wav
  ayumi-3x/
    manifest.json
    winrt-Microsoft_Ayumi-3x.wav
```

Windows側にもスクリプトと生成物を残している:

```text
C:\Users\modev\windows-speech-sample-20260918-BupIgM\
```

これらのサンプル・WAVはリポジトリには追加していない。
Windows側での再実行例:

```powershell
cd C:\Users\modev\windows-speech-sample-20260918-BupIgM
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\ayumi-speed-sample.ps1 -SpeakingRate 2 -OutputDirectory .\ayumi-2x
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\ayumi-speed-sample.ps1 -SpeakingRate 3 -OutputDirectory .\ayumi-3x
```

## 次の実装方針

目指す構成:

```text
Emacs ──本文・言語・声・速度──▶ 音声生成サーバー（Windows 11 / WinRT）
                                    │
                               順序付きWAV
                                    ▼
Emacs ◀──再生開始・完了・エラー── 再生サーバー（手元の端末）
  └──────────停止・キュー破棄────────▶┘
```

### 1. Windows用の音声生成バックエンドを追加する

- API上のバックエンド名は、例えば `windows` とし、内部実装にWinRTを使う。
- 初期の日本語音声は今回検証した `Microsoft Ayumi` を候補にする。
- テキストはJSONまたは標準入力で渡し、PowerShellコマンド文字列へ直接埋め込まない。
- 常駐プロセスで合成要求を処理し、文ごとのPowerShell起動を避ける。
- 音声の一覧、対応言語、速度範囲を取得できるようにする。
- 必要なWindows依存だけで導入できる構成にし、macOS専用のMLX依存を要求しない。
- Windows用バックエンドのWAVも、既存配信仕様の24kHz・mono・PCM16へ正規化する。

### 2. Emacsの声・速度設定を接続する

- 日本語バックエンド・声・速度倍率をリクエストごとに送る。
- WinRT用の速度範囲を扱い、3倍速が共通の「最大2倍」等の検証で拒否されないようにする。
- 他バックエンドの速度範囲は維持し、バックエンドごとに検証する。
- macOSの語/分とWinRTの倍率は別設定として保持する。
- 声・速度・生成先をキャッシュキーへ反映し、変更後に古い先読み音声を再生しない。

### 3. 再生サーバーと連携する

- 音声生成サーバーから手元の再生サーバーへWAVを送る。
- 読み上げセッションID・チャンクID・連番で、順序とキャンセルを管理する。
- 停止・読み直し後に遅れて届く旧セッションの音声は破棄する。
- Emacsが受け取る完了通知は、生成完了・受信完了ではなく実際の再生完了とする。
- 次の文の生成は再生完了を待たずに進め、受信・再生キューには上限を設ける。
- 接続先が異なる構成では、生成サーバーから再生サーバーへ到達できる経路も確認する。
- LAN・SSHトンネルを使う場合の接続先設定と認証を文書化する。

### 4. Windowsの常駐運用を検証する

- 今回成功したのは、ユーザー `modev` のSSHセッション内での実行。
- Windowsサービスやタスクスケジューラーでの起動は未検証。
- 再起動後の自動起動、ログアウト状態、実行アカウントごとの音声列挙を確認する。
- 生成のみの運用で音声出力デバイスに依存しないことを、常駐方式でも確認する。

## 次の受け入れ確認

1. EmacsからAyumiの通常・2倍・3倍を指定し、Windows生成音声を手元で再生できる。
2. 再生開始・完了に合わせて、ハイライト・読書位置・ページ送りが動く。
3. 停止、言語・速度変更、読み直し、ネットワーク切断で、古い音声を再生しない。
4. 長文を連続再生し、先読みが維持され、文の重複・欠落・順序逆転がない。
5. Windows再起動後の常駐起動と、日本語音声の利用可否を確認する。
6. 既存のmacOS/Kokoro/Irodoriによる生成とローカル再生を壊していない。

## 公式資料

- [Windowsで利用できる言語と音声](https://support.microsoft.com/ja-jp/accessibility/windows/narrator/appendix-a-supported-languages-and-voices)
- [WinRT SpeechSynthesizer](https://learn.microsoft.com/en-us/uwp/api/windows.media.speechsynthesis.speechsynthesizer)
- [WinRT SpeakingRate：0.5〜6.0倍](https://learn.microsoft.com/en-us/uwp/api/windows.media.speechsynthesis.speechsynthesizeroptions.speakingrate)
- [System.Speech SetOutputToWaveFile](https://learn.microsoft.com/en-us/dotnet/api/system.speech.synthesis.speechsynthesizer.setoutputtowavefile)
- [System.Speech Rate：−10〜＋10](https://learn.microsoft.com/en-us/dotnet/api/system.speech.synthesis.speechsynthesizer.rate)

# Readerのテスト

`make reader-ert`（`make my-read-k-ert`）はReader ERT全体を実行します。
旧 `my-read-k-tests.el` の206件は下記11ファイルへ移し、旧ファイルは互換ローダーとして残しています。
共通fixtureは `reader-test-helpers.el`、source優先のロード設定は `reader-test-source.el` です。

| `READER_SUITE` | 対象 |
| --- | --- |
| speech | 合成・先読み・連続読み上げ |
| epub | EPUB文境界・章送り |
| pdf | PDF抽出・表示・読み上げ |
| eww | Web・数式 |
| kindle | Kindle本文・操作 |
| ui | frame・window・tab・キー |
| position | 読書位置の保存・復元 |
| translation | 翻訳 |
| lookup | 辞書 |
| notes | org-noter |
| vocabulary | 語彙capture |
| speech-queue | queue API・取消・古いcallback・音声長 |
| diagnose | 診断の副作用防止・応答・表示 |
| document | 文書APIとlifecycle |
| layout | pane配置 |

```sh
make reader-ert READER_SUITE=speech
make reader-ert READER_SUITE=speech-queue
make reader-check
make speech-http-test speech-playback-test
make speech-native-test  # macOS実機device：無音PCMで検証
```

HTTP・リモート再生のERTとPythonテストは、それぞれの専用targetで実行します。
新規Reader機能のテストファイルを追加したら、Makefileの全体実行対象にも登録してください。

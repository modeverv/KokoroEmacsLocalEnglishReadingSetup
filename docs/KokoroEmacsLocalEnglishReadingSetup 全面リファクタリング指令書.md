# KokoroEmacsLocalEnglishReadingSetup 全面リファクタリング指令書

対象リポジトリ:

https://github.com/modeverv/KokoroEmacsLocalEnglishReadingSetup

## 0. ミッション

このリポジトリ全体を詳細に解析したうえで、既存のユーザー体験・公開操作・機能を可能な限り維持しながら、今後長期間安全に拡張できるモジュール構造へ全面的にリファクタリングしてください。

今回の仕事は「分析」「提案」「一部のファイル分割」ではありません。

**解析 → 設計 → 実装 → 移行 → テスト → 不具合修正 → 不要コード除去 → ドキュメント更新 → 最終検証**

までを一続きのタスクとして実施し、リファクタリングを完了させてください。

途中で人間へ設計判断を投げ返さず、コード・テスト・既存仕様から合理的な判断を行って最後まで進めてください。

ただし、既存仕様を意図的に変更しなければ解決できない重大な矛盾が発見された場合は、最も後方互換性の高い解決策を選択し、最終報告へ記録してください。

---

# 1. このプロジェクトの本質

このプロジェクトは単純なEmacs TTS設定ではありません。

PDF / EPUB / EWW / Markdown / Org / TXT / Kindle.app など異なる媒体に対して、

- 文単位移動
- 文単位読み上げ
- 連続読み上げ
- 読み上げ位置追従
- ハイライト
- 翻訳
- Lookup辞書
- 語彙保存
- org-noter
- 読書位置保存・復元
- TTS backend切り替え
- 音声先読み
- HTTP音声生成
- remote playback
- 再生完了との同期

を統合するReader環境です。

設計上の中心概念は「特定のPDF ReaderやKindle連携」ではなく、

**Document → Sentence → Reading State → Speech / Translation / Notes**

という読書抽象モデルであるべきです。

この原則をリファクタリング全体の中心にしてください。

---

# 2. 最重要目標

今回のリファクタリングの最終目標は、

**巨大な `my-read.el` や `english-reading-mode.el` に責務が集中している状態から脱却し、`my-read` 本体を薄いオーケストレーターへ変えること**

です。

最終的には少なくとも概念上、以下の責務が明確に分離されている必要があります。

```text
my-read
│
├── Core / Reading State
│
├── UI / Frame / Window Layout
│
├── Document Abstraction
│   ├── PDF
│   ├── EPUB
│   ├── EWW
│   ├── TEXT
│   └── Kindle
│
├── Speech
│   ├── backend selection
│   ├── synthesis
│   ├── HTTP transport
│   ├── prefetch
│   └── playback
│
├── Translation
│
├── Lookup
│
├── Notes / org-noter
│
├── Vocabulary
│
├── Position / Persistence
│
└── Supporting integrations
```

この図をそのまま機械的にファイル名へ変換する必要はありません。

実コードを解析し、依存関係が最も自然になる構造を選択してください。

---

# 3. 絶対に守る原則

## 3.1 外部動作を壊さない

既存ユーザーから見える挙動は原則維持してください。

特に以下を守ってください。

- `M-x my-read`
- `M-x my-read-end`
- 現在利用されている主要interactive command
- 現在のキーバインド
- PDF / EPUB / EWW / TEXT / Kindleの操作
- org-noter連携
- Lookup
- 翻訳
- 語彙保存
- 読書位置保存・復元
- TTS backend切り替え
- 日本語・英語速度変更
- HTTP speech transport
- remote playback
- prefetch
- stop / cancel
- playback完了後の文送り

内部実装の整理のために互換ラッパーが必要なら残してください。

---

## 3.2 リファクタと機能追加を混ぜない

新機能は原則追加しないでください。

今回の目的は、

- 構造改善
- 責務分離
- 依存方向整理
- 状態管理整理
- API明確化
- テスト容易性向上
- 重複削減
- dead code除去
- ドキュメント整備

です。

ただし、リファクタリング中に発見された明らかな既存バグで、修正しなければテストまたは構造整理が成立しないものは修正して構いません。

その場合は最終報告に明記してください。

---

## 3.3 テストを安全網として使う

既存テストを最大限利用してください。

最初に現在のテスト結果を記録してください。

その後、大きな変更単位ごとにテストを実行してください。

単に最後に1回だけ実行するのではなく、

```text
baseline
↓
module extraction
↓
test
↓
next extraction
↓
test
↓
...
↓
full test
```

という形で進めてください。

---

# 4. 最初に必ず行う解析

コードを変更する前に、リポジトリ全体を詳細に解析してください。

ただし解析結果を提出して作業終了してはいけません。

解析は後続の実装のための内部工程です。

少なくとも以下を把握してください。

## 4.1 責務マップ

各主要ファイルについて、

- 何を担当しているか
- 本来どこへ属する責務か
- 他モジュールとの依存
- public API
- internal API

を整理してください。

特に重点的に調査する対象:

```text
my-read.el
english-reading-mode.el
my-read-k.el
my-read-k2.el
my-read-org-noter.el
my-read-eww-math.el
kokoro-reader.el
english-reader-tts.el
reader-http-speech.el
reader-http-speech-transport.el
reader-http-playback.el
speech_http/
speech-http-app/
playback-app/
macos-speech-bridge/
test/
```

---

# 5. Global State調査

Emacs Lisp側に存在する、

- `defvar`
- `defcustom`
- buffer-local variable
- timer
- process
- sentinel
- filter
- callback
- advice
- hook
- overlay
- current buffer依存状態
- current window依存状態
- global minor mode

を洗い出してください。

特に、

**「この変数はReader全体の状態なのか、Documentごとの状態なのか、Speech sessionの状態なのか」**

を明確にしてください。

不要にglobalな状態は可能な範囲で局所化してください。

ただし互換性を壊す大規模な状態オブジェクト導入は慎重に行ってください。

---

# 6. Document abstractionを正式化する

今回のリファクタリングで最も重要なポイントの一つです。

現在PDF / EPUB / EWW / TEXT / Kindleに散在している、

- current sentence取得
- next sentence
- previous sentence
- sentence position
- highlight
- scroll / recenter
- page change
- location取得
- location restore
- current title
- current source
- org-noter位置
- close
- refresh

などの操作を分析してください。

可能な限り共通インターフェースを定義してください。

例えば概念としては、

```elisp
(my-read-document-current-sentence)
(my-read-document-next-sentence)
(my-read-document-previous-sentence)
(my-read-document-current-location)
(my-read-document-restore-location ...)
(my-read-document-highlight ...)
```

のようなAPIが考えられます。

ただし名前や方式は既存コードに最も適した設計を選択してください。

`cl-defgeneric` / dispatch table / backend property / protocol的関数群など、最適な方式を判断してください。

目的は、

```text
if PDF ...
else if EPUB ...
else if Kindle ...
```

という条件分岐がCore全体へ拡散するのを防ぐことです。

---

# 7. Coreを薄くする

最終的な`my-read.el`は、

- package entry point
- require
-主要設定
- subsystem orchestration
- 起動 / 終了

を中心とする薄いファイルにしてください。

以下のようなロジックが大量に残らない状態を目標にしてください。

- PDF固有実装
- EPUB固有実装
- Kindle固有実装
- EWW固有実装
- translation実装
- Lookup実装
- persistence実装
- org-noter詳細実装
- speech transport詳細実装

ただし無意味な細分化は避けてください。

100行未満のファイルを大量生成すること自体を目的にしてはいけません。

**「変更理由が同じコードを同じモジュールへまとめる」**
ことを基準にしてください。

---

# 8. english-reading-mode.elの整理

`english-reading-mode.el`も巨大化しているため詳細に解析してください。

少なくとも、

- sentence navigation
- speech state
- continuous reading
- highlight
- prefetch
- player lifecycle
- document integration

の境界を見つけてください。

Document abstractionとの責務重複があれば整理してください。

`english-reading-mode`が汎用的なSentence Reading engineとして成立するなら、その方向を明確化してください。

逆にmy-read固有ロジックが入り込んでいる場合は分離してください。

---

# 9. Speech subsystemは慎重に扱う

Speech関連は現在かなり高度な非同期システムになっています。

以下の性質を絶対に壊さないでください。

```text
text
↓
synthesis
↓
chunk delivery
↓
playback queue
↓
actual audio playback
↓
finished
↓
reader progression
```

特に次を維持してください。

- prefetch
- ordered chunks
- session identity
- cancellation
- stale session rejection
- stop後の古い音声破棄
- duplicate拒否
- out-of-order対策
- actual playback finished通知
- playback server分離
- synthesis server分離
- local playback fallbackまたは既存挙動
- backendごとのvoice/rate

Speech subsystemは、明確な改善がない限り無理に全面書き換えしないでください。

既に責務分離が良好な部分はその構造を尊重してください。

今回の主目的はReader側との境界を明確化することです。

---

# 10. Callback raceを調査する

以下のようなrace conditionの可能性を重点的に確認してください。

- stop直後のplayer callback
- old session callback
- timer callback
- prefetch completion
- HTTP completion
- buffer kill後のcallback
- frame delete後のcallback
- document switch後のold highlight
- Kindle page cache callback
- playback server disconnect

各callbackでは必要に応じて、

- session id
- generation id
- buffer live check
- process live check
- current document identity

を確認してください。

既に対策されている場合は重複実装しないでください。

---

# 11. Dependency directionを整理する

依存方向をなるべく一方向にしてください。

望ましい概念:

```text
UI
 ↓
Core
 ↓
Document abstraction

Core
 ↓
Speech API

Core
 ↓
Translation API

Core
 ↓
Persistence API
```

避けたい構造:

```text
PDF → UI → Speech → PDF

Translation → my-read.el → Lookup → Translation

Document backend → unrelated backend
```

循環requireがあれば可能な限り解消してください。

---

# 12. Public / Private APIを明確にする

Emacs Lispの命名を整理してください。

内部関数は可能な範囲で、

```text
package--internal-function
```

形式にしてください。

ユーザー向けinteractive commandや設定変数は安易にrenameしないでください。

renameが有益な場合も、

- alias
- obsolete alias
- compatibility wrapper

などを使って後方互換性を確保してください。

---

# 13. Error handlingを整理する

現在の、

- `message`
- `user-error`
- `condition-case`
- silent ignore
- process sentinel error
- HTTP error buffer

の使われ方を確認してください。

ユーザー操作で回復可能なエラーと内部バグを区別してください。

特にremote speech/playbackについて、

- server unavailable
- timeout
- auth failure
- stale session
- malformed response
- playback disconnect

を既存仕様を壊さず整理してください。

---

# 14. Lifecycleを明確にする

Reader全体のライフサイクルを明確にしてください。

```text
start
↓
frame creation
↓
subsystem initialization
↓
document open
↓
reading
↓
document change
↓
stop speech
↓
close document
↓
reader shutdown
```

終了時には可能な範囲で、

- timer
- process
- overlay
- hook
- advice
- temporary buffer
- network connection
- playback session

が正しく解放されるようにしてください。

---

# 15. Dead codeと重複コードを除去する

リファクタ後に、

- 使われていない関数
- 旧実装
- obsolete compatibility code
- 到達不能コード
- duplicated helper
- 同じ意味の複数関数

を調査してください。

安全に削除できるものは削除してください。

ただしGit historyにあるからという理由だけで、現在ユーザーが利用している可能性のあるpublic commandを削除してはいけません。

---

# 16. ファイル構成

最終ファイル構成は実コードに基づいて判断してください。

以下はあくまで参考です。

```text
my-read.el
my-read-core.el
my-read-ui.el
my-read-document.el

my-read-document-pdf.el
my-read-document-epub.el
my-read-document-eww.el
my-read-document-text.el
my-read-document-kindle.el

my-read-position.el
my-read-translation.el
my-read-lookup.el
my-read-vocabulary.el
my-read-noter.el

english-reading-mode.el
english-reading-speech.el

reader-http-speech.el
reader-http-speech-transport.el
reader-http-playback.el
```

既存ファイルの方が適切なら維持してください。

重要なのは名前ではなく責務境界です。

---

# 17. テストを追加する

既存テストを維持するとともに、リファクタによって新たに明確になった境界について必要なテストを追加してください。

特に、

## Document abstraction

- current sentence
- next / previous
- end of document
- location restore
- backend dispatch

## Reading state

- start
- stop
- resume
- continuous progression
- document switch

## Speech

- stale callback ignored
- cancellation
- playback finished
- prefetch
- backend change
- speed change

## Persistence

- save
- restore
- missing state
- corrupted state

について不足している部分を補ってください。

---

# 18. テストしにくいコードを改善する

外部プロセス、HTTP、Kindle Accessibility、PDF Toolsなどは実環境依存があります。

実環境依存部分とpure logicを分離し、

- fake
- stub
- function injection
- process wrapper

などを使ってテスト可能性を高めてください。

ただし過度なDI frameworkは導入しないでください。

Emacs Lispらしいシンプルな仕組みを優先してください。

---

# 19. 現在失敗しているテストの扱い

baseline時点で失敗している既知テストがある場合は、

1. 本当に既知の環境依存失敗なのか
2. 実際のバグなのか
3. staleなテストなのか

を調査してください。

可能なら修正してください。

ただし実機AccessibilityなどCIで成立しない条件を無理に成功扱いしてはいけません。

skipすべきテストなら理由を明確にしてskipしてください。

---

# 20. Elisp品質

変更したEmacs Lispについて、

- byte compile
- warnings
- lexical scope
- free variable
- obsolete API
- docstring
- interactive spec

を確認してください。

新しいbyte compile warningを残さないでください。

---

# 21. Python / Swift側

今回の中心はReaderアーキテクチャですが、Python / Swift側にも明白な構造問題がある場合は整理して構いません。

ただし不要な全面書き換えは禁止します。

優先順位は、

1. Reader architecture
2. module boundaries
3. Speech interface
4. peripheral implementation cleanup

です。

---

# 22. READMEと設計文書を更新する

リファクタ完了後、READMEを現実の構造に合わせて更新してください。

さらに、

```text
docs/architecture.md
```

のような設計文書を作成してください。

最低限、以下を記載してください。

- 全体構成
- Reading Core
- Document abstraction
- Document backend
- Speech architecture
- Remote playback
- Translation
- org-noter
- Persistence
- Lifecycle
- module dependency

Mermaidを利用できるなら依存図も作成してください。

---

# 23. DEVELOPMENT.mdを追加する

今後の変更者向けに、必要なら

```text
DEVELOPMENT.md
```

を追加してください。

内容:

- 新しいDocument backendを追加する方法
- 新しいSpeech backendを追加する方法
- interactive commandを追加する際のルール
- stateを置く場所
- test実行方法
- architecture上避けるべきこと

---

# 24. コメントの方針

自明なコードへ大量の説明コメントを追加しないでください。

コメントは、

- race対策
- macOS固有制約
- Kindle Accessibility制約
- PDF Tools peculiar behavior
- non-obvious lifecycle
- protocol invariant

など、「なぜそうなっているのか」がコードだけでは分かりにくい場所へ限定してください。

---

# 25. リファクタリングの進め方

内部的には段階的に進めてください。

推奨順序:

```text
1. baseline tests
2. architecture inventory
3. low-risk helpers
4. persistence
5. translation / lookup / vocabulary
6. UI
7. document abstraction
8. individual document backend extraction
9. reading core
10. english-reading-mode cleanup
11. speech boundary cleanup
12. dead code removal
13. complete tests
14. docs
15. final verification
```

ただし実際の依存関係からより安全な順番が見つかった場合は変更してください。

---

# 26. Gitの扱い

可能なら意味のある単位でcommitしてください。

例えば、

```text
refactor: extract reader persistence
refactor: introduce document protocol
refactor: isolate PDF backend
refactor: isolate EPUB backend
refactor: isolate Kindle backend
refactor: simplify reader core
test: cover document protocol
docs: describe reader architecture
```

ただしcommit作業そのものが環境上許可されていない場合は無理に行わなくて構いません。

---

# 27. 禁止事項

以下は禁止します。

## 禁止1

分析レポートを書いただけで終了する。

## 禁止2

TODOを大量に残して「将来対応」とする。

## 禁止3

新構造と旧構造を両方残して実質コード量を倍増させる。

移行完了後は不要な旧実装を除去してください。

## 禁止4

テストを削除・弱体化して通す。

## 禁止5

テスト失敗を無条件にskipへ変更する。

## 禁止6

ユーザー向け機能を「整理のため」という理由で削除する。

## 禁止7

Speechの非同期性を単純化して機能退行させる。

## 禁止8

巨大な万能State objectへすべてを詰め込む。

## 禁止9

細かすぎるファイル分割を目的化する。

## 禁止10

途中で人間へ、

「どちらの設計にしますか？」

「続けますか？」

「この方針でよいですか？」

と確認して作業停止する。

既存コードとテストから合理的な方を選んでください。

---

# 28. 完了条件

以下をすべて満たすまで作業を続けてください。

### Architecture

- `my-read.el`の責務が大幅に縮小されている
- Document固有処理がCoreから分離されている
- Speech subsystemとの境界が明確
- Persistence / Translation / Lookup / Notesが適切に分離
- module dependencyが理解可能

### Compatibility

- 主要commandが維持されている
- key bindingが維持されている
- PDFが利用可能
- EPUBが利用可能
- EWWが利用可能
- TEXTが利用可能
- Kindle連携が利用可能な構造を維持
- org-noter連携維持
- translation維持
- Lookup維持
- vocabulary維持
- TTS維持
- HTTP speech維持
- remote playback維持

### Testing

- baselineと比較してregressionがない
- 新構造に必要なテストが追加されている
- byte compileで重大なwarningがない
- test suiteを可能な限り成功させる

### Cleanup

- dead code除去
- duplicate reduction
- obsolete internal helpers整理
- 不要なcompatibility layer除去

### Documentation

- README更新
- architecture document追加
- developer向け情報更新

---

# 29. 数値的な成功条件

ファイル行数そのものを目的にはしませんが、結果として以下が期待されます。

現在巨大な、

```text
my-read.el
english-reading-mode.el
```

について、責務の大部分が適切なモジュールへ移動していること。

`my-read.el`が依然として巨大であれば、

**本当にそこへ置くべきコードなのか再検討してください。**

ただし行数を減らすためだけの意味のないwrapper分割は禁止します。

---

# 30. 最終レビューを自分で実施する

実装完了後、自分自身でコードレビューしてください。

以下の観点を再確認してください。

```text
Can a new document backend be added without editing many unrelated files?

Can a new speech backend be added without changing the Reader core?

Can translation be changed without touching PDF/EPUB/Kindle code?

Can persistence change without touching speech code?

Can a speech callback from an old session corrupt current reading state?

Does killing a Reader clean up its resources?

Does the module structure explain itself?
```

どれかが明確にNOなら、可能な範囲で追加改善してください。

---

# 31. 最終テスト

完了時に利用可能なテストをすべて実行してください。

可能なら以下を含めてください。

```text
ERT tests
speech HTTP tests
playback tests
Python tests
build checks
byte compilation
```

OS / GUI / Accessibility / audio deviceなどの理由で実行不能なものは、

```text
NOT RUN
```

として理由を書いてください。

「未実行」と「失敗」を混同しないでください。

---

# 32. 最終報告

最後に簡潔だが具体的な報告を作成してください。

以下を含めてください。

## Architecture changes

何をどう分離したか。

## Important files

主要ファイルと責務。

## Compatibility

維持した公開API・操作。

## Bugs fixed

リファクタ中に修正した既存バグ。

## Tests

```text
Before:
passed:
failed:
skipped:

After:
passed:
failed:
skipped:
```

## Remaining limitations

実機依存など今回検証できなかったもの。

## Future extension points

新Document backend、新Speech backendなどをどこへ追加すればよいか。

---

# 33. 最終的に目指す状態

このプロジェクトを初めて読む熟練Emacs Lisp開発者が、

```text
my-read.el
↓
core
↓
document abstraction
↓
backend
```

を追うことで全体構造を短時間で理解できること。

そして新しい開発者が、

```text
新しいReaderを追加する
新しいTTS backendを追加する
新しいtranslation backendを追加する
```

際に、既存の巨大ファイルへ条件分岐を追加していく必要がない状態にしてください。

---

# 34. 最終指示

このタスクでは、リファクタリング計画を提示して終了してはいけません。

リポジトリを調査し、自ら設計を決定し、コードを変更し、必要なテストを追加し、すべての可能なテストを実行し、問題があれば修正し、ドキュメントを更新してください。

途中で規模が大きいと判断しても、可能な範囲だけ行って終了するのではなく、**リポジトリ全体のリファクタリング完了をゴールとして継続してください。**

既存ユーザー体験を守りながら、

**「機能を追加し続けられるReaderシステム」**

へ変えてください。

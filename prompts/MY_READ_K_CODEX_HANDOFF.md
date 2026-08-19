# ===== README =====

# my-read-k Codex implementation pack

## 目的

既存の Emacs `my-read` の UI / Google Translate / 単語 lookup / 読書補助機能をできるだけそのまま再利用し、
Kindle Web Reader を Chrome 上で動かしたまま、表示中の英語本文を Chrome DevTools Protocol (CDP) で
スクリーンショット取得 → Apple Vision OCR → Emacs 中央ペインへ通常の文字列として展開する `my-read-k`
を実装する。

このパックは Codex に渡すための実装指示一式である。

## 最初に Codex に渡すもの

Codex にはまず `CODEX_TASK.md` を読ませる。その後、必要に応じて以下を参照させる。

- `docs/ARCHITECTURE.md`
- `docs/EMACS_UI_SPEC.md`
- `docs/BRIDGE_PROTOCOL.md`
- `docs/IMPLEMENTATION_PLAN.md`
- `docs/TEST_PLAN.md`
- `docs/SCOPE_AND_GUARDRAILS.md`
- `reference/my-read-current-ui.png`

## 重要な前提

- Kindle Web Reader の本文は DOM から取得しない。
- OCR が本文取得の正規ルートである。
- Kindle の認証・DRM・ページ描画は Kindle Web Reader / Chrome に任せる。
- Chrome は CDP の remote debugging port で制御する。
- OCR は macOS の Apple Vision を使う。
- Emacs 側では OCR 済み本文を普通の text buffer として扱い、既存の `my-read` の翻訳・lookup を再利用する。
- `xwidget` は前提にしない。
- 既存 `my-read.el` を壊さない。必要な共通化は最小限の refactor とする。
- ページ本文を本一冊分バッチ抽出するツールにはしない。表示中ページ中心の読書支援として作る。
- 既存 `my-read` の `j/k`（段落移動 + Kokoro 読み上げ）をそのまま主操作にする。
- `j/k` で current OCR buffer の次/前段落がなくなった時だけ、自動で Kindle の次/前ページを取得する。
- ユーザーに Kindle のページ境界を意識させず、一続きの Emacs text buffer のような読書体験を目指す。

## 想定操作

```text
M-x my-read-k

→ Chrome の Kindle Web Reader target を attach
→ 現在ページ screenshot
→ Apple Vision OCR
→ my-read に近い UI を構築
→ 中央に OCR 英文を表示
→ 既存の Google Translate / lookup がそのまま動く

M-x my-read-k-next-page
→ Kindle の次ページ
→ 描画安定待ち
→ OCR
→ 中央 buffer を置換

M-x my-read-k-prev-page
→ 前ページ
→ OCR
→ 中央 buffer を置換

M-x my-read-k-refresh
→ 現在ページを再 OCR
```

## 完了条件の短縮版

1. `M-x my-read-k` で Kindle target に接続できる。
2. 現在表示ページを OCR し、中央ペインに英語テキストを出せる。
3. 既存 my-read の Google Translate がその英語テキストに対して動く。
4. 既存 lookup がカーソル下の単語に対して動く。
5. Emacs から次ページ / 前ページを制御できる。
6. ページ送り直後のアニメーション途中を OCR しない。
7. Chrome / OCR / bridge 障害時に Emacs が固まらない。
8. `my-read` 自体の既存挙動を壊さない。

# ===== MASTER TASK =====

# Codex master task: `my-read-k`

あなたは既存の Emacs 読書環境 `my-read` に Kindle Web Reader OCR backend を追加する。

## 0. 最重要ルール

**いきなり実装を始めず、まず既存コードを調査すること。**

このタスクの価値は「新しい Kindle reader をゼロから作る」ことではなく、
既存 `my-read` の UI、翻訳、lookup、TTS 等を壊さず再利用することにある。

推測した関数名を先にコードへ書かない。
リポジトリ内の実際の symbol / hook / keymap / buffer 構成を確認してから接続点を決める。

最初に最低限、次のような探索を行うこと。

```sh
rg -n "my-read|Reading Translation|Google Translate|lookup|Lookup|kokoro|Kokoro|translate|translation" .
rg -n "\(defun|\(define-minor-mode|\(define-derived-mode|\(defvar|\(defcustom" --glob='*.el' .
```

調査結果を短くまとめてから Phase 1 を開始する。

---

# 1. ゴール

既存の `my-read` に近い UI を使った `my-read-k` を実装する。

Chrome 上の Kindle Web Reader に CDP で接続し、

```text
Kindle Web Reader
  ↓ CDP Page.captureScreenshot
screen image
  ↓ crop
Apple Vision OCR
  ↓ JSON
Emacs
  ↓
my-read 中央ペインに英語本文
  ↓
既存 Google Translate / lookup / 読書機能
```

という経路で読書する。

**Kindle 本文を DOM から取り出そうとしてはいけない。OCR が必須の正規ルートである。**

---

# 2. 実行環境

主対象:

- macOS
- Apple Silicon
- Emacs
- 既存 `my-read`
- Chrome headful
- Kindle Web Reader
- Chrome remote debugging port
- Apple Vision OCR

`xwidget` は使わない。

Chrome ウィンドウは Emacs の外に存在してよい。
人間が普段見る UI は Emacs 側とする。

---

# 3. 推奨全体構成

追加物は原則として以下。

```text
<repo>/
├── my-read.el                  # existing; change minimally
├── my-read-k.el                # new Emacs integration
├── my-read-k/
│   └── bridge/
│       ├── Package.swift
│       ├── Sources/
│       │   └── MyReadKBridge/
│       │       ├── main.swift
│       │       ├── CDPClient.swift
│       │       ├── ChromeTarget.swift
│       │       ├── Screenshot.swift
│       │       ├── VisionOCR.swift
│       │       ├── PageSettler.swift
│       │       └── Protocol.swift
│       └── Tests/
├── scripts/
│   └── launch-kindle-chrome.sh
├── test/
│   └── my-read-k-tests.el
└── README-my-read-k.md
```

既存 repo の方針が違う場合は構成を合わせてよい。
ただし責務は分離する。

## Emacs の責務

- UI
- bridge process 管理
- async request / response 管理
- page history
- OCR text buffer 更新
- existing translation / lookup への接続
- user commands / keymap
- error reporting

## Swift bridge の責務

- Chrome target discovery
- CDP WebSocket
- `Page.captureScreenshot`
- page turn input
- screenshot decode / crop
- Apple Vision OCR
- OCR line ordering
- page-settle detection
- JSON Lines stdin/stdout protocol

**理由:** Swift なら macOS 標準 API だけで Apple Vision と `URLSessionWebSocketTask` を使える。
不要な Python / Node dependency を増やさず、常駐 bridge 一つにまとめる。

---

# 4. Chrome 起動

Chrome は remote debugging 用の専用 user-data-dir で起動する。

例:

```sh
#!/bin/zsh
set -euo pipefail

PORT="${MY_READ_K_CDP_PORT:-9222}"
PROFILE="${MY_READ_K_CHROME_PROFILE:-$HOME/Library/Application Support/my-read-k-chrome}"

exec "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --remote-debugging-port="$PORT" \
  --user-data-dir="$PROFILE" \
  "https://read.amazon.co.jp/"
```

スクリプトに secret を書かない。
Amazon ログインはユーザーが Chrome 上で行う。

target discovery は `/json/list` 相当から行い、
デフォルトでは Kindle Web Reader URL を候補にする。
URL matcher は `defcustom` または bridge config で変更可能にする。

---

# 5. OCR

Apple Vision を使う。

MVP は以下を基本とする。

```text
VNRecognizeTextRequest
recognitionLevel = .accurate
recognitionLanguages = ["en-US"]
usesLanguageCorrection = true
```

OCR の入力は Chrome screenshot から Kindle 読書領域だけ切り出したもの。

## crop

DOM 要素検出に依存しないこと。

最初の実装では normalized crop rect を設定可能にする。

例:

```elisp
(defcustom my-read-k-crop '(0.08 0.06 0.84 0.88) ...)
```

値の意味と座標原点は一つに統一し、bridge protocol に明記する。

デバッグ時のみ last screenshot / cropped screenshot を保存できる command を提供してよい。
通常読書では画像ファイルを永続保存しない。

## OCR result

単なる text だけではなく line metadata も返す。

最低限:

```json
{
  "text": "For a moment ...",
  "lines": [
    {
      "text": "For a moment ...",
      "confidence": 0.997,
      "bbox": [0.10, 0.78, 0.70, 0.035]
    }
  ]
}
```

Vision 座標と Emacs 側座標の意味を曖昧にしない。

## reading order

MVP は Kindle を 1 page / 1 column 表示に固定する運用を推奨する。

line ordering は基本:

1. 上から下
2. 同一行なら左から右

Vision bounding box の原点差を考慮すること。

将来的な 2 column 対応は可能だが MVP の blocker にしない。

---

# 6. ページ送り

CDP の `Input.dispatchKeyEvent` を使い、Kindle Web Reader に ArrowRight / ArrowLeft を送る。

実ブラウザでキーが効かない場合のみ mouse click fallback を追加する。

Emacs command:

```text
my-read-k-next-page
my-read-k-prev-page
my-read-k-refresh
my-read-k-attach
my-read-k-detach
my-read-k-show-last-error
```

## ページ描画安定待ち

固定 `sleep 0.5` だけに依存しない。

推奨:

```text
before fingerprint
→ page-turn
→ 100ms 程度の interval で viewport fingerprint
→ before と違うことを確認
→ 同一 fingerprint が連続 N 回になったら stable
→ final screenshot
→ OCR
```

fingerprint は小さく downscale した画像の hash でよい。
アニメーション途中を OCR しないことが目的。

timeout を必ず設ける。

---

# 7. bridge は常駐 process

ページごとに Swift executable を起動しない。

Emacs `make-process` 等から bridge を一度起動し、
stdin/stdout を JSON Lines で接続する。

- stdout: machine-readable JSON only
- stderr: human-readable logs
- 1 line = 1 JSON message
- request に `id`
- response に同じ `id`
- async safety のため `generation` を Emacs 側で持つ

詳細は `docs/BRIDGE_PROTOCOL.md`。

---

# 8. Emacs UI

`reference/my-read-current-ui.png` を visual reference とする。

**新しい UI を好き勝手に設計し直さない。既存 `my-read` を土台にする。**

目標:

```text
┌────────────────┬──────────────────────┬──────────────────────┐
│ Lookup         │ Kindle OCR English   │ Reading Translation  │
│                │                      │                      │
│ dictionary     │ normal Emacs text    │ Google Translate     │
│ result         │ buffer               │ current paragraph    │
│                │                      ├──────────────────────┤
│                │                      │ notes / org          │
└────────────────┴──────────────────────┴──────────────────────┘
```

中央だけが Kindle OCR source に置き換わるイメージ。

## 強い要件

OCR 英文は画像表示ではなく **普通の Emacs buffer の文字列** とする。

これにより:

- current point の単語 lookup
- paragraph translation
- sentence navigation
- copy
- search
- TTS
- existing my-read functions

を可能な限りそのまま使う。

## buffer

例:

```text
*my-read-k:english*
```

read-only を基本にしてよいが、point movement / text properties / overlays は普通に使えること。

ページ更新時:

1. stale async response を reject
2. `inhibit-read-only`
3. buffer replace
4. point restore policy
5. existing my-read refresh hooks を走らせる
6. translation / lookup timer の暴発を避ける

## page direction と point

next page:
- 新ページ先頭へ

prev page:
- 新ページ末尾付近へ

既存 my-read の sentence navigation を優先して壊さない。

MVP では page turn に専用 command を用意する。
既存 `j/k` に既に意味があるなら勝手に上書きしない。

Phase 2 で:

- sentence-next で page end に到達したら自動 next page
- sentence-prev で page beginning に到達したら自動 prev page

を追加してよい。

---

# 9. 既存 Google Translate / lookup の再利用

この部分は再実装しない。

既存 `my-read` を調査し、中央 buffer が通常テキストなら使える経路を抽出する。

必要なら `my-read.el` の内部処理を以下のように小さく共通化する。

```text
my-read source setup
        │
        ├─ file/epub/text source
        │
        └─ kindle OCR source
                ↓
        common reading UI
        common translation
        common lookup
        common TTS
```

ただし大規模 rewrite はしない。

**既存 my-read 用テストを追加して regression を防ぐ。**

---

# 10. async / race condition

これは重要。

想定:

```text
user: next
request A started

user: next
request B started

B response arrives
A response arrives late
```

A が B の画面を上書きしてはいけない。

Emacs 側で monotonically increasing generation を持つ。

```text
generation 41 → request A
generation 42 → request B
```

response generation が current generation でないなら破棄する。

page-turn command 実行中は:

- queue last intent
- または command を serialize

のどちらかを実装する。
MVP は serialize でよい。

Emacs UI thread を block しない。

---

# 11. in-memory page cache

小さな ring cache は許可する。

例:

```text
previous 2
current
next 1
```

cache key:

```text
screenshot fingerprint
```

value:

```text
OCR text
OCR lines
optional translation cache key
```

原則メモリのみ。
本一冊分を crawl / export / persist する機能は作らない。

---

# 12. エラー UX

次を区別する。

- Chrome not running
- debug port unavailable
- Kindle target not found
- target disconnected
- page turn timeout
- screenshot failed
- invalid crop
- Vision OCR failed
- no text recognized
- malformed bridge response

Emacs minibuffer に短い message。
詳細は `*my-read-k-log*` または `my-read-k-show-last-error`。

bridge crash 時に Emacs 自体を巻き込まない。

---

# 13. テスト

必須:

## Emacs ERT

- bridge response parser
- stale generation reject
- page update
- next / prev request generation
- process death handling
- text replacement 後も lookup / translation hook が有効
- `my-read` regression

## Swift

- protocol decode/encode
- target selection
- crop coordinate conversion
- OCR line ordering
- stable fingerprint state machine
- timeout

Chrome / Kindle / Amazon を必要としない fake response test を多めにする。

integration test は optional / manual でよい。

---

# 14. 実装の順序

絶対に一気に全部作らない。

## Phase 0: reconnaissance
既存 my-read の structure を把握し、接続点を報告。

## Phase 1: standalone bridge capture
Chrome target attach → screenshot → Vision OCR → JSON stdout。

**ここで実ブラウザ上の Kindle 1ページが OCR できるまで進まない。**

## Phase 2: Emacs current-page
`M-x my-read-k` → current page OCR → center buffer。

## Phase 3: reuse my-read
Google Translate / lookup を既存コードから接続。

## Phase 4: page navigation
next / prev → stable wait → OCR → replace。

## Phase 5: robustness
async generation, reconnect, timeout, log, tests。

## Phase 6: optional UX
small cache, end-of-buffer automatic page turn, debug screenshot, performance tune。

各 Phase の終わりに test / manual verification を行う。

---

# 15. 完了判定

以下が全部満たされるまで完了と言わない。

- [ ] existing my-read の構成を調査した
- [ ] `my-read.el` の変更は最小限
- [ ] Swift bridge が Kindle target に attach できる
- [ ] `Page.captureScreenshot` で current page image を取得できる
- [ ] crop が設定可能
- [ ] Apple Vision で英語 OCR できる
- [ ] Emacs center buffer に普通の文字として展開される
- [ ] existing Google Translate が動く
- [ ] existing word lookup が動く
- [ ] existing TTS がある場合、それを壊していない
- [ ] Emacs から next page
- [ ] Emacs から previous page
- [ ] animation 中を OCR しない
- [ ] stale async response で画面が巻き戻らない
- [ ] bridge failure で Emacs が固まらない
- [ ] ERT tests が通る
- [ ] Swift tests が通る
- [ ] README にセットアップと操作方法がある

---

# 16. Codex の作業報告フォーマット

各 Phase 終了時に短く以下を出す。

```text
Phase:
Changed:
Tests:
Manual verification:
Known issues:
Next:
```

不要な長文説明より、実ファイル・テスト・再現手順を優先すること。

# 17. `j/k` の最重要 UX: ページ境界を意識させない

既存 `my-read` では `j/k` が「Kokoro で読み上げながら段落を前後に進む」操作になっている。
`my-read-k` でも **この意味を変えてはいけない**。

Kindle のページ送りは新しい主操作として露出させるのではなく、
**現在の OCR buffer 内に次/前の段落がなくなった時だけ、`j/k` の内部処理として発火する**こと。

期待する挙動:

```text
j
├─ buffer 内に次段落あり
│    └─ 既存 my-read の j 処理
│         ├─ 次段落へ移動
│         ├─ Google Translate 更新
│         ├─ lookup 更新
│         └─ Kokoro 読み上げ
│
└─ buffer 内に次段落なし
     └─ Kindle next page
          ├─ page settle
          ├─ screenshot
          ├─ Vision OCR
          ├─ English buffer 差し替え
          ├─ 新ページの先頭段落へ移動
          ├─ Google Translate 更新
          ├─ lookup 更新
          └─ Kokoro 読み上げ
```

`k` は完全に対称:

```text
k
├─ buffer 内に前段落あり
│    └─ 既存 my-read の k 処理
│
└─ buffer 内に前段落なし
     └─ Kindle previous page
          ├─ page settle
          ├─ screenshot
          ├─ Vision OCR
          ├─ English buffer 差し替え
          ├─ 新ページの最終段落へ移動
          ├─ Google Translate 更新
          ├─ lookup 更新
          └─ Kokoro 読み上げ
```

ユーザーから見れば、

```text
j/k = 本文を前後に読む
```

だけでよく、Kindle の「ページ」という概念は極力 UI から消す。

## 実装上の方針

`j/k` の本体を Kindle 用にコピーしない。

既存 my-read の paragraph navigation と post-move 処理を調査し、
必要なら最小限の refactor で、

```text
move within current source buffer
    ↓
移動できた?
├─ yes → common post-move
└─ no  → source boundary handler
              ↓
         Kindle page fetch
              ↓
         common post-move
```

という構造にする。

理想的な責務分離:

```text
my-read common:
- paragraph movement
- translation refresh
- lookup refresh
- Kokoro playback
- post-move hooks

my-read-k source adapter:
- next page fetch
- previous page fetch
- OCR buffer replacement
- first/last paragraph positioning
```

既存 `j/k` の TTS / timer / translation sequencing を壊さないこと。

## MVP と最適化順

MVP:
1. buffer 境界まで通常 `j/k`
2. 境界で Kindle page turn
3. OCR 完了後に next/previous paragraph へ移動
4. Kokoro / translation / lookup

その後:
1. previous/current page の小さな memory cache
2. page boundary の復帰高速化
3. 必要なら、現在ページ最後の段落を Kokoro が読み上げている間に next page を prefetch

**prefetch は MVP に入れない。**
Chrome の物理ページ位置と Emacs の論理ページ位置がズレるため、
state model とテストを追加してから導入する。

## 受け入れ条件

- `j` を連打しても通常の my-read と同じ感覚で段落を進める
- current OCR buffer の最後で `j` を押すと自動で Kindle 次ページへ進む
- 新ページ第1段落の翻訳・lookup・Kokoro が通常通り動く
- current OCR buffer の最初で `k` を押すと自動で前ページへ戻る
- 前ページ最終段落の翻訳・lookup・Kokoro が通常通り動く
- ページ境界のためだけにユーザーが別キーを押す必要がない
- `j/k` の既存動作を regression させない

# ===== ARCHITECTURE =====

# Architecture

## 1. 基本思想

Kindle Web Reader を「認証済みのページレンダラー」として使い、
Emacs を実際の読書 UI とする。

Kindle の内部形式を解析しない。
本文 DOM 抽出を試みない。
人間に表示されている current page を screenshot → OCR する。

```text
                        macOS
┌─────────────────────────────────────────────────────────┐
│                                                         │
│ Chrome / Kindle Web Reader                              │
│     │                                                   │
│     │ CDP                                               │
│     ▼                                                   │
│ MyReadKBridge (Swift, persistent)                       │
│     ├─ target discovery                                 │
│     ├─ screenshot                                       │
│     ├─ crop                                             │
│     ├─ Vision OCR                                       │
│     ├─ page settle                                      │
│     └─ key input                                        │
│     │ JSON Lines stdin/stdout                           │
│     ▼                                                   │
│ Emacs                                                   │
│     ├─ my-read-k.el                                     │
│     └─ existing my-read                                 │
│          ├─ central English text                        │
│          ├─ Google Translate                            │
│          ├─ lookup                                      │
│          ├─ notes                                       │
│          └─ TTS if present                              │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

## 2. なぜ persistent Swift bridge か

1ページごとに CLI 起動すると startup / process handling が無駄。
一度起動した bridge が Chrome WebSocket と Vision OCR の両方を保持する。

Swift の標準 framework を中心にする:

- Foundation
- URLSession / URLSessionWebSocketTask
- Vision
- CoreGraphics / ImageIO

third-party dependency は原則ゼロ。

## 3. 状態

### Emacs

```text
detached
  ↓ attach
attached
  ↓ capture/navigation
busy
  ↓ result
attached
```

fields のイメージ:

```elisp
my-read-k--process
my-read-k--request-id
my-read-k--generation
my-read-k--busy-p
my-read-k--pending-intent
my-read-k--last-error
my-read-k--page-cache
my-read-k--target
```

### Bridge

```text
startup
  ↓
discovering
  ↓
connected
  ├─ capture
  ├─ next
  ├─ prev
  └─ status
```

target が閉じたら `disconnected` を返し、必要なら次 request で再 discovery。

## 4. current-page only を基本にする

MVP では先読みしない。
まず reliability を優先する。

後から optional prefetch を入れる場合でも、
Emacs が表示している page と Chrome が実際に表示している page の差を
明示的 state として持たない限り実装しない。

## 5. 性能方針

最適化順:

1. crop で余計な UI を OCR しない
2. Vision `.accurate` を基準に正確さ優先
3. bridge 常駐
4. page settle 用 screenshot は downscale/fingerprint のみ
5. final stable image にだけ OCR
6. OCR result の small ring cache

まず correctness、その後 latency。

## 6. privacy / storage

通常モード:

- screenshot は memory only
- OCR text は current/small ring memory
- debug file output off

debug モードでのみ画像保存。
ファイル名に book title を必須にしない。

# ===== EMACS UI SPEC =====

# Emacs UI specification

## 1. visual reference

`../reference/my-read-current-ui.png`

この UI を「似せて再実装」するより、既存 `my-read` の window setup / buffer logic を再利用する。

## 2. target layout

概念:

```text
┌──────────────────┬──────────────────────┬──────────────────────┐
│ lookup           │ English              │ translation          │
│                  │                      │                      │
│ cursor word      │ OCR current page     │ current paragraph    │
│ dictionary       │ normal text buffer   │ Google Translate     │
│                  │                      ├──────────────────────┤
│                  │                      │ notes / org          │
│                  │                      │                      │
└──────────────────┴──────────────────────┴──────────────────────┘
```

既存 UI の ratio / face / font / theme は可能な限りそのまま使う。
色を hard-code しない。

## 3. commands

最低限:

```text
M-x my-read-k
M-x my-read-k-attach
M-x my-read-k-detach
M-x my-read-k-next-page
M-x my-read-k-prev-page
M-x my-read-k-refresh
M-x my-read-k-status
M-x my-read-k-show-last-error
```

optional:

```text
M-x my-read-k-debug-save-screenshot
M-x my-read-k-open-chrome
M-x my-read-k-clear-cache
```

## 4. key bindings

既存 `my-read` keymap を必ず調査する。

`j/k` 等を既存機能が使っているなら勝手に上書きしない。

MVP では例として:

```text
C-c ]  next Kindle page
C-c [  previous Kindle page
C-c g  refresh OCR
```

repo の naming convention / keymap に合わせて変更可。

Phase 2 optional:

- sentence-forward が buffer end なら next Kindle page
- sentence-backward が buffer beginning なら previous Kindle page

これなら通常は sentence 単位で読み、ページ境界を意識しなくてよい。

## 5. English buffer

要件:

- normal text, not image
- read-only acceptable
- point movable
- `thing-at-point` works
- paragraph boundaries exist
- existing lookup timers/hooks work
- existing translation paragraph detection works
- existing TTS works if present

OCR text normalize:

- line-wrap 由来の改行を paragraph 内では適切に join
- paragraph boundary は blank line
- hyphenation at line end は慎重に扱う
- curly apostrophe / quote を過剰に ASCII 化しない
- OCR raw lines は metadata として別保持

`English` buffer 本文を OCR の line そのままにすると paragraph translation が不自然になるので、
`raw lines -> paragraph reconstruction -> display text` の層を分ける。

ただし reconstruction が誤る可能性があるため、raw OCR を捨てない。

## 6. update policy

next:

```text
show busy indicator
→ bridge next
→ stable
→ OCR
→ generation check
→ replace English buffer
→ point=min
→ run my-read refresh
→ clear busy
```

prev:

```text
...
→ point=max or last readable sentence
```

## 7. status

mode-line または header-line に過剰でない status を出してよい。

例:

```text
Kindle: attached | OCR 184ms
```

ただし visual noise を増やさない。
既存 my-read の表示を優先。

# 7. `j/k` seamless page-boundary behavior

`j/k` は既存 `my-read` の主要読書操作として維持する。

### `j`

```text
次段落が current OCR buffer に存在
→ 既存 my-read の段落移動 + translate + lookup + Kokoro

次段落が存在しない
→ Kindle next
→ settle
→ OCR
→ buffer replace
→ first paragraph
→ translate + lookup + Kokoro
```

### `k`

```text
前段落が current OCR buffer に存在
→ 既存 my-read の段落移動 + translate + lookup + Kokoro

前段落が存在しない
→ Kindle prev
→ settle
→ OCR
→ buffer replace
→ last paragraph
→ translate + lookup + Kokoro
```

この結果、ユーザーには一冊の本が連続した巨大な Emacs buffer のように見えること。

ページ送り専用 command (`my-read-k-next-page` / `prev-page`) は
debug / direct navigation 用として残してよいが、通常読書の主 UI にはしない。

### async 中のキー入力

ページ境界で OCR 中にさらに `j/k` が押された場合、
MVP では処理を serialize する。

少なくとも:
- Emacs を block しない
- stale OCR response で巻き戻らない
- Kokoro の二重再生を起こさない
- translation timer を二重発火させない

# ===== BRIDGE PROTOCOL =====

# Bridge protocol

## Transport

persistent process stdin/stdout, JSON Lines.

- request: one JSON object per line
- response: one JSON object per line
- stdout contains JSON only
- diagnostics to stderr
- UTF-8

## Common request

```json
{
  "id": 12,
  "command": "capture",
  "generation": 41,
  "params": {}
}
```

## Common success response

```json
{
  "id": 12,
  "ok": true,
  "generation": 41,
  "result": {}
}
```

## Common error response

```json
{
  "id": 12,
  "ok": false,
  "generation": 41,
  "error": {
    "code": "NO_KINDLE_TARGET",
    "message": "No matching Kindle Web Reader target found"
  }
}
```

## Commands

### hello

```json
{"id":1,"command":"hello","generation":0,"params":{}}
```

result:

```json
{
  "protocolVersion": 1,
  "bridgeVersion": "0.1.0",
  "capabilities": ["capture","ocr","next","prev","status"]
}
```

### attach

params:

```json
{
  "cdpHost": "127.0.0.1",
  "cdpPort": 9222,
  "urlPattern": "read.amazon"
}
```

result:

```json
{
  "targetId": "...",
  "title": "...",
  "url": "https://read.amazon.co.jp/..."
}
```

Do not return cookies/auth/session data.

### capture

params:

```json
{
  "crop": {
    "x": 0.08,
    "y": 0.06,
    "width": 0.84,
    "height": 0.88
  },
  "language": "en-US",
  "recognition": "accurate"
}
```

result:

```json
{
  "fingerprint": "sha256-or-other-stable-id",
  "imageWidth": 1200,
  "imageHeight": 1600,
  "ocrMs": 180,
  "text": "It was very dark ...",
  "lines": [
    {
      "text": "It was very dark ...",
      "confidence": 0.997,
      "bbox": [0.10, 0.82, 0.70, 0.035]
    }
  ]
}
```

### next

params:

```json
{
  "settle": {
    "pollMs": 100,
    "stableSamples": 2,
    "timeoutMs": 4000
  },
  "capture": {
    "crop": {
      "x": 0.08,
      "y": 0.06,
      "width": 0.84,
      "height": 0.88
    },
    "language": "en-US",
    "recognition": "accurate"
  }
}
```

result: same as capture + optional `navigation`.

### prev

same as next.

### status

result:

```json
{
  "connected": true,
  "target": {
    "title": "...",
    "url": "..."
  }
}
```

## Error codes

At minimum:

```text
CDP_UNAVAILABLE
NO_KINDLE_TARGET
TARGET_DISCONNECTED
CDP_PROTOCOL_ERROR
SCREENSHOT_FAILED
INVALID_CROP
PAGE_DID_NOT_CHANGE
PAGE_SETTLE_TIMEOUT
OCR_FAILED
NO_TEXT
INVALID_REQUEST
INTERNAL_ERROR
```

## Generation rule

Bridge echoes generation.
Emacs decides whether the response is stale.

Never let an old response overwrite a newer page.

# ===== IMPLEMENTATION PLAN =====

# Implementation plan

## Phase 0 — reconnaissance

Deliverable: short note in Codex output.

Find:

- actual `my-read` entry command
- central reading buffer creation
- translation buffer / update hook
- lookup process / timer
- TTS interaction
- keymap
- window layout
- tests
- known async timers

Do not modify code yet unless needed to run tests.

## Phase 1 — Swift bridge PoC

Implement:

1. `hello`
2. `attach`
3. `capture`
4. Apple Vision OCR
5. stderr logs

Manual acceptance:

```text
launch Chrome
open Kindle book
run bridge
send attach JSON
send capture JSON
receive readable English current-page text
```

Do not add navigation before this works.

## Phase 2 — Emacs current page

Implement `my-read-k.el`:

- launch bridge via `make-process`
- JSONL framing
- request ids
- generation
- attach
- current page capture
- central buffer replacement

Manual acceptance:

```text
M-x my-read-k
```

shows current Kindle page as English text.

## Phase 3 — existing my-read integration

Refactor minimally so same translation and lookup logic acts on Kindle OCR buffer.

Acceptance:

- moving point changes lookup as it currently does in my-read
- current paragraph translation changes as it currently does
- no new duplicate translation implementation
- existing my-read still works

## Phase 4 — navigation

Bridge:

- Input.dispatchKeyEvent
- next
- prev
- settle detector

Emacs:

- commands
- busy serialization
- page update
- direction-aware point

## Phase 5 — race/error robustness

- stale response rejection
- timeouts
- process death
- reconnect
- bad JSON
- no target
- no text
- user-visible error path

## Phase 6 — tests

Increase ERT and Swift unit tests until core state transitions are covered.

## Phase 7 — optional

Only after stable:

- automatic page turn at sentence boundary
- small ring cache
- debug crop UI
- OCR paragraph reconstruction refinement
- page latency display

# Phase 4.5 — seamless `j/k` integration

navigation command が単独で動いた後、既存 `my-read` の `j/k` と統合する。

1. current buffer 内の paragraph movement を既存実装で行う
2. movement 不可能な場合だけ source boundary handler を呼ぶ
3. Kindle source なら next/prev page request
4. OCR result を buffer に展開
5. direction に応じて first/last paragraph に point を置く
6. **既存の common post-move path を一度だけ呼ぶ**
7. Kokoro / translation / lookup の順序を既存 my-read と一致させる

Acceptance:

```text
j j j ... [page boundary] j j ...
```

が、ユーザーから見て一続きの paragraph navigation に見えること。

# ===== TEST PLAN =====

# Test plan

## Emacs ERT

### protocol

- partial process chunks are assembled into JSON lines
- multiple JSON lines in one process chunk
- invalid JSON does not crash Emacs
- response id maps to callback
- stale generation is ignored

### state

- detached -> attaching -> attached
- attached -> busy -> attached
- process death -> detached/error
- next/prev serialized

### English buffer

- capture replaces content
- next sets point near beginning
- prev sets point near end
- buffer remains normal searchable text
- read-only replacement uses `inhibit-read-only`
- paragraph reconstruction gives usable paragraph boundaries

### my-read integration

Using stubs/mocks if network services are undesirable:

- existing translation update function is reachable from Kindle buffer
- existing lookup update function is reachable from Kindle buffer
- timers are not duplicated each page
- timers/processes are cleaned up on exit
- original `my-read` command still builds its normal UI

## Swift tests

### Protocol

- request decoding
- unknown command
- response encoding
- error encoding
- generation echo

### target selection

fixtures for `/json/list`:

- one Kindle page
- many pages
- no Kindle
- target missing websocket URL

### crop

- normalized rect conversion
- invalid negative values
- width > 1
- out of bounds
- coordinate origin conversion

### OCR line order

synthetic observations:

- single column
- same y different x
- Vision lower-left origin
- blank result

### PageSettler

state machine fixtures:

```text
AAAA → BBBB → CCCC → CCCC => stable
AAAA → AAAA → AAAA => did not change
AAAA → BBBB → CCCC → DDDD => timeout
```

No real Kindle dependency in unit tests.

## Manual integration checklist

- [ ] launch debug Chrome
- [ ] login to Amazon manually
- [ ] open a Kindle English book
- [ ] `M-x my-read-k`
- [ ] current page OCR readable
- [ ] lookup current word
- [ ] paragraph translated
- [ ] next page
- [ ] previous page
- [ ] rapid next requests do not corrupt UI
- [ ] close Kindle tab: sensible error
- [ ] restart tab: reconnect
- [ ] kill bridge: Emacs survives

# `j/k` page-boundary regression tests

ERT で最低限以下を追加する。

- `j`: next paragraph がある → bridge navigation request を出さない
- `j`: next paragraph がない → Kindle next request を1回だけ出す
- next OCR success → first paragraph に point
- next OCR success → common post-move / translation / lookup / Kokoro trigger が各1回
- `k`: previous paragraph がある → bridge navigation request を出さない
- `k`: previous paragraph がない → Kindle prev request を1回だけ出す
- prev OCR success → last paragraph に point
- boundary request 中の追加 `j/k` で二重 request / 二重 TTS にならない
- stale generation response で古いページに戻らない
- original non-Kindle `my-read` の `j/k` が完全に従来通り

# ===== SCOPE AND GUARDRAILS =====

# Scope and guardrails

## In scope

- user-controlled Chrome
- Kindle Web Reader as renderer
- current displayed page screenshot
- OCR for interactive reading assistance
- translation/lookup/TTS integration in Emacs
- next/previous page control
- small transient cache
- debug screenshots explicitly requested by user

## Out of scope

- DRM circumvention
- Kindle file format decryption
- extracting hidden book resources
- crawling an entire book unattended
- exporting a whole book to EPUB/PDF/TXT
- bulk persistent OCR archive
- bypassing Amazon authentication
- capturing cookies/tokens into logs

The product should remain an interactive reading frontend/controller.

## Security

CDP debugging endpoint has powerful browser control.

Defaults:

- bind/use `127.0.0.1`
- do not expose port to LAN
- dedicated Chrome profile
- never log cookies or auth headers
- no arbitrary `Runtime.evaluate` unless a concrete need appears
- target matcher narrowed to Kindle reader

# ===== ENVIRONMENT =====

# Environment / integration notes

These notes are constraints for Codex, not assumptions about exact existing symbol names.

## Known intended environment

- macOS on Apple Silicon
- Emacs-based daily reading workflow
- existing `my-read` UI
- existing Google Translate integration
- existing per-word lookup integration
- existing notes pane
- TTS may already be wired into `my-read`
- no `xwidget` dependency
- Chrome is allowed to run separately in headful mode

## Existing UI reference

See:

```text
reference/my-read-current-ui.png
```

Visual characteristics visible in the reference:

- left: dictionary / lookup
- center: English reading text
- right upper: reading translation
- right lower: notes / org content
- dark theme
- large central reading typography

Do not hard-code the color palette.
Use existing faces/theme/window setup where possible.

## Integration strategy

Prefer:

```text
existing my-read
  ├─ source-specific loading
  └─ shared reading services
       ├─ layout
       ├─ translation
       ├─ lookup
       └─ TTS
```

Add Kindle as another source backend.

Avoid:

```text
my-read
my-read-k  # giant duplicated fork of everything
```

If current code is monolithic, extract only the smallest reusable pieces required.

# ===== OFFICIAL REFERENCES =====

# Official API references used for the design

These are implementation references, not requirements to copy sample code verbatim.

## Chrome

Chrome DevTools Protocol — Page domain

https://chromedevtools.github.io/devtools-protocol/tot/Page/

Relevant method:

```text
Page.captureScreenshot
```

Chrome DevTools Protocol — Input domain

https://chromedevtools.github.io/devtools-protocol/tot/Input/

Relevant method:

```text
Input.dispatchKeyEvent
```

Chrome remote debugging switch security change

https://developer.chrome.com/blog/remote-debugging-port

Relevant operational point:
Use a non-default `--user-data-dir` together with remote debugging on current Chrome.

## Apple

Vision — VNRecognizeTextRequest

https://developer.apple.com/documentation/vision/vnrecognizetextrequest

Recognizing Text in Images

https://developer.apple.com/documentation/vision/recognizing-text-in-images

Relevant concepts:

- accurate vs fast recognition
- recognition languages
- text observations / bounding boxes

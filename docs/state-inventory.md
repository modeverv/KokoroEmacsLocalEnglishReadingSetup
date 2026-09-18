# Elisp state inventory

2026-09-18のトップレベル宣言から作成。初期値のない外部パッケージ向け宣言は省略しています。

設定は `defcustom`、文書ごとの状態は `defvar-local`、単一の音声出力や接続の状態は `defvar` として保持します。
所有者・解放タイミングは [architecture.md](architecture.md#状態とライフサイクル) を参照してください。
値やキー構造は既存のまま維持し、設定変数のrenameは行っていません。

## my-read/integrations/english-reader-tts.el

| 宣言 | 名前 |
| --- | --- |
| `defcustom` | `english-reader-tts-voice` |
| `defcustom` | `english-reader-tts-rate` |
| `defvar` | `english-reader-tts-process` |

## my-read/core/english-reading-state.el

| 宣言 | 名前 |
| --- | --- |
| `defcustom` | `english-reading-mode-pdftotext-program` |
| `defcustom` | `english-reading-mode-pdf-highlight-color` |
| `defcustom` | `english-reading-mode-pdf-highlight-opacity` |
| `defcustom` | `english-reading-mode-pdf-highlight-program` |
| `defcustom` | `english-reading-mode-pdf-highlight-delay` |
| `defcustom` | `english-reading-mode-pdf-highlight-watch-duration` |
| `defcustom` | `english-reading-mode-pdf-speech-screen-position` |
| `defcustom` | `english-reading-mode-macos-continuous-sentence-count` |
| `defcustom` | `english-reading-mode-macos-prefetch-chunk-count` |
| `defcustom` | `english-reading-mode-macos-prefetch-check-interval` |
| `defvar` | `english-reading-mode-pdf-text-buffer-hook` |
| `defvar` | `english-reading-mode-speech-start-hook` |
| `defvar` | `english-reading-mode-speech-finish-hook` |
| `defvar` | `english-reading-mode--speech-sequence` |
| `defvar` | `english-reading-mode--active-speech` |
| `defvar` | `english-reading-mode--pdf-highlight-timer` |
| `defvar` | `english-reading-mode--pdf-highlight-pending-context` |
| `defvar` | `english-reading-mode--pdf-highlight-pending-scroll-state` |
| `defvar` | `english-reading-mode--pdf-highlight-watch-timer` |
| `defvar` | `english-reading-mode--pdf-highlight-watch-context` |
| `defvar` | `english-reading-mode--pdf-highlight-watch-remaining` |
| `defvar` | `english-reading-mode` |
| `defvar-local` | `english-reading-mode--saved-sentence-end-double-space` |
| `defvar-local` | `english-reading-mode--sentence-setting-saved-p` |
| `defvar-local` | `english-reading-mode--sentence-setting-was-local-p` |
| `defvar-local` | `english-reading-mode--saved-buffer-read-only` |
| `defvar-local` | `english-reading-mode--read-only-setting-saved-p` |
| `defvar-local` | `english-reading-mode--pdf-text-buffer` |
| `defvar-local` | `english-reading-mode--pdf-page-ranges` |
| `defvar-local` | `english-reading-mode--pdf-page` |
| `defvar-local` | `english-reading-mode--pdf-text-point` |
| `defvar-local` | `english-reading-mode--pdf-bbox-cache` |
| `defvar-local` | `english-reading-mode--pdf-image-data-cache` |
| `defvar-local` | `english-reading-mode--pdf-highlight-page` |
| `defvar-local` | `english-reading-mode--pdf-highlight-state` |
| `defvar-local` | `english-reading-mode-key-active-predicate` |
| `defvar` | `english-reading-mode--speech-watch-timer` |
| `defvar` | `english-reading-mode--speech-start-time` |
| `defvar` | `english-reading-mode--speech-player-seen-p` |
| `defvar` | `english-reading-mode--exact-player-finish-p` |
| `defvar` | `english-reading-mode--continuous-state` |
| `defvar` | `english-reading-mode--continuous-generation` |
| `defvar` | `english-reading-mode--continuous-timer` |
| `defvar` | `english-reading-mode--macos-prefetch-monitor-timer` |
| `defvar` | `english-reading-mode--continuous-warmup-timer` |
| `defvar-local` | `english-reading-mode-continuous-next-function` |
| `defvar-local` | `english-reading-mode-continuous-prefetch-text-function` |
| `defvar` | `english-reading-mode-speech-prepare-hook` |
| `defvar` | `english-reading-mode-speech-highlight-hook` |

## my-read/speech/synthesis/kokoro-reader.el

| 宣言 | 名前 |
| --- | --- |
| `defcustom` | `kokoro-reader-endpoint` |
| `defcustom` | `kokoro-reader-health-endpoint` |
| `defcustom` | `kokoro-reader-server-command` |
| `defcustom` | `kokoro-reader-server-directory` |
| `defcustom` | `kokoro-reader-model` |
| `defcustom` | `kokoro-reader-voice` |
| `defcustom` | `kokoro-reader-lang-code` |
| `defcustom` | `kokoro-reader-speed` |
| `defcustom` | `kokoro-reader-volume` |
| `defcustom` | `kokoro-reader-curl-program` |
| `defcustom` | `kokoro-reader-player-program` |
| `defcustom` | `kokoro-reader-backend` |
| `defcustom` | `kokoro-reader-macos-speech-bridge-program` |
| `defcustom` | `kokoro-reader-macos-voice` |
| `defcustom` | `kokoro-reader-macos-rate` |
| `defcustom` | `kokoro-reader-macos-prefetch-enabled` |
| `defcustom` | `kokoro-reader-macos-prefetch-count` |
| `defcustom` | `kokoro-reader-kokoro-prefetch-count` |
| `defcustom` | `kokoro-reader-kokoro-prefetch-concurrency` |
| `defvar` | `kokoro-reader--request-process` |
| `defvar` | `kokoro-reader--player-process` |
| `defvar` | `kokoro-reader--server-process` |
| `defvar` | `kokoro-reader--server-health-process` |
| `defvar` | `kokoro-reader--server-health-timer` |
| `defvar` | `kokoro-reader--audio-file` |
| `defvar` | `kokoro-reader--overlay` |
| `defvar` | `kokoro-reader--macos-bridge-process` |
| `defvar` | `kokoro-reader--macos-bridge-fragment` |
| `defvar` | `kokoro-reader--macos-bridge-ready-p` |
| `defvar` | `kokoro-reader-macos-queued-start-hook` |
| `defvar` | `kokoro-reader-player-finish-hook` |

## my-read/speech/synthesis/reader-speech-queue.el

旧queue変数名は互換性のため維持します。変更はこのmoduleのAPIに集約します。

| 宣言 | 名前 |
| --- | --- |
| `defvar` | `kokoro-reader--macos-prefetch-queue` |
| `defvar` | `kokoro-reader--macos-next-id` |
| `defvar` | `kokoro-reader--macos-current-entry` |
| `defvar` | `kokoro-reader--kokoro-pending-entries` |
| `defvar` | `kokoro-reader--kokoro-request-processes` |
| `defvar` | `kokoro-reader--kokoro-api-ready-p` |
| `defvar` | `kokoro-reader--kokoro-health-pending-p` |
| `defvar` | `reader-speech-queue--generation` |
| `defvar` | `reader-speech-queue-transport` |
| `defvar` | `reader-speech-queue-connect-functions` |
| `defvar` | `reader-speech-queue-event-functions` |
| `defvar` | `reader-speech-queue-last-error` |

## my-read/core/reader-diagnose.el

診断buffer内のsource・snapshot・health・probe process・generationはbuffer-localです。
更新時に古いprobeを取り消し、古いgenerationの応答は破棄します。

## my-read/core/my-read-core.el

| 宣言 | 名前 |
| --- | --- |
| `defvar-local` | `my/read-center-tab-frame` |
| `defvar-local` | `my/read-center-tab-placeholder-type` |

## my-read/integrations/my-read-eww-math.el

| 宣言 | 名前 |
| --- | --- |
| `defcustom` | `my/read-eww-math-enabled` |
| `defcustom` | `my/read-eww-math-trusted-url-regexp` |
| `defcustom` | `my/read-eww-math-cache-directory` |
| `defcustom` | `my/read-eww-math-latex-program` |
| `defcustom` | `my/read-eww-math-dvisvgm-program` |
| `defcustom` | `my/read-eww-math-process-timeout` |
| `defcustom` | `my/read-eww-math-max-processes` |
| `defcustom` | `my/read-eww-math-max-tex-length` |
| `defcustom` | `my/read-eww-math-image-ascent` |
| `defcustom` | `my/read-eww-math-image-scale` |
| `defcustom` | `my/read-eww-math-image-scale-multiplier` |
| `defcustom` | `my/read-eww-math-inline-scale-multiplier` |
| `defcustom` | `my/read-eww-math-image-vertical-margin` |
| `defcustom` | `my/read-eww-math-svg-stroke-width` |
| `defcustom` | `my/read-eww-math-svg-padding` |
| `defvar-local` | `my/read-eww-math--queue` |
| `defvar-local` | `my/read-eww-math--active-processes` |
| `defvar-local` | `my/read-eww-math--generation` |
| `defvar-local` | `my/read-eww-math--job-counter` |
| `defvar-local` | `my/read-eww-math--installed-p` |
| `defvar` | `my/read-eww-math--missing-program-warning-shown` |
| `defvar` | `my/read-eww-math--render-target-buffer` |

## my-read/document/eww/my-read-eww.el

| 宣言 | 名前 |
| --- | --- |
| `defvar-local` | `my/read-position--eww-file` |
| `defcustom` | `my/read-eww-url` |
| `defcustom` | `my/read-eww-history-file` |
| `defcustom` | `my/read-eww-history-limit` |
| `defcustom` | `my/read-eww-enable-automatic-lookup` |
| `defcustom` | `my/read-eww-line-spacing` |
| `defcustom` | `my/read-eww-article-image-background` |
| `defcustom` | `my/read-eww-image-convert-program` |
| `defcustom` | `my/read-eww-svg-raster-program` |
| `defcustom` | `my/read-eww-article-svg-max-width` |
| `defvar-local` | `my/read--eww-image-background-installed-p` |
| `defvar-local` | `my/read-eww-history-page-p` |

## my-read/document/kindle/my-read-k.el

| 宣言 | 名前 |
| --- | --- |
| `defcustom` | `my-read-k-settle-poll-ms` |
| `defcustom` | `my-read-k-settle-stable-samples` |
| `defcustom` | `my-read-k-settle-timeout-ms` |
| `defcustom` | `my-read-k-prefetch-enabled` |
| `defcustom` | `my-read-k-prefetch-count` |
| `defcustom` | `my-read-k-history-count` |
| `defvar` | `my-read-k--bridge-command-function` |
| `defvar` | `my-read-k--reconnect-function` |
| `defvar` | `my-read-k--process` |
| `defvar` | `my-read-k--stopping-p` |
| `defvar` | `my-read-k--process-output` |
| `defvar` | `my-read-k--callbacks` |
| `defvar` | `my-read-k--request-id` |
| `defvar` | `my-read-k--generation` |
| `defvar` | `my-read-k--busy-p` |
| `defvar` | `my-read-k--prefetch-busy-p` |
| `defvar` | `my-read-k--sync-busy-p` |
| `defvar` | `my-read-k--pending-intent` |
| `defvar` | `my-read-k--last-error` |
| `defvar` | `my-read-k--state` |
| `defvar` | `my-read-k--frame` |
| `defvar` | `my-read-k--buffer` |
| `defvar` | `my-read-k--last-fingerprint` |
| `defvar` | `my-read-k--current-result` |
| `defvar` | `my-read-k--page-number` |
| `defvar` | `my-read-k--target-title` |
| `defvar` | `my-read-k--target-url` |
| `defvar` | `my-read-k--detected-language` |
| `defvar` | `my-read-k--prefetch-queue` |
| `defvar` | `my-read-k--prefetch-source-fingerprint` |
| `defvar` | `my-read-k--prefetch-attempted-fingerprint` |
| `defvar` | `my-read-k--back-queue` |
| `defvar` | `my-read-k--back-source-fingerprint` |

## my-read/document/kindle/my-read-k2.el

| 宣言 | 名前 |
| --- | --- |
| `defcustom` | `my-read-k2-bridge-program` |
| `defcustom` | `my-read-k2-book-name` |

## my-read/lookup/my-read-lookup.el

| 宣言 | 名前 |
| --- | --- |
| `defcustom` | `my/read-lookup-dictionary-ids` |
| `defcustom` | `my/read-lookup-idle-delay` |
| `defcustom` | `my/read-lookup-entry-window-height` |
| `defvar` | `my/read-lookup-timer` |
| `defvar` | `my/read-lookup-last-target` |
| `defvar` | `my/read-lookup-running-p` |
| `defvar` | `my/read--lookup-module` |
| `defvar` | `my/read--lookup-module-signature` |

## my-read/notes/my-read-org-noter.el

| 宣言 | 名前 |
| --- | --- |
| `defcustom` | `my/read-org-noter-directory` |
| `defcustom` | `my/read-org-noter-file-name` |
| `defvar` | `my/read-org-noter--sync-timer` |

## my-read/document/pdf/my-read-pdf.el

| 宣言 | 名前 |
| --- | --- |
| `defcustom` | `my/read-pdf-continuous-scroll` |

## my-read/position/my-read-position.el

| 宣言 | 名前 |
| --- | --- |
| `defcustom` | `my/read-position-directory` |
| `defcustom` | `my/read-position-save-delay` |
| `defvar-local` | `my/read-position--restored-p` |
| `defvar-local` | `my/read-position--restoring-p` |
| `defvar-local` | `my/read-position--save-timer` |

## my-read/speech/backend-selection/my-read-speech-settings.el

| 宣言 | 名前 |
| --- | --- |
| `defcustom` | `my/read-japanese-speech-backend` |
| `defcustom` | `my/read-japanese-kokoro-voice` |
| `defcustom` | `my/read-japanese-kokoro-speed` |
| `defcustom` | `my/read-japanese-irodori-speed` |
| `defcustom` | `my/read-japanese-macos-voice` |
| `defcustom` | `my/read-japanese-macos-rate` |
| `defcustom` | `my/read-english-macos-rate` |
| `defvar-local` | `my/read-source-language` |
| `defvar-local` | `my/read-speech-language-override` |

## my-read/translation/my-read-translation.el

| 宣言 | 名前 |
| --- | --- |
| `defcustom` | `my/read-translate-idle-delay` |
| `defcustom` | `my/read-translation-backend` |
| `defcustom` | `my/read-local-translation-url` |
| `defcustom` | `my/read-local-translation-model` |
| `defcustom` | `my/read-local-translation-timeout` |
| `defcustom` | `my/read-google-translation-fallback` |
| `defcustom` | `my/read-translate-overlay-opacity` |
| `defcustom` | `my/read-japanese-translation-target-language` |
| `defvar` | `my/read-translate-timer` |
| `defvar` | `my/read-translate-process` |
| `defvar` | `my/read-translate-last-target` |
| `defvar` | `my/read-kokoro-context` |
| `defvar` | `my/read-speech-translation-suppressed-context` |

## my-read/ui/my-read-ui.el

| 宣言 | 名前 |
| --- | --- |
| `defvar` | `lookup-sub-window` |
| `defcustom` | `my/read-book-path` |
| `defcustom` | `my/read-frame-name` |
| `defvar` | `my-read-center-tab-mode-map` |

## my-read/vocabulary/my-read-vocabulary.el

| 宣言 | 名前 |
| --- | --- |
| `defvar` | `lookup-open-function` |
| `defcustom` | `my/read-vocabulary-file` |
| `defcustom` | `my/read-vocab-english-dictionary-title-regexp` |
| `defcustom` | `my/read-vocab-japanese-dictionary-title-regexp` |

## my-read/document/reader-document.el

| 宣言 | 名前 |
| --- | --- |
| `defvar` | `reader-document--backends` |

## my-read/speech/playback/reader-http-playback.el

| 宣言 | 名前 |
| --- | --- |
| `defcustom` | `reader-http-speech-playback-endpoint` |
| `defcustom` | `reader-http-speech-playback-target` |
| `defcustom` | `reader-http-speech-playback-delivery-endpoint` |
| `defvar` | `reader-http-playback--session` |
| `defvar` | `reader-http-playback--delivery-token` |

## my-read/speech/http/reader-http-speech-transport.el

| 宣言 | 名前 |
| --- | --- |
| `defvar` | `reader-http-speech-transport-mode` |

## my-read/speech/http/reader-http-speech.el

| 宣言 | 名前 |
| --- | --- |
| `defcustom` | `reader-http-speech-python` |
| `defcustom` | `reader-http-speech-endpoint` |
| `defcustom` | `reader-http-speech-listen-host` |
| `defcustom` | `reader-http-speech-prebuffer` |
| `defcustom` | `reader-http-speech-player` |
| `defcustom` | `reader-http-speech-english-backend` |
| `defcustom` | `reader-http-speech-japanese-backend` |
| `defcustom` | `reader-http-speech-english-speed` |
| `defcustom` | `reader-http-speech-japanese-speed` |
| `defcustom` | `reader-http-speech-language` |
| `defvar` | `reader-http-speech--process` |
| `defvar` | `reader-http-speech--gui-process` |
| `defvar` | `reader-http-speech-finished-hook` |
| `defvar` | `reader-http-speech-mode-map` |

## my-read/reader-load-path.el

`reader-root-directory` はリポジトリの基準位置、`reader-companion-directory` はruntime資産の基準位置、`reader-module-directories` は概念別の検索先です。
いずれも `defconst` であり、読書sessionの可変状態を所有しません。

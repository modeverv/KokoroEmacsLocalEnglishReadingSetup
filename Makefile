run:
	uv run --extra japanese python kokoro_server.py --host 127.0.0.1 --port 8000

ORG_NOTER_DIR := $(shell find $(HOME)/.emacs.d/elpa -maxdepth 1 -type d -name 'org-noter-*' 2>/dev/null | sort | tail -1)
EMACS ?= /Applications/Emacs-takaxp/Emacs.app/Contents/MacOS/Emacs
READER_ELISP_DIR ?= .
SWIFT_TEST_FLAGS ?=
PDF_TOOLS_DIR := $(shell find $(HOME)/.emacs.d/elpa -maxdepth 1 -type d -name 'pdf-tools-*' 2>/dev/null | sort | tail -1)
MARKDOWN_MODE_DIR := $(shell find $(HOME)/.emacs.d/elpa -maxdepth 1 -type d -name 'markdown-mode-*' 2>/dev/null | sort | tail -1)
TABLIST_DIR := $(shell find $(HOME)/.emacs.d/elpa -maxdepth 1 -type d -name 'tablist-*' 2>/dev/null | sort | tail -1)

.PHONY: my-read-k-build my-read-speech-build my-read-k-test my-read-k-ert my-read-k-check

my-read-k-build:
	swift build --package-path my-read-k2/bridge --configuration release

my-read-speech-build:
	clang -fobjc-arc -O2 -Wall -Wextra \
		-framework Foundation -framework AVFoundation \
		macos-speech-bridge/main.m \
		-o macos-speech-bridge/my-read-speech-bridge

my-read-k-test:
	swift test --package-path my-read-k2/bridge $(SWIFT_TEST_FLAGS) \
		-Xswiftc -F \
		-Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
		-Xlinker -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
		-Xlinker -rpath \
		-Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
		-Xlinker -rpath \
		-Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib

my-read-k-ert:
	READER_TEST_COMPILED_DIR="$(if $(READER_TEST_COMPILED),$(abspath $(READER_ELISP_DIR)))" $(EMACS) -Q --batch -L . -L "$(READER_ELISP_DIR)" \
		-L $(ORG_NOTER_DIR) \
		-L $(PDF_TOOLS_DIR) -L $(TABLIST_DIR) -L $(MARKDOWN_MODE_DIR) \
		--eval "(setq load-prefer-newer t native-comp-jit-compilation nil native-comp-enable-subr-trampolines nil)" \
		-l test/reader-test-source.el \
		-l test/my-read-k-tests.el -l test/my-read-k2-tests.el \
		-l test/reader-document-tests.el -l test/reader-layout-tests.el \
		-f ert-run-tests-batch-and-exit

my-read-k-check: my-read-speech-build my-read-k-test my-read-k-ert

.PHONY: my-read-irodori-setup
my-read-irodori-setup:
	python3 scripts/setup_irodori.py

.PHONY: speech-server speech-gui speech-http-test
speech-server:
	.venv/bin/python -m speech_http.service start

speech-gui:
	.venv/bin/python -m speech_http.gui

speech-http-test:
	.venv/bin/python -m unittest discover -s test -p test_speech_http.py -v
	READER_TEST_COMPILED_DIR="$(if $(READER_TEST_COMPILED),$(abspath $(READER_ELISP_DIR)))" $(EMACS) -Q --batch -L . -L "$(READER_ELISP_DIR)" \
		--eval "(setq load-prefer-newer t)" \
		-l test/reader-test-source.el \
		-l test/reader-http-speech-tests.el -f ert-run-tests-batch-and-exit
	READER_TEST_COMPILED_DIR="$(if $(READER_TEST_COMPILED),$(abspath $(READER_ELISP_DIR)))" $(EMACS) -Q --batch -L . -L "$(READER_ELISP_DIR)" \
		-L $(ORG_NOTER_DIR) -L $(PDF_TOOLS_DIR) -L $(TABLIST_DIR) -L $(MARKDOWN_MODE_DIR) \
		--eval "(setq load-prefer-newer t)" \
		-l test/reader-test-source.el \
		-l test/reader-http-settings-tests.el -f ert-run-tests-batch-and-exit

.PHONY: speech-app-build
speech-app-build:
	.venv/bin/python scripts/build_speech_app.py

.PHONY: speech-playback speech-playback-setup speech-playback-test
speech-playback:
	.venv/bin/python -m speech_http.playback

speech-playback-setup:
	uv sync --locked --inexact --extra playback

.PHONY: speech-playback-app
speech-playback-app:
	python3 scripts/build_playback_app.py

speech-playback-test:
	.venv/bin/python -m unittest discover -s test -p test_playback.py -v
	READER_TEST_COMPILED_DIR="$(if $(READER_TEST_COMPILED),$(abspath $(READER_ELISP_DIR)))" $(EMACS) -Q --batch -L . -L "$(READER_ELISP_DIR)" \
		--eval "(setq load-prefer-newer t)" \
		-l test/reader-test-source.el \
		-l test/reader-http-playback-tests.el -f ert-run-tests-batch-and-exit

.PHONY: reader-check reader-python-test reader-test
reader-check:
	$(EMACS) -Q --batch -l scripts/check-reader.el

reader-python-test:
	.venv/bin/python -m unittest discover -s test -p 'test_*.py' -v
	.venv/bin/python -m unittest discover -s scripts -p 'test_*.py' -v

reader-test: reader-check my-read-k-ert speech-http-test speech-playback-test reader-python-test my-read-k-test

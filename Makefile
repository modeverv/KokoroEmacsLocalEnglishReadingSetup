COMPANION_DIR := $(CURDIR)/companion-implementations
PYTHON := $(COMPANION_DIR)/.venv/bin/python
export PYTHONPATH := $(COMPANION_DIR)$(if $(PYTHONPATH),:$(PYTHONPATH))

run:
	uv run --directory "$(COMPANION_DIR)" --extra japanese python kokoro_server.py --host 127.0.0.1 --port 8000

ORG_NOTER_DIR := $(shell find $(HOME)/.emacs.d/elpa -maxdepth 1 -type d -name 'org-noter-*' 2>/dev/null | sort | tail -1)
EMACS ?= /Applications/Emacs-takaxp/Emacs.app/Contents/MacOS/Emacs
READER_ELISP_DIR ?= .
SWIFT_TEST_FLAGS ?=
PDF_TOOLS_DIR := $(shell find $(HOME)/.emacs.d/elpa -maxdepth 1 -type d -name 'pdf-tools-*' 2>/dev/null | sort | tail -1)
MARKDOWN_MODE_DIR := $(shell find $(HOME)/.emacs.d/elpa -maxdepth 1 -type d -name 'markdown-mode-*' 2>/dev/null | sort | tail -1)
TABLIST_DIR := $(shell find $(HOME)/.emacs.d/elpa -maxdepth 1 -type d -name 'tablist-*' 2>/dev/null | sort | tail -1)

.PHONY: my-read-k-build my-read-speech-build my-read-k-test my-read-k-ert my-read-k-check

my-read-k-build:
	swift build --package-path companion-implementations/my-read-k2/bridge --configuration release

my-read-speech-build:
	clang -fobjc-arc -O2 -Wall -Wextra -mmacosx-version-min=13.0 \
		-framework Foundation -framework AVFoundation \
		companion-implementations/macos-speech-bridge/main.m \
		-o companion-implementations/macos-speech-bridge/my-read-speech-bridge

my-read-k-test:
	swift test --package-path companion-implementations/my-read-k2/bridge $(SWIFT_TEST_FLAGS) \
		-Xswiftc -F \
		-Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
		-Xlinker -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
		-Xlinker -rpath \
		-Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
		-Xlinker -rpath \
		-Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib

READER_ERT_FILES := $(if $(READER_SUITE),test/reader-$(READER_SUITE)-tests.el,test/my-read-k-tests.el test/my-read-k2-tests.el test/reader-document-tests.el test/reader-layout-tests.el test/reader-speech-queue-tests.el test/reader-diagnose-tests.el)

.PHONY: reader-ert
reader-ert: my-read-k-ert

my-read-k-ert:
	READER_TEST_COMPILED_DIR="$(if $(READER_TEST_COMPILED),$(abspath $(READER_ELISP_DIR)))" $(EMACS) -Q --batch -L . -L "$(READER_ELISP_DIR)" \
		-L $(ORG_NOTER_DIR) \
		-L $(PDF_TOOLS_DIR) -L $(TABLIST_DIR) -L $(MARKDOWN_MODE_DIR) \
		--eval "(setq load-prefer-newer t native-comp-jit-compilation nil native-comp-enable-subr-trampolines nil)" \
		-l test/reader-test-source.el \
		$(foreach file,$(READER_ERT_FILES),-l $(file)) \
		-f ert-run-tests-batch-and-exit

my-read-k-check: my-read-speech-build my-read-k-test my-read-k-ert

.PHONY: my-read-irodori-setup
my-read-irodori-setup:
	python3 scripts/setup_irodori.py

.PHONY: speech-server speech-gui speech-http-test
speech-server:
	$(PYTHON) -m speech_http.service start

speech-gui:
	$(PYTHON) -m speech_http.gui

.PHONY: speech-dictionary
speech-dictionary:
	$(PYTHON) -m speech_http.dictionary_ui

speech-http-test:
	$(PYTHON) -m unittest discover -s test -p test_speech_http.py -v
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
	$(PYTHON) scripts/build_speech_app.py

.PHONY: speech-playback speech-playback-stop speech-playback-status speech-playback-foreground speech-playback-setup speech-playback-test
speech-playback:
	$(PYTHON) -m speech_http.playback_service start

speech-playback-stop:
	$(PYTHON) -m speech_http.playback_service stop

speech-playback-status:
	$(PYTHON) -m speech_http.playback_service status

speech-playback-foreground:
	$(PYTHON) -m speech_http.playback

speech-playback-setup:
	uv sync --directory "$(COMPANION_DIR)" --locked --inexact --extra playback

.PHONY: speech-playback-app
speech-playback-app:
	python3 scripts/build_playback_app.py

speech-playback-test:
	$(PYTHON) -m unittest discover -s test -p 'test_playback*.py' -v
	READER_TEST_COMPILED_DIR="$(if $(READER_TEST_COMPILED),$(abspath $(READER_ELISP_DIR)))" $(EMACS) -Q --batch -L . -L "$(READER_ELISP_DIR)" \
		--eval "(setq load-prefer-newer t)" \
		-l test/reader-test-source.el \
		-l test/reader-http-playback-tests.el -f ert-run-tests-batch-and-exit

.PHONY: reader-check reader-python-test reader-test
reader-check:
	$(EMACS) -Q --batch -l scripts/check-reader.el

reader-python-test:
	$(PYTHON) -m unittest discover -s test -p 'test_*.py' -v
	$(PYTHON) -m unittest discover -s scripts -p 'test_*.py' -v

reader-test: reader-check my-read-k-ert speech-http-test speech-playback-test reader-python-test my-read-k-test

.PHONY: speech-native-test
speech-native-test: my-read-speech-build
	READER_NATIVE_AUDIO_TESTS=1 $(PYTHON) -m unittest discover -s test -p test_macos_speech_bridge.py -v

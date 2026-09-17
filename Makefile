run:
	uv run --extra japanese python kokoro_server.py --host 127.0.0.1 --port 8000

ORG_NOTER_DIR := $(shell find $(HOME)/.emacs.d/elpa -maxdepth 1 -type d -name 'org-noter-*' 2>/dev/null | sort | tail -1)
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
	swift test --package-path my-read-k2/bridge \
		-Xswiftc -F \
		-Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
		-Xlinker -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
		-Xlinker -rpath \
		-Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
		-Xlinker -rpath \
		-Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib

my-read-k-ert:
	/Applications/Emacs-takaxp/Emacs.app/Contents/MacOS/Emacs -Q --batch -L . \
		-L $(ORG_NOTER_DIR) \
		-L $(PDF_TOOLS_DIR) -L $(TABLIST_DIR) -L $(MARKDOWN_MODE_DIR) \
		--eval "(setq native-comp-jit-compilation nil native-comp-enable-subr-trampolines nil)" \
		-l test/my-read-k-tests.el -l test/my-read-k2-tests.el \
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
	/Applications/Emacs-takaxp/Emacs.app/Contents/MacOS/Emacs -Q --batch -L . \
		-l test/reader-http-speech-tests.el -f ert-run-tests-batch-and-exit
	/Applications/Emacs-takaxp/Emacs.app/Contents/MacOS/Emacs -Q --batch -L . \
		-L $(ORG_NOTER_DIR) -L $(PDF_TOOLS_DIR) -L $(TABLIST_DIR) -L $(MARKDOWN_MODE_DIR) \
		-l test/reader-http-settings-tests.el -f ert-run-tests-batch-and-exit

.PHONY: speech-app-build
speech-app-build:
	.venv/bin/python scripts/build_speech_app.py

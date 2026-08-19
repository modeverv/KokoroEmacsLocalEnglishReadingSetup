run:
	uv run python kokoro_server.py --host 127.0.0.1 --port 8000

.PHONY: my-read-k-build my-read-k-test my-read-k-ert my-read-k-check

my-read-k-build:
	swift build --package-path my-read-k/bridge --configuration release

my-read-k-test:
	swift test --package-path my-read-k/bridge

my-read-k-ert:
	/Applications/Emacs-takaxp/Emacs.app/Contents/MacOS/Emacs -Q --batch -L . \
		-l test/my-read-k-tests.el -f ert-run-tests-batch-and-exit

my-read-k-check: my-read-k-test my-read-k-ert

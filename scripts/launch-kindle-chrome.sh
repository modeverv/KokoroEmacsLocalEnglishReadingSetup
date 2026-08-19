#!/bin/zsh
set -euo pipefail

port="${MY_READ_K_CDP_PORT:-9000}"
profile="${MY_READ_K_CHROME_PROFILE:-$HOME/Library/Application Support/my-read-k-chrome}"
chrome="${MY_READ_K_CHROME_APP:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

exec "$chrome" \
  --remote-debugging-port="$port" \
  --remote-debugging-address=127.0.0.1 \
  --user-data-dir="$profile" \
  "https://read.amazon.co.jp/"

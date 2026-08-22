#!/bin/sh
set -eu

destination_dir=${MY_READ_K_TESSDATA:-"$HOME/Library/Caches/my-read-k/tessdata"}
destination="$destination_dir/jpn_vert.traineddata"
url="https://github.com/tesseract-ocr/tessdata_best/raw/main/jpn_vert.traineddata"
expected_sha256="1258be6eb2a9851f18043234ad18cca13ed32690bfff62b335c898bbea371548"

if ! command -v tesseract >/dev/null 2>&1; then
  echo "tesseract がありません。先に brew install tesseract を実行してください。" >&2
  exit 1
fi

mkdir -p "$destination_dir"
temporary=$(mktemp "$destination_dir/.jpn_vert.XXXXXX")
trap 'rm -f "$temporary"' EXIT HUP INT TERM

curl --fail --location --progress-bar "$url" --output "$temporary"
actual_sha256=$(shasum -a 256 "$temporary" | awk '{print $1}')
if [ "$actual_sha256" != "$expected_sha256" ]; then
  echo "jpn_vert.traineddata のSHA-256が一致しません。" >&2
  exit 1
fi

mv "$temporary" "$destination"
trap - EXIT HUP INT TERM
echo "縦書き日本語OCRモデルを配置しました: $destination"

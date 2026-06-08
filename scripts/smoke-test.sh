#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/bazarr-ai-subtitle-translator.XXXXXX")

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

cat > "$WORK_DIR/sample.en.srt" <<'EOF'
1
00:00:01,000 --> 00:00:03,000
Hello, everyone. Welcome back.

2
00:00:03,500 --> 00:00:06,000
Today we are going to test subtitle translation.
EOF

"$PROJECT_DIR/scripts/translate-srt-upstream.sh" "$WORK_DIR/sample.en.srt"

test -s "$WORK_DIR/sample.zh.srt"
grep -q -- "-->" "$WORK_DIR/sample.zh.srt"

echo "smoke-test: ok"


#!/usr/bin/env sh
set -eu

if [ "$#" -lt 1 ]; then
  echo "usage: bazarr-postprocess.sh <subtitle-path>" >&2
  exit 2
fi

SUBTITLE_PATH="$1"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

if [ ! -f "$SUBTITLE_PATH" ]; then
  echo "subtitle-translator: file not found: $SUBTITLE_PATH" >&2
  exit 1
fi

case "$SUBTITLE_PATH" in
  *.srt|*.SRT) ;;
  *)
    echo "subtitle-translator: skip non-SRT file: $SUBTITLE_PATH"
    exit 0
    ;;
esac

case "$SUBTITLE_PATH" in
  *.en.srt|*.eng.srt|*.en.SRT|*.eng.SRT) ;;
  *)
    echo "subtitle-translator: skip subtitle that does not look English: $SUBTITLE_PATH"
    exit 0
    ;;
esac

FORCE_FLAG=""
if [ "${SUBTRANS_FORCE:-0}" = "1" ]; then
  FORCE_FLAG="--force"
fi

if [ -n "$FORCE_FLAG" ]; then
  SUBTRANS_FORCE=1 "$PROJECT_DIR/scripts/translate-srt-upstream.sh" "$SUBTITLE_PATH"
else
  "$PROJECT_DIR/scripts/translate-srt-upstream.sh" "$SUBTITLE_PATH"
fi

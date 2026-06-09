#!/usr/bin/env sh
set -eu

if [ "$#" -lt 1 ]; then
  echo "usage: bazarr-postprocess.sh <subtitle-path>" >&2
  exit 2
fi

SUBTITLE_PATH="$1"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

if [ -f "$PROJECT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$PROJECT_DIR/.env"
  set +a
fi

SOURCE_SUFFIXES="${SUBTRANS_SOURCE_SUFFIXES:-en,eng,english}"

if [ ! -f "$SUBTITLE_PATH" ]; then
  echo "subtitle-translator: file not found: $SUBTITLE_PATH" >&2
  exit 1
fi

case "$SUBTITLE_PATH" in
  *.[sS][rR][tT]) ;;
  *)
    echo "subtitle-translator: skip non-SRT file: $SUBTITLE_PATH"
    exit 0
    ;;
esac

SOURCE_STEM=$(INPUT_PATH="$SUBTITLE_PATH" SOURCE_SUFFIXES="$SOURCE_SUFFIXES" awk '
  BEGIN {
    path = ENVIRON["INPUT_PATH"]
    suffixes = ENVIRON["SOURCE_SUFFIXES"]
    noext = path
    sub(/\.[sS][rR][tT]$/, "", noext)
    lower = tolower(noext)
    split(suffixes, parts, ",")
    for (i in parts) {
      suffix = tolower(parts[i])
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", suffix)
      if (suffix == "") continue
      for (sep_i = 1; sep_i <= 2; sep_i++) {
        sep = sep_i == 1 ? "." : "_"
        needle = sep suffix
        start = length(lower) - length(needle) + 1
        if (start > 0 && substr(lower, start) == needle) {
          print substr(noext, 1, length(noext) - length(needle))
          exit
        }
      }
    }
  }
')

if [ -z "$SOURCE_STEM" ]; then
  echo "subtitle-translator: skip subtitle that does not match configured source suffixes ($SOURCE_SUFFIXES): $SUBTITLE_PATH"
  exit 0
fi

if [ "${SUBTRANS_FORCE:-0}" = "1" ]; then
  SUBTRANS_FORCE=1 "$PROJECT_DIR/scripts/translate-srt-upstream.sh" "$SUBTITLE_PATH"
else
  "$PROJECT_DIR/scripts/translate-srt-upstream.sh" "$SUBTITLE_PATH"
fi

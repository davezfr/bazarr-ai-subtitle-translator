#!/usr/bin/env sh
set -eu

if [ "$#" -lt 1 ]; then
  echo "usage: translate-srt-upstream.sh <input.<source>.srt> [output.<target>.srt|output.<target>.ass]" >&2
  exit 2
fi

INPUT_PATH="$1"
OUTPUT_PATH="${2:-}"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

if [ -f "$PROJECT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$PROJECT_DIR/.env"
  set +a
fi

RUNTIME_DIR="${SUBTRANS_RUNTIME_DIR:-$PROJECT_DIR/.runtime}"
UPSTREAM_DIR="${SUBTRANS_UPSTREAM_DIR:-$RUNTIME_DIR/chatgpt-subtitle-translator}"
FORMAT_PROMPT_FILE="${SUBTRANS_FORMAT_PROMPT_FILE:-$PROJECT_DIR/prompts/format-contract-system.md}"
PROMPT_FILE="${SUBTRANS_PROMPT_FILE:-$PROJECT_DIR/prompts/xiaohu-style-system.md}"
SOURCE_LANGUAGE="${SUBTRANS_SOURCE_LANGUAGE:-English}"
TARGET_LANGUAGE="${SUBTRANS_TARGET_LANGUAGE:-Simplified Chinese}"
SOURCE_SUFFIXES="${SUBTRANS_SOURCE_SUFFIXES:-en,eng,english}"
TARGET_SUFFIX="${SUBTRANS_TARGET_SUFFIX:-zh}"
OUTPUT_MODE=$(printf '%s' "${SUBTRANS_OUTPUT_MODE:-target}" | tr '[:upper:]' '[:lower:]')
OUTPUT_FORMAT_ENV="${SUBTRANS_OUTPUT_FORMAT:-}"

if [ ! -f "$INPUT_PATH" ]; then
  echo "subtitle-translator: input not found: $INPUT_PATH" >&2
  exit 1
fi

case "$INPUT_PATH" in
  *.[sS][rR][tT]) ;;
  *)
    echo "subtitle-translator: only SRT is supported by the upstream MVP: $INPUT_PATH" >&2
    exit 1
    ;;
esac

SOURCE_MATCH=$(INPUT_PATH="$INPUT_PATH" SOURCE_SUFFIXES="$SOURCE_SUFFIXES" awk '
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
          print sep
          exit
        }
      }
    }
  }
')
SOURCE_STEM=$(printf '%s\n' "$SOURCE_MATCH" | sed -n '1p')
SOURCE_SEPARATOR=$(printf '%s\n' "$SOURCE_MATCH" | sed -n '2p')

if [ -z "$SOURCE_STEM" ]; then
  echo "subtitle-translator: input subtitle does not match configured source suffixes ($SOURCE_SUFFIXES): $INPUT_PATH" >&2
  exit 1
fi

case "$OUTPUT_MODE" in
  target|bilingual) ;;
  *)
    echo "subtitle-translator: unsupported output mode: $OUTPUT_MODE" >&2
    exit 1
    ;;
esac

if [ -n "$OUTPUT_FORMAT_ENV" ]; then
  OUTPUT_FORMAT=$(printf '%s' "$OUTPUT_FORMAT_ENV" | tr '[:upper:]' '[:lower:]')
elif [ -n "$OUTPUT_PATH" ]; then
  case "$OUTPUT_PATH" in
    *.[aA][sS][sS]) OUTPUT_FORMAT="ass" ;;
    *) OUTPUT_FORMAT="srt" ;;
  esac
else
  OUTPUT_FORMAT="srt"
fi

case "$OUTPUT_FORMAT" in
  srt|ass) ;;
  *)
    echo "subtitle-translator: unsupported output format: $OUTPUT_FORMAT" >&2
    exit 1
    ;;
esac

if [ "$OUTPUT_MODE" = "bilingual" ] && [ "$OUTPUT_FORMAT" != "ass" ]; then
  echo "subtitle-translator: bilingual output requires ASS output format" >&2
  exit 1
fi

if [ -z "$OUTPUT_PATH" ]; then
  OUTPUT_PATH="$SOURCE_STEM$SOURCE_SEPARATOR$TARGET_SUFFIX.$OUTPUT_FORMAT"
fi

if [ -f "$OUTPUT_PATH" ] && [ "${SUBTRANS_FORCE:-0}" != "1" ]; then
  echo "subtitle-translator: output already exists, skipping: $OUTPUT_PATH"
  exit 0
fi

if [ ! -f "$UPSTREAM_DIR/cli/translator.mjs" ]; then
  echo "subtitle-translator: upstream is not installed. Run:" >&2
  echo "  $PROJECT_DIR/scripts/install-upstream.sh" >&2
  exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
  echo "subtitle-translator: prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

if [ ! -f "$FORMAT_PROMPT_FILE" ]; then
  echo "subtitle-translator: format prompt file not found: $FORMAT_PROMPT_FILE" >&2
  exit 1
fi

INPUT_COUNT=$(grep -c -- "-->" "$INPUT_PATH" || true)
if [ "$INPUT_COUNT" -eq 0 ]; then
  echo "subtitle-translator: input has no SRT timestamp rows: $INPUT_PATH" >&2
  exit 1
fi

TMP_OUTPUT="$OUTPUT_PATH.tmp.$$"
rm -f "$TMP_OUTPUT"

SYSTEM_INSTRUCTION=$(
  printf 'Source language: %s\n' "$SOURCE_LANGUAGE"
  printf 'Target language: %s\n' "$TARGET_LANGUAGE"
  printf 'Output mode requested by wrapper: %s\n\n' "$OUTPUT_MODE"
  cat "$FORMAT_PROMPT_FILE"
  printf '\n\n--- Style and translation guidance ---\n\n'
  cat "$PROMPT_FILE"
)

OPENAI_BASE_URL="${OPENAI_BASE_URL:-${SUBTRANS_BASE_URL:-http://127.0.0.1:11434/v1}}" \
OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}" \
node "$UPSTREAM_DIR/cli/translator.mjs" \
  --input "$INPUT_PATH" \
  --output "$TMP_OUTPUT" \
  --from "$SOURCE_LANGUAGE" \
  --to "$TARGET_LANGUAGE" \
  --model "${SUBTRANS_MODEL:-gemma4:latest}" \
  --structured "${SUBTRANS_STRUCTURED:-array}" \
  --context "${SUBTRANS_CONTEXT_TOKENS:-2000}" \
  --temperature "${SUBTRANS_TEMPERATURE:-0}" \
  --system-instruction "$SYSTEM_INSTRUCTION" \
  --no-stream \
  --log-level "${SUBTRANS_LOG_LEVEL:-warn}"

OUTPUT_COUNT=$(grep -c -- "-->" "$TMP_OUTPUT" || true)
if [ "$INPUT_COUNT" -ne "$OUTPUT_COUNT" ]; then
  rm -f "$TMP_OUTPUT"
  echo "subtitle-translator: timestamp count mismatch: input=$INPUT_COUNT output=$OUTPUT_COUNT" >&2
  exit 1
fi

EMPTY_OUTPUT_COUNT=$(awk '
  function close_cue() {
    if (in_cue && !has_text) empty += 1
    in_cue = 0
    has_text = 0
  }
  /-->/ {
    close_cue()
    in_cue = 1
    has_text = 0
    next
  }
  in_cue {
    line = $0
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
    if (line == "") {
      close_cue()
      next
    }
    has_text = 1
  }
  END {
    close_cue()
    print empty + 0
  }
' "$TMP_OUTPUT")

if [ "$EMPTY_OUTPUT_COUNT" -gt 0 ]; then
  rm -f "$TMP_OUTPUT"
  echo "subtitle-translator: empty translated subtitle entries: $EMPTY_OUTPUT_COUNT" >&2
  exit 1
fi

TMP_CLEAN_OUTPUT="$OUTPUT_PATH.clean.$$"
python3 "$PROJECT_DIR/scripts/clean-srt-display.py" "$TMP_OUTPUT" "$TMP_CLEAN_OUTPUT"
mv "$TMP_CLEAN_OUTPUT" "$TMP_OUTPUT"

if [ "$OUTPUT_FORMAT" = "ass" ]; then
  set -- \
    --source "$INPUT_PATH" \
    --target "$TMP_OUTPUT" \
    --output "$OUTPUT_PATH" \
    --mode "$OUTPUT_MODE"
  if [ -n "${SUBTRANS_ASS_TARGET_SIZE:-}" ]; then
    set -- "$@" --target-size "$SUBTRANS_ASS_TARGET_SIZE"
  fi
  if [ -n "${SUBTRANS_ASS_SOURCE_SIZE:-}" ]; then
    set -- "$@" --source-size "$SUBTRANS_ASS_SOURCE_SIZE"
  fi
  if [ -n "${SUBTRANS_ASS_HEIGHT:-}" ]; then
    set -- "$@" --height "$SUBTRANS_ASS_HEIGHT"
  fi
  if [ -n "${SUBTRANS_ASS_MARGINV:-}" ]; then
    set -- "$@" --marginv "$SUBTRANS_ASS_MARGINV"
  fi
  if [ -n "${SUBTRANS_ASS_FONT:-}" ]; then
    set -- "$@" --font "$SUBTRANS_ASS_FONT"
  fi
  if [ -n "${SUBTRANS_ASS_SOURCE_FONT:-}" ]; then
    set -- "$@" --source-font "$SUBTRANS_ASS_SOURCE_FONT"
  fi

  python3 "$PROJECT_DIR/scripts/build-ass-subtitle.py" "$@"
  rm -f "$TMP_OUTPUT"
else
  mv "$TMP_OUTPUT" "$OUTPUT_PATH"
fi

echo "subtitle-translator: wrote $OUTPUT_PATH ($OUTPUT_COUNT entries, $OUTPUT_FORMAT/$OUTPUT_MODE)"

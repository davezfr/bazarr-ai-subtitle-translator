#!/usr/bin/env sh
set -eu

if [ "$#" -lt 1 ]; then
  echo "usage: translate-srt-upstream.sh <input.en.srt> [output.zh.srt]" >&2
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
PROMPT_FILE="${SUBTRANS_PROMPT_FILE:-$PROJECT_DIR/prompts/xiaohu-style-system.md}"

if [ ! -f "$INPUT_PATH" ]; then
  echo "subtitle-translator: input not found: $INPUT_PATH" >&2
  exit 1
fi

case "$INPUT_PATH" in
  *.srt|*.SRT) ;;
  *)
    echo "subtitle-translator: only SRT is supported by the upstream MVP: $INPUT_PATH" >&2
    exit 1
    ;;
esac

if [ -z "$OUTPUT_PATH" ]; then
  case "$INPUT_PATH" in
    *.en.srt) OUTPUT_PATH="${INPUT_PATH%.en.srt}.zh.srt" ;;
    *.eng.srt) OUTPUT_PATH="${INPUT_PATH%.eng.srt}.zh.srt" ;;
    *.english.srt) OUTPUT_PATH="${INPUT_PATH%.english.srt}.zh.srt" ;;
    *.EN.SRT) OUTPUT_PATH="${INPUT_PATH%.EN.SRT}.zh.srt" ;;
    *.ENG.SRT) OUTPUT_PATH="${INPUT_PATH%.ENG.SRT}.zh.srt" ;;
    *.srt) OUTPUT_PATH="${INPUT_PATH%.srt}.zh.srt" ;;
    *.SRT) OUTPUT_PATH="${INPUT_PATH%.SRT}.zh.srt" ;;
  esac
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

INPUT_COUNT=$(grep -c -- "-->" "$INPUT_PATH" || true)
if [ "$INPUT_COUNT" -eq 0 ]; then
  echo "subtitle-translator: input has no SRT timestamp rows: $INPUT_PATH" >&2
  exit 1
fi

TMP_OUTPUT="$OUTPUT_PATH.tmp.$$"
rm -f "$TMP_OUTPUT"

OPENAI_BASE_URL="${OPENAI_BASE_URL:-${SUBTRANS_BASE_URL:-http://127.0.0.1:11434/v1}}" \
OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}" \
node "$UPSTREAM_DIR/cli/translator.mjs" \
  --input "$INPUT_PATH" \
  --output "$TMP_OUTPUT" \
  --model "${SUBTRANS_MODEL:-gemma4:latest}" \
  --structured "${SUBTRANS_STRUCTURED:-array}" \
  --context "${SUBTRANS_CONTEXT_TOKENS:-2000}" \
  --temperature "${SUBTRANS_TEMPERATURE:-0}" \
  --system-instruction "$(cat "$PROMPT_FILE")" \
  --no-stream \
  --log-level "${SUBTRANS_LOG_LEVEL:-warn}"

OUTPUT_COUNT=$(grep -c -- "-->" "$TMP_OUTPUT" || true)
if [ "$INPUT_COUNT" -ne "$OUTPUT_COUNT" ]; then
  rm -f "$TMP_OUTPUT"
  echo "subtitle-translator: timestamp count mismatch: input=$INPUT_COUNT output=$OUTPUT_COUNT" >&2
  exit 1
fi

mv "$TMP_OUTPUT" "$OUTPUT_PATH"
echo "subtitle-translator: wrote $OUTPUT_PATH ($OUTPUT_COUNT entries)"

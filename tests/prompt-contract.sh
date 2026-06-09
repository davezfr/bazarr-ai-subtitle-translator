#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
PROMPT_FILE="$PROJECT_DIR/prompts/xiaohu-style-system.md"
ENDPOINT_PROMPT_FILE="$PROJECT_DIR/prompts/endpoint-format-contract-system.md"

fail() {
  echo "prompt-contract: $*" >&2
  exit 1
}

grep -q "This prompt is language-neutral" "$PROMPT_FILE" \
  || fail "style prompt must declare language-neutral behavior"

grep -q "protected source terms" "$PROMPT_FILE" \
  || fail "style prompt must define protected source terms"

grep -q "Copy protected names from the source subtitles" "$PROMPT_FILE" \
  || fail "style prompt must preserve protected names"

grep -q "translating, transliterating, localizing, or renaming" "$PROMPT_FILE" \
  || fail "style prompt must prevent implicit protected-term localization"

grep -q "Generic role or speaker labels are not names" "$PROMPT_FILE" \
  || fail "style prompt must keep generic speaker labels translatable"

grep -q "should not be copied as source terms" "$PROMPT_FILE" \
  || fail "style prompt must prevent generic labels from being over-protected"

grep -q "Translate generic speaker labels naturally" "$PROMPT_FILE" \
  || fail "style prompt must require generic speaker labels to be translated"

grep -q "keep a translated speaker label at the beginning" "$PROMPT_FILE" \
  || fail "style prompt must preserve leading speaker label structure"

grep -q "API worker" "$ENDPOINT_PROMPT_FILE" \
  || fail "endpoint prompt must define the endpoint API-worker role"

grep -q "translations.*array length must equal the number of input items" "$ENDPOINT_PROMPT_FILE" \
  || fail "endpoint prompt must require one translation per input item"

grep -q "higher priority than fluent writing" "$ENDPOINT_PROMPT_FILE" \
  || fail "endpoint prompt must make cue boundaries higher priority than fluent writing"

echo "prompt-contract: ok"

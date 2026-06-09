#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
PROMPT_FILE="$PROJECT_DIR/prompts/xiaohu-style-system.md"

fail() {
  echo "prompt-contract: $*" >&2
  exit 1
}

grep -q "Keep personal names in their original Latin spelling" "$PROMPT_FILE" \
  || fail "style prompt must preserve personal names in Latin spelling"

grep -q "Generic speaker labels may be translated" "$PROMPT_FILE" \
  || fail "style prompt must allow generic speaker labels to be translated"

echo "prompt-contract: ok"

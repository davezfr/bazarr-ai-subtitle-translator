#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

fail() {
  echo "wrapper-behavior: $*" >&2
  exit 1
}

make_srt() {
  cat > "$1" <<'EOF'
1
00:00:01,000 --> 00:00:03,000
Hello, everyone.
EOF
}

make_french_srt() {
  cat > "$1" <<'EOF'
1
00:00:01,000 --> 00:00:03,000
Bonjour à tous.
EOF
}

make_fake_upstream() {
  upstream_dir="$1"
  mkdir -p "$upstream_dir/cli"
  cat > "$upstream_dir/cli/translator.mjs" <<'EOF'
import fs from 'node:fs'

const args = process.argv.slice(2)
let input = ''
let output = ''

for (let index = 0; index < args.length; index += 1) {
  if (args[index] === '--input') input = args[index + 1] || ''
  if (args[index] === '--output') output = args[index + 1] || ''
}

if (!input || !output) {
  process.stderr.write('fake translator missing --input or --output\n')
  process.exit(2)
}

fs.copyFileSync(input, output)
EOF
}

make_empty_body_fake_upstream() {
  upstream_dir="$1"
  mkdir -p "$upstream_dir/cli"
  cat > "$upstream_dir/cli/translator.mjs" <<'EOF'
import fs from 'node:fs'

const args = process.argv.slice(2)
let output = ''

for (let index = 0; index < args.length; index += 1) {
  if (args[index] === '--output') output = args[index + 1] || ''
}

if (!output) {
  process.stderr.write('fake translator missing --output\n')
  process.exit(2)
}

fs.writeFileSync(output, `1
00:00:01,000 --> 00:00:03,000

`)
EOF
}

make_contract_checking_fake_upstream() {
  upstream_dir="$1"
  mkdir -p "$upstream_dir/cli"
  cat > "$upstream_dir/cli/translator.mjs" <<'EOF'
import fs from 'node:fs'

const args = process.argv.slice(2)
let input = ''
let output = ''
let systemInstruction = ''

for (let index = 0; index < args.length; index += 1) {
  if (args[index] === '--input') input = args[index + 1] || ''
  if (args[index] === '--output') output = args[index + 1] || ''
  if (args[index] === '--system-instruction') systemInstruction = args[index + 1] || ''
}

if (!input || !output) {
  process.stderr.write('fake translator missing --input or --output\n')
  process.exit(2)
}

if (!systemInstruction.includes('FORMAT_CONTRACT_SENTINEL')) {
  process.stderr.write('system instruction missing format contract\n')
  process.exit(42)
}

if (!systemInstruction.includes('STYLE_PROMPT_SENTINEL')) {
  process.stderr.write('system instruction missing style prompt\n')
  process.exit(43)
}

fs.copyFileSync(input, output)
EOF
}

make_translating_fake_upstream() {
  upstream_dir="$1"
  mkdir -p "$upstream_dir/cli"
  cat > "$upstream_dir/cli/translator.mjs" <<'EOF'
import fs from 'node:fs'

const args = process.argv.slice(2)
let output = ''

for (let index = 0; index < args.length; index += 1) {
  if (args[index] === '--output') output = args[index + 1] || ''
}

if (!output) {
  process.stderr.write('fake translator missing --output\n')
  process.exit(2)
}

fs.writeFileSync(output, `1
00:00:01,000 --> 00:00:03,000
大家好。

`)
EOF
}

run_wrapper() {
  SUBTRANS_UPSTREAM_DIR="$1" \
  SUBTRANS_PROMPT_FILE="$PROJECT_DIR/prompts/xiaohu-style-system.md" \
  OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  OPENAI_API_KEY="test" \
  SUBTRANS_MODEL="test-model" \
    "$PROJECT_DIR/scripts/translate-srt-upstream.sh" "$2"
}

run_wrapper_with_prompts() {
  SUBTRANS_UPSTREAM_DIR="$1" \
  SUBTRANS_FORMAT_PROMPT_FILE="$2" \
  SUBTRANS_PROMPT_FILE="$3" \
  OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  OPENAI_API_KEY="test" \
  SUBTRANS_MODEL="test-model" \
    "$PROJECT_DIR/scripts/translate-srt-upstream.sh" "$4"
}

run_wrapper_with_settings() {
  upstream_dir="$1"
  input_path="$2"
  shift 2

  env \
    SUBTRANS_UPSTREAM_DIR="$upstream_dir" \
    SUBTRANS_PROMPT_FILE="$PROJECT_DIR/prompts/xiaohu-style-system.md" \
    OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
    OPENAI_API_KEY="test" \
    SUBTRANS_MODEL="test-model" \
    "$@" \
    "$PROJECT_DIR/scripts/translate-srt-upstream.sh" "$input_path"
}

test_rejects_non_english_srt() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-wrapper-test.XXXXXX")
  upstream_dir="$work_dir/upstream"
  input="$work_dir/movie.fr.srt"

  make_fake_upstream "$upstream_dir"
  make_srt "$input"

  set +e
  output=$(run_wrapper "$upstream_dir" "$input" 2>&1)
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    fail "expected non-English SRT to be rejected, got success"
  fi

  case "$output" in
    *"does not match configured source suffixes"*) ;;
    *) fail "expected configured source suffix guard message, got: $output" ;;
  esac

  if [ -e "$work_dir/movie.fr.zh.srt" ]; then
    fail "non-English SRT should not produce output"
  fi

  rm -rf "$work_dir"
}

test_en_uppercase_extension_writes_zh_sidecar() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-wrapper-test.XXXXXX")
  upstream_dir="$work_dir/upstream"
  input="$work_dir/movie.en.SRT"

  make_fake_upstream "$upstream_dir"
  make_srt "$input"

  run_wrapper "$upstream_dir" "$input" >/dev/null

  if [ ! -s "$work_dir/movie.zh.srt" ]; then
    fail "expected movie.en.SRT to write movie.zh.srt"
  fi

  if [ -e "$work_dir/movie.en.zh.srt" ]; then
    fail "movie.en.SRT should not produce movie.en.zh.srt"
  fi

  rm -rf "$work_dir"
}

test_mixed_case_english_suffix_writes_zh_sidecar() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-wrapper-test.XXXXXX")
  upstream_dir="$work_dir/upstream"
  input="$work_dir/movie.Eng.SrT"

  make_fake_upstream "$upstream_dir"
  make_srt "$input"

  run_wrapper "$upstream_dir" "$input" >/dev/null

  if [ ! -s "$work_dir/movie.zh.srt" ]; then
    fail "expected movie.Eng.SrT to write movie.zh.srt"
  fi

  rm -rf "$work_dir"
}

test_rejects_empty_translated_cue_text() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-wrapper-test.XXXXXX")
  upstream_dir="$work_dir/upstream"
  input="$work_dir/movie.en.srt"

  make_empty_body_fake_upstream "$upstream_dir"
  make_srt "$input"

  set +e
  output=$(run_wrapper "$upstream_dir" "$input" 2>&1)
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    fail "expected empty translated cue text to be rejected, got success"
  fi

  case "$output" in
    *"empty translated subtitle entries"*) ;;
    *) fail "expected empty translated subtitle entry message, got: $output" ;;
  esac

  if [ -e "$work_dir/movie.zh.srt" ]; then
    fail "empty translated cue text should not produce final output"
  fi

  rm -rf "$work_dir"
}

test_prepends_format_contract_to_style_prompt() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-wrapper-test.XXXXXX")
  upstream_dir="$work_dir/upstream"
  input="$work_dir/movie.en.srt"
  format_prompt="$work_dir/format-contract.md"
  style_prompt="$work_dir/style-prompt.md"

  make_contract_checking_fake_upstream "$upstream_dir"
  make_srt "$input"
  printf '%s\n' 'FORMAT_CONTRACT_SENTINEL' > "$format_prompt"
  printf '%s\n' 'STYLE_PROMPT_SENTINEL' > "$style_prompt"

  run_wrapper_with_prompts "$upstream_dir" "$format_prompt" "$style_prompt" "$input" >/dev/null

  if [ ! -s "$work_dir/movie.zh.srt" ]; then
    fail "expected composed prompt run to write movie.zh.srt"
  fi

  rm -rf "$work_dir"
}

test_allows_configured_french_source_suffix() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-wrapper-test.XXXXXX")
  upstream_dir="$work_dir/upstream"
  input="$work_dir/movie.fr.srt"

  make_fake_upstream "$upstream_dir"
  make_french_srt "$input"

  run_wrapper_with_settings \
    "$upstream_dir" \
    "$input" \
    SUBTRANS_SOURCE_LANGUAGE="French" \
    SUBTRANS_SOURCE_SUFFIXES="fr,fra,french" \
    SUBTRANS_TARGET_LANGUAGE="Simplified Chinese" \
    SUBTRANS_TARGET_SUFFIX="zh" \
    >/dev/null

  if [ ! -s "$work_dir/movie.zh.srt" ]; then
    fail "expected configured French source to write movie.zh.srt"
  fi

  rm -rf "$work_dir"
}

test_allows_underscore_source_suffix_and_preserves_separator() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-wrapper-test.XXXXXX")
  upstream_dir="$work_dir/upstream"
  input="$work_dir/2_English.srt"

  make_fake_upstream "$upstream_dir"
  make_srt "$input"

  run_wrapper_with_settings \
    "$upstream_dir" \
    "$input" \
    SUBTRANS_TARGET_SUFFIX="Chinese" \
    >/dev/null

  if [ ! -s "$work_dir/2_Chinese.srt" ]; then
    fail "expected underscore source suffix to write 2_Chinese.srt"
  fi

  rm -rf "$work_dir"
}

test_rejects_srt_bilingual_mode() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-wrapper-test.XXXXXX")
  upstream_dir="$work_dir/upstream"
  input="$work_dir/movie.en.srt"

  make_translating_fake_upstream "$upstream_dir"
  make_srt "$input"

  set +e
  output=$(run_wrapper_with_settings \
    "$upstream_dir" \
    "$input" \
    SUBTRANS_OUTPUT_FORMAT="srt" \
    SUBTRANS_OUTPUT_MODE="bilingual" \
    2>&1)
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    fail "expected srt bilingual mode to be rejected, got success"
  fi

  case "$output" in
    *"bilingual output requires ASS"*) ;;
    *) fail "expected srt bilingual rejection message, got: $output" ;;
  esac

  rm -rf "$work_dir"
}

test_writes_bilingual_ass_with_target_then_source() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-wrapper-test.XXXXXX")
  upstream_dir="$work_dir/upstream"
  input="$work_dir/movie.fr.srt"
  output_ass="$work_dir/movie.zh.ass"

  make_translating_fake_upstream "$upstream_dir"
  make_french_srt "$input"

  run_wrapper_with_settings \
    "$upstream_dir" \
    "$input" \
    SUBTRANS_SOURCE_LANGUAGE="French" \
    SUBTRANS_SOURCE_SUFFIXES="fr,fra,french" \
    SUBTRANS_TARGET_LANGUAGE="Simplified Chinese" \
    SUBTRANS_TARGET_SUFFIX="zh" \
    SUBTRANS_OUTPUT_FORMAT="ass" \
    SUBTRANS_OUTPUT_MODE="bilingual" \
    >/dev/null

  if [ ! -s "$output_ass" ]; then
    fail "expected bilingual ASS output at $output_ass"
  fi

  grep -q "\\[Script Info\\]" "$output_ass" || fail "expected ASS header"
  grep -q "Style: Primary" "$output_ass" || fail "expected primary-language ASS style"
  grep -q "Style: Secondary" "$output_ass" || fail "expected secondary-language ASS style"
  grep -q "Dialogue: 1,0:00:01.00,0:00:03.00,Primary" "$output_ass" || fail "expected target text in Primary dialogue"
  grep -q "Dialogue: 0,0:00:01.00,0:00:03.00,Secondary" "$output_ass" || fail "expected source text in Secondary dialogue"
  grep -q "大家好" "$output_ass" || fail "expected target text in ASS subtitle"
  if grep -q "大家好。" "$output_ass"; then
    fail "expected bilingual ASS target text to remove terminal Chinese full stop"
  fi
  grep -q "Bonjour à tous" "$output_ass" || fail "expected source text in ASS subtitle"

  rm -rf "$work_dir"
}

test_bilingual_ass_default_output_uses_target_language_suffix() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-wrapper-test.XXXXXX")
  upstream_dir="$work_dir/upstream"
  input="$work_dir/movie.en.srt"

  make_translating_fake_upstream "$upstream_dir"
  make_srt "$input"

  run_wrapper_with_settings \
    "$upstream_dir" \
    "$input" \
    SUBTRANS_SOURCE_LANGUAGE="English" \
    SUBTRANS_SOURCE_SUFFIXES="en,eng,english" \
    SUBTRANS_TARGET_LANGUAGE="French" \
    SUBTRANS_TARGET_SUFFIX="fr" \
    SUBTRANS_OUTPUT_FORMAT="ass" \
    SUBTRANS_OUTPUT_MODE="bilingual" \
    SUBTRANS_ASS_PRIMARY_SCRIPT="latin" \
    SUBTRANS_ASS_SECONDARY_SCRIPT="latin" \
    >/dev/null

  if [ ! -s "$work_dir/movie.fr.ass" ]; then
    fail "expected bilingual ASS output to use target/primary language suffix"
  fi

  if [ -e "$work_dir/movie.en.ass" ] || [ -e "$work_dir/movie.en-fr.ass" ] || [ -e "$work_dir/movie.bilingual.ass" ]; then
    fail "bilingual ASS output should not use source, pair, or bilingual suffixes"
  fi

  rm -rf "$work_dir"
}

test_bilingual_ass_accepts_font_name_with_spaces() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-wrapper-test.XXXXXX")
  upstream_dir="$work_dir/upstream"
  input="$work_dir/movie.en.srt"
  output_ass="$work_dir/movie.zh.ass"

  make_translating_fake_upstream "$upstream_dir"
  make_srt "$input"

  run_wrapper_with_settings \
    "$upstream_dir" \
    "$input" \
    SUBTRANS_OUTPUT_FORMAT="ass" \
    SUBTRANS_OUTPUT_MODE="bilingual" \
    SUBTRANS_ASS_FONT="PingFang SC" \
    >/dev/null

  grep -q "Style: Primary,PingFang SC" "$output_ass" || fail "expected target ASS font with spaces to be preserved"

  rm -rf "$work_dir"
}

test_bilingual_ass_accepts_source_font_name_with_spaces() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-wrapper-test.XXXXXX")
  upstream_dir="$work_dir/upstream"
  input="$work_dir/movie.en.srt"
  output_ass="$work_dir/movie.zh.ass"

  make_translating_fake_upstream "$upstream_dir"
  make_srt "$input"

  run_wrapper_with_settings \
    "$upstream_dir" \
    "$input" \
    SUBTRANS_OUTPUT_FORMAT="ass" \
    SUBTRANS_OUTPUT_MODE="bilingual" \
    SUBTRANS_ASS_SOURCE_FONT="Noto Sans" \
    >/dev/null

  grep -q "Style: Secondary,Noto Sans" "$output_ass" || fail "expected source ASS font with spaces to be preserved"

  rm -rf "$work_dir"
}

test_bilingual_ass_accepts_latin_primary_script_profile() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-wrapper-test.XXXXXX")
  upstream_dir="$work_dir/upstream"
  input="$work_dir/movie.en.srt"
  output_ass="$work_dir/movie.zh.ass"

  make_translating_fake_upstream "$upstream_dir"
  make_srt "$input"

  run_wrapper_with_settings \
    "$upstream_dir" \
    "$input" \
    SUBTRANS_OUTPUT_FORMAT="ass" \
    SUBTRANS_OUTPUT_MODE="bilingual" \
    SUBTRANS_ASS_HEIGHT="1080" \
    SUBTRANS_ASS_PRIMARY_SCRIPT="latin" \
    SUBTRANS_ASS_SECONDARY_SCRIPT="latin" \
    >/dev/null

  grep -q "Style: Primary,Arial,48" "$output_ass" || fail "expected latin primary script profile to use latin primary style"
  grep -q "Style: Secondary,Arial,34" "$output_ass" || fail "expected latin primary script profile to use latin secondary style"

  rm -rf "$work_dir"
}

test_bilingual_ass_accepts_primary_secondary_style_overrides() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-wrapper-test.XXXXXX")
  upstream_dir="$work_dir/upstream"
  input="$work_dir/movie.en.srt"
  output_ass="$work_dir/movie.zh.ass"

  make_translating_fake_upstream "$upstream_dir"
  make_srt "$input"

  run_wrapper_with_settings \
    "$upstream_dir" \
    "$input" \
    SUBTRANS_OUTPUT_FORMAT="ass" \
    SUBTRANS_OUTPUT_MODE="bilingual" \
    SUBTRANS_ASS_PRIMARY_FONT="Noto Sans" \
    SUBTRANS_ASS_SECONDARY_FONT="Helvetica Neue" \
    SUBTRANS_ASS_PRIMARY_SIZE="50" \
    SUBTRANS_ASS_SECONDARY_SIZE="33" \
    >/dev/null

  grep -q "Style: Primary,Noto Sans,50" "$output_ass" || fail "expected primary ASS style overrides to be preserved"
  grep -q "Style: Secondary,Helvetica Neue,33" "$output_ass" || fail "expected secondary ASS style overrides to be preserved"

  rm -rf "$work_dir"
}

test_srt_output_cleans_terminal_statement_punctuation() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-wrapper-test.XXXXXX")
  upstream_dir="$work_dir/upstream"
  input="$work_dir/movie.en.srt"
  output_srt="$work_dir/movie.zh.srt"

  make_translating_fake_upstream "$upstream_dir"
  make_srt "$input"

  run_wrapper_with_settings \
    "$upstream_dir" \
    "$input" \
    >/dev/null

  grep -q "大家好" "$output_srt" || fail "expected translated text in SRT output"
  if grep -q "大家好。" "$output_srt"; then
    fail "expected SRT target text to remove terminal Chinese full stop"
  fi

  rm -rf "$work_dir"
}

test_rejects_non_english_srt
test_en_uppercase_extension_writes_zh_sidecar
test_mixed_case_english_suffix_writes_zh_sidecar
test_rejects_empty_translated_cue_text
test_prepends_format_contract_to_style_prompt
test_allows_configured_french_source_suffix
test_allows_underscore_source_suffix_and_preserves_separator
test_rejects_srt_bilingual_mode
test_writes_bilingual_ass_with_target_then_source
test_bilingual_ass_default_output_uses_target_language_suffix
test_bilingual_ass_accepts_font_name_with_spaces
test_bilingual_ass_accepts_source_font_name_with_spaces
test_bilingual_ass_accepts_latin_primary_script_profile
test_bilingual_ass_accepts_primary_secondary_style_overrides
test_srt_output_cleans_terminal_statement_punctuation

echo "wrapper-behavior: ok"

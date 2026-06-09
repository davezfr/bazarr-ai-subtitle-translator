#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

fail() {
  echo "workflow-cli: $*" >&2
  exit 1
}

make_sample_srt() {
  cat > "$1" <<'EOF'
1
00:00:01,000 --> 00:00:03,000
Hello there.

2
00:00:04,000 --> 00:00:06,000
Wait...
EOF
}

test_default_workflow_writes_primary_srt() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-workflow-test.XXXXXX")
  input="$work_dir/movie.EN.srt"
  summary="$work_dir/workflow-summary.json"

  make_sample_srt "$input"

  python3 "$PROJECT_DIR/scripts/subtitle-workflow.py" \
    --input "$input" \
    --target-language "Simplified Chinese" \
    --target-suffix zh \
    --backend fake \
    --summary "$summary" >/dev/null

  if [ ! -s "$work_dir/movie.zh.srt" ]; then
    fail "expected workflow to write primary SRT with target suffix"
  fi
  if [ -e "$work_dir/movie.EN.zh.srt" ]; then
    fail "workflow should strip source suffix when deriving output stem"
  fi
  grep -q '"output_format": "srt"' "$summary" || fail "summary should record SRT format"
  grep -q '"alignment_check": "off"' "$summary" || fail "summary should record default alignment mode"
  grep -q '"ass_output": null' "$summary" || fail "summary should not record ASS output for default SRT workflow"

  rm -rf "$work_dir"
}

test_bilingual_srt_is_rejected() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-workflow-test.XXXXXX")
  input="$work_dir/movie.en.srt"
  make_sample_srt "$input"

  set +e
  output=$(python3 "$PROJECT_DIR/scripts/subtitle-workflow.py" \
    --input "$input" \
    --target-suffix zh \
    --output-mode bilingual \
    --output-format srt \
    --backend fake 2>&1)
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    fail "expected bilingual SRT workflow to be rejected"
  fi
  case "$output" in
    *"bilingual output requires ASS"*) ;;
    *) fail "expected bilingual ASS requirement message, got: $output" ;;
  esac

  rm -rf "$work_dir"
}

test_bilingual_ass_writes_primary_srt_and_ass() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-workflow-test.XXXXXX")
  input="$work_dir/movie.en.srt"

  make_sample_srt "$input"

  python3 "$PROJECT_DIR/scripts/subtitle-workflow.py" \
    --input "$input" \
    --target-language French \
    --target-suffix fr \
    --output-mode bilingual \
    --backend fake \
    --ass-height 1080 \
    --primary-script latin \
    --secondary-script latin >/dev/null

  if [ ! -s "$work_dir/movie.fr.srt" ]; then
    fail "bilingual workflow should keep primary SRT artifact"
  fi
  if [ ! -s "$work_dir/movie.fr.ass" ]; then
    fail "bilingual workflow should write primary-language ASS sidecar"
  fi
  dialogue_count=$(grep -c '^Dialogue:' "$work_dir/movie.fr.ass")
  if [ "$dialogue_count" -ne 4 ]; then
    fail "expected two dialogue events per cue, got $dialogue_count"
  fi
  grep -F -q -- 'Style: Primary,Arial,48,&H00FFFFFF' "$work_dir/movie.fr.ass" \
    || fail "French primary workflow should use latin primary ASS preset"

  rm -rf "$work_dir"
}

test_target_ass_writes_single_language_ass() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-workflow-test.XXXXXX")
  input="$work_dir/movie.en.srt"

  make_sample_srt "$input"

  python3 "$PROJECT_DIR/scripts/subtitle-workflow.py" \
    --input "$input" \
    --target-suffix zh \
    --output-format ass \
    --output-mode target \
    --backend fake \
    --ass-height 1080 >/dev/null

  if [ ! -s "$work_dir/movie.zh.srt" ]; then
    fail "target ASS workflow should keep primary SRT artifact"
  fi
  if [ ! -s "$work_dir/movie.zh.ass" ]; then
    fail "target ASS workflow should write ASS sidecar"
  fi
  grep -q '^Style: Default,' "$work_dir/movie.zh.ass" || fail "target ASS should use single-language Default style"
  if grep -q '^Style: Secondary,' "$work_dir/movie.zh.ass"; then
    fail "target ASS should not include secondary style"
  fi

  rm -rf "$work_dir"
}

test_workflow_rejects_cli_command_backend() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-workflow-test.XXXXXX")
  input="$work_dir/movie.en.srt"

  make_sample_srt "$input"
  set +e
  output=$(python3 "$PROJECT_DIR/scripts/subtitle-workflow.py" \
    --input "$input" \
    --target-suffix zh \
    --backend cli-command 2>&1)
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    fail "workflow should reject unsupported public cli-command backend"
  fi
  case "$output" in
    *"invalid choice: 'cli-command'"*) ;;
    *) fail "expected cli-command backend to be rejected, got: $output" ;;
  esac

  rm -rf "$work_dir"
}

test_workflow_exposes_codex_cli_backend() {
  help_text=$(python3 "$PROJECT_DIR/scripts/subtitle-workflow.py" --help)
  case "$help_text" in
    *"codex-cli"*) ;;
    *) fail "workflow help should expose codex-cli as the stable local runner" ;;
  esac
}

test_workflow_does_not_expose_scheduling_flags() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-workflow-test.XXXXXX")
  input="$work_dir/movie.en.srt"
  make_sample_srt "$input"

  for flag in "--concurrency 1" "--chunk-size 1"; do
    set +e
    output=$(python3 "$PROJECT_DIR/scripts/subtitle-workflow.py" \
      --input "$input" \
      --target-suffix zh \
      --backend fake \
      $flag 2>&1)
    status=$?
    set -e

    if [ "$status" -eq 0 ]; then
      fail "workflow should not expose public scheduling flag: $flag"
    fi
    case "$output" in
      *"unrecognized arguments"*) ;;
      *) fail "expected scheduling flag to be rejected, got: $output" ;;
    esac
  done

  rm -rf "$work_dir"
}

test_default_workflow_writes_primary_srt
test_bilingual_srt_is_rejected
test_bilingual_ass_writes_primary_srt_and_ass
test_target_ass_writes_single_language_ass
test_workflow_rejects_cli_command_backend
test_workflow_exposes_codex_cli_backend
test_workflow_does_not_expose_scheduling_flags

echo "workflow-cli: ok"

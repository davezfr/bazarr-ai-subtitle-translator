#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

fail() {
  echo "v2-translator: $*" >&2
  exit 1
}

make_sample_srt() {
  cat > "$1" <<'EOF'
1
00:00:01,000 --> 00:00:03,000
Hello there.

2
00:00:03,500 --> 00:00:05,000
How are you?
EOF
}

test_fake_worker_rebuilds_srt_from_source_structure() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-v2-test.XXXXXX")
  input="$work_dir/movie.en.srt"
  output="$work_dir/movie.zh.srt"
  summary="$work_dir/summary.json"

  make_sample_srt "$input"

  python3 "$PROJECT_DIR/scripts/translate-srt-v2.py" \
    --input "$input" \
    --output "$output" \
    --summary "$summary" \
    --backend fake \
    --chunk-size 1 \
    --concurrency 2 >/dev/null

  grep -q '^1$' "$output" || fail "missing cue 1"
  grep -q '^2$' "$output" || fail "missing cue 2"
  grep -q '00:00:01,000 --> 00:00:03,000' "$output" || fail "cue 1 timestamp changed"
  grep -q '00:00:03,500 --> 00:00:05,000' "$output" || fail "cue 2 timestamp changed"
  grep -q '假译：Hello there.' "$output" || fail "missing fake translation for cue 1"
  grep -q '假译：How are you?' "$output" || fail "missing fake translation for cue 2"
  grep -q '"cue_count": 2' "$summary" || fail "summary missing cue count"
  grep -q '"translation_seconds"' "$summary" || fail "summary missing translation timing"

  rm -rf "$work_dir"
}

test_validator_rejects_extra_worker_cue() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-v2-test.XXXXXX")
  input="$work_dir/movie.en.srt"
  output="$work_dir/movie.zh.srt"

  make_sample_srt "$input"

  set +e
  output_text=$(python3 "$PROJECT_DIR/scripts/translate-srt-v2.py" \
    --input "$input" \
    --output "$output" \
    --backend fake-extra \
    --chunk-size 2 \
    --concurrency 1 2>&1)
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    fail "expected fake-extra worker output to fail validation"
  fi

  case "$output_text" in
    *"translation count mismatch"*) ;;
    *) fail "expected count mismatch error, got: $output_text" ;;
  esac

  if [ -e "$output" ]; then
    fail "invalid worker output should not write final SRT"
  fi

  rm -rf "$work_dir"
}

test_fake_worker_rebuilds_srt_from_source_structure
test_validator_rejects_extra_worker_cue

echo "v2-translator: ok"

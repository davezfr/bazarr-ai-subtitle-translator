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
  grep -q '假译：Hello there' "$output" || fail "missing fake translation for cue 1"
  if grep -q '假译：Hello there\.' "$output"; then
    fail "display cleanup should remove terminal English period in V2 SRT output"
  fi
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

test_ass_header_includes_playres() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-v2-test.XXXXXX")
  source="$work_dir/movie.en.srt"
  target="$work_dir/movie.zh.srt"
  output="$work_dir/movie.zh.ass"

  make_sample_srt "$source"
  cat > "$target" <<'EOF'
1
00:00:01,000 --> 00:00:03,000
你好。

2
00:00:03,500 --> 00:00:05,000
你好吗？
EOF

  python3 "$PROJECT_DIR/scripts/build-ass-subtitle.py" \
    --source "$source" \
    --target "$target" \
    --output "$output" \
    --mode bilingual \
    --height 1080 >/dev/null

  grep -q '^PlayResX: 1920$' "$output" || fail "ASS header missing PlayResX"
  grep -q '^PlayResY: 1080$' "$output" || fail "ASS header missing PlayResY"

  rm -rf "$work_dir"
}

test_bilingual_ass_uses_layered_two_line_layout() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-v2-test.XXXXXX")
  source="$work_dir/movie.en.srt"
  target="$work_dir/movie.zh.srt"
  output="$work_dir/movie.zh.ass"

  cat > "$source" <<'EOF'
1
00:00:01,000 --> 00:00:03,000
- Watch it, asshole.
- So, uh, when's the next date?
EOF

  cat > "$target" <<'EOF'
1
00:00:01,000 --> 00:00:03,000
- 小心点，混蛋。
- 那么，呃，下次约会什么时候？
EOF

  python3 "$PROJECT_DIR/scripts/build-ass-subtitle.py" \
    --source "$source" \
    --target "$target" \
    --output "$output" \
    --mode bilingual \
    --height 1080 >/dev/null

  grep -F -q -- 'Style: ZH,PingFang SC,56,&H00FFFFFF' "$output" \
    || fail "bilingual ASS should define a target-language ZH style"
  grep -F -q -- 'Style: EN,Arial,36,&H00D6F4FF' "$output" \
    || fail "bilingual ASS should define a source-language EN style"
  grep -F -q -- 'Dialogue: 1,0:00:01.00,0:00:03.00,ZH,,0,0,0,,- 小心点，混蛋 - 那么，呃，下次约会什么时候？' "$output" \
    || fail "bilingual ASS should flatten target text into one styled dialogue line"
  grep -F -q -- 'Dialogue: 0,0:00:01.00,0:00:03.00,EN,,0,0,0,,- Watch it, asshole - So, uh, when'\''s the next date?' "$output" \
    || fail "bilingual ASS should flatten source text into one styled dialogue line"

  rm -rf "$work_dir"
}

test_bilingual_ass_flattens_cjk_without_extra_spaces() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-v2-test.XXXXXX")
  source="$work_dir/movie.en.srt"
  target="$work_dir/movie.zh.srt"
  output="$work_dir/movie.zh.ass"

  cat > "$source" <<'EOF'
1
00:00:01,000 --> 00:00:03,000
That's the tragedy of you being blind,
you've never seen me dance.
EOF

  cat > "$target" <<'EOF'
1
00:00:01,000 --> 00:00:03,000
你看不见的悲哀就在这儿，
你从没见过我跳舞。
EOF

  python3 "$PROJECT_DIR/scripts/build-ass-subtitle.py" \
    --source "$source" \
    --target "$target" \
    --output "$output" \
    --mode bilingual \
    --height 1080 >/dev/null

  grep -F -q -- '你看不见的悲哀就在这儿，你从没见过我跳舞' "$output" \
    || fail "bilingual ASS should flatten adjacent CJK lines without inserting spaces"
  grep -F -q -- "That's the tragedy of you being blind, you've never seen me dance" "$output" \
    || fail "bilingual ASS should keep spaces when flattening Latin lines"

  rm -rf "$work_dir"
}

test_display_punctuation_cleanup_preserves_non_statement_endings() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-v2-test.XXXXXX")
  source="$work_dir/movie.en.srt"
  target="$work_dir/movie.zh.srt"
  output="$work_dir/movie.zh.ass"

  cat > "$source" <<'EOF'
1
00:00:01,000 --> 00:00:03,000
Do you believe him?

2
00:00:04,000 --> 00:00:06,000
I just thought...

3
00:00:07,000 --> 00:00:09,000
I live in the U.S.
EOF

  cat > "$target" <<'EOF'
1
00:00:01,000 --> 00:00:03,000
你真的相信他吗？

2
00:00:04,000 --> 00:00:06,000
我只是觉得…

3
00:00:07,000 --> 00:00:09,000
我在美国。
EOF

  python3 "$PROJECT_DIR/scripts/build-ass-subtitle.py" \
    --source "$source" \
    --target "$target" \
    --output "$output" \
    --mode bilingual \
    --height 1080 >/dev/null

  grep -F -q -- '你真的相信他吗？' "$output" \
    || fail "display cleanup should preserve Chinese question marks"
  grep -F -q -- 'Do you believe him?' "$output" \
    || fail "display cleanup should preserve English question marks"
  grep -F -q -- '我只是觉得…' "$output" \
    || fail "display cleanup should preserve Chinese ellipsis"
  grep -F -q -- 'I just thought...' "$output" \
    || fail "display cleanup should preserve English ellipsis"
  grep -F -q -- '我在美国' "$output" \
    || fail "display cleanup should remove terminal Chinese full stop"
  grep -F -q -- 'I live in the U.S.' "$output" \
    || fail "display cleanup should preserve protected terminal abbreviations"

  rm -rf "$work_dir"
}

test_fake_worker_rebuilds_srt_from_source_structure
test_validator_rejects_extra_worker_cue
test_ass_header_includes_playres
test_bilingual_ass_uses_layered_two_line_layout
test_bilingual_ass_flattens_cjk_without_extra_spaces
test_display_punctuation_cleanup_preserves_non_statement_endings

echo "v2-translator: ok"

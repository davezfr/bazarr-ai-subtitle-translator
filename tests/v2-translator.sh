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

make_srt_with_cue_count() {
  output="$1"
  count="$2"
  : > "$output"
  index=1
  while [ "$index" -le "$count" ]; do
    cat >> "$output" <<EOF
$index
00:00:01,000 --> 00:00:02,000
Line $index.

EOF
    index=$((index + 1))
  done
}

assert_auto_concurrency() {
  cue_count="$1"
  expected="$2"
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-v2-test.XXXXXX")
  input="$work_dir/movie.en.srt"
  output="$work_dir/movie.zh.srt"
  summary="$work_dir/summary.json"

  make_srt_with_cue_count "$input" "$cue_count"

  python3 "$PROJECT_DIR/scripts/translate-srt-v2.py" \
    --input "$input" \
    --output "$output" \
    --summary "$summary" \
    --backend fake >/dev/null

  grep -q "\"cue_count\": $cue_count" "$summary" || fail "summary missing cue count $cue_count"
  grep -q "\"chunk_size\": 100" "$summary" || fail "summary should use the internal chunk size"
  grep -q "\"concurrency\": $expected" "$summary" || fail "expected auto concurrency $expected for $cue_count cues"
  grep -q '"concurrency_policy": "auto_by_cue_count"' "$summary" || fail "summary should record auto concurrency policy"

  rm -rf "$work_dir"
}

test_auto_concurrency_policy_uses_internal_thresholds() {
  assert_auto_concurrency 250 2
  assert_auto_concurrency 251 3
  assert_auto_concurrency 501 4
  assert_auto_concurrency 801 6
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
    --backend fake >/dev/null

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
    2>&1)
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

test_cli_command_backend_rebuilds_srt() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-v2-test.XXXXXX")
  input="$work_dir/movie.en.srt"
  output="$work_dir/movie.zh.srt"
  fake_cli="$work_dir/fake-cli.py"

  make_sample_srt "$input"
  cat > "$fake_cli" <<'PY'
import json
import re
import sys

prompt = sys.stdin.read()
match = re.search(r"Input JSON:\n(\{.*\})\s*$", prompt, re.S)
if not match:
    raise SystemExit("missing Input JSON")
payload = json.loads(match.group(1))
translations = [
    {"number": item["number"], "translation": f"CLI {item['text']}"}
    for item in payload["items"]
]
print(json.dumps({"translations": translations}, ensure_ascii=False))
PY

  python3 "$PROJECT_DIR/scripts/translate-srt-v2.py" \
    --input "$input" \
    --output "$output" \
    --backend cli-command \
    --cli-command "python3 $fake_cli" >/dev/null

  grep -q 'CLI Hello there' "$output" || fail "cli-command backend should write translated cue 1"
  grep -q 'CLI How are you?' "$output" || fail "cli-command backend should write translated cue 2"

  rm -rf "$work_dir"
}

test_openai_compatible_backend_rebuilds_srt() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-v2-test.XXXXXX")
  input="$work_dir/movie.en.srt"
  output="$work_dir/movie.zh.srt"
  server="$work_dir/fake-openai.py"
  port_file="$work_dir/port"

  make_sample_srt "$input"
  cat > "$server" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import re
import sys
from pathlib import Path


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length).decode("utf-8"))
        prompt = next(
            message["content"]
            for message in body["messages"]
            if message.get("role") == "user"
        )
        match = re.search(r"Input JSON:\n(\{.*\})\s*$", prompt, re.S)
        if not match:
            self.send_response(400)
            self.end_headers()
            return
        payload = json.loads(match.group(1))
        translations = [
            {"number": item["number"], "translation": f"API {item['text']}"}
            for item in payload["items"]
        ]
        content = json.dumps({"translations": translations}, ensure_ascii=False)
        response = {"choices": [{"message": {"content": content}}]}
        raw = json.dumps(response).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, format, *args):
        return


httpd = HTTPServer(("127.0.0.1", 0), Handler)
Path(sys.argv[1]).write_text(str(httpd.server_port), encoding="utf-8")
httpd.serve_forever()
PY

  python3 "$server" "$port_file" &
  server_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$port_file" ] && break
    sleep 0.05
  done
  if [ ! -s "$port_file" ]; then
    kill "$server_pid" 2>/dev/null || true
    fail "fake OpenAI-compatible endpoint did not start"
  fi
  port=$(cat "$port_file")

  python3 "$PROJECT_DIR/scripts/translate-srt-v2.py" \
    --input "$input" \
    --output "$output" \
    --backend openai-compatible \
    --model test-model \
    --openai-base-url "http://127.0.0.1:$port/v1" \
    --openai-api-key test \
    --openai-response-format none >/dev/null

  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true

  grep -q 'API Hello there' "$output" || fail "openai-compatible backend should write translated cue 1"
  grep -q 'API How are you?' "$output" || fail "openai-compatible backend should write translated cue 2"

  rm -rf "$work_dir"
}

test_openai_compatible_backend_accepts_text_aliases() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-v2-test.XXXXXX")
  input="$work_dir/movie.en.srt"
  output="$work_dir/movie.zh.srt"
  server="$work_dir/fake-openai.py"
  port_file="$work_dir/port"

  make_sample_srt "$input"
  cat > "$server" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import re
import sys
from pathlib import Path


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length).decode("utf-8"))
        prompt = next(
            message["content"]
            for message in body["messages"]
            if message.get("role") == "user"
        )
        match = re.search(r"Input JSON:\n(\{.*\})\s*$", prompt, re.S)
        if not match:
            self.send_response(400)
            self.end_headers()
            return
        payload = json.loads(match.group(1))
        items = [
            {"number": item["number"], "text": f"Alias {item['text']}"}
            for item in payload["items"]
        ]
        content = "Returning JSON now. " + json.dumps({"items": items}, ensure_ascii=False)
        response = {"choices": [{"message": {"content": content}}]}
        raw = json.dumps(response).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, format, *args):
        return


httpd = HTTPServer(("127.0.0.1", 0), Handler)
Path(sys.argv[1]).write_text(str(httpd.server_port), encoding="utf-8")
httpd.serve_forever()
PY

  python3 "$server" "$port_file" &
  server_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$port_file" ] && break
    sleep 0.05
  done
  if [ ! -s "$port_file" ]; then
    kill "$server_pid" 2>/dev/null || true
    fail "fake OpenAI-compatible endpoint did not start"
  fi
  port=$(cat "$port_file")

  python3 "$PROJECT_DIR/scripts/translate-srt-v2.py" \
    --input "$input" \
    --output "$output" \
    --backend openai-compatible \
    --model test-model \
    --openai-base-url "http://127.0.0.1:$port/v1" \
    --openai-api-key test \
    --openai-response-format none >/dev/null

  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true

  grep -q 'Alias Hello there' "$output" || fail "openai-compatible backend should accept items/text alias for cue 1"
  grep -q 'Alias How are you?' "$output" || fail "openai-compatible backend should accept items/text alias for cue 2"

  rm -rf "$work_dir"
}

test_endpoint_backend_uses_endpoint_prompt_only_for_endpoint() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-v2-test.XXXXXX")
  input="$work_dir/movie.en.srt"
  output="$work_dir/movie.zh.srt"
  server="$work_dir/fake-openai.py"
  port_file="$work_dir/port"
  request_file="$work_dir/request.json"

  make_sample_srt "$input"
  cat > "$server" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import re
import sys
from pathlib import Path


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length).decode("utf-8"))
        Path(sys.argv[2]).write_text(json.dumps(body, ensure_ascii=False), encoding="utf-8")
        prompt = next(
            message["content"]
            for message in body["messages"]
            if message.get("role") == "user"
        )
        match = re.search(r"Input JSON:\n(\{.*\})\s*$", prompt, re.S)
        if not match:
            self.send_response(400)
            self.end_headers()
            return
        payload = json.loads(match.group(1))
        translations = [
            {"number": item["number"], "translation": f"API {item['text']}"}
            for item in payload["items"]
        ]
        content = json.dumps({"translations": translations}, ensure_ascii=False)
        response = {"choices": [{"message": {"content": content}}]}
        raw = json.dumps(response).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, format, *args):
        return


httpd = HTTPServer(("127.0.0.1", 0), Handler)
Path(sys.argv[1]).write_text(str(httpd.server_port), encoding="utf-8")
httpd.serve_forever()
PY

  python3 "$server" "$port_file" "$request_file" &
  server_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$port_file" ] && break
    sleep 0.05
  done
  if [ ! -s "$port_file" ]; then
    kill "$server_pid" 2>/dev/null || true
    fail "fake OpenAI-compatible endpoint did not start"
  fi
  port=$(cat "$port_file")

  python3 "$PROJECT_DIR/scripts/translate-srt-v2.py" \
    --input "$input" \
    --output "$output" \
    --backend openai-compatible \
    --model test-model \
    --openai-base-url "http://127.0.0.1:$port/v1" \
    --openai-api-key test \
    --openai-response-format none \
    --work-dir "$work_dir/endpoint-work" \
    --keep-work-dir >/dev/null

  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true

  python3 - "$request_file" <<'PY'
import json
import sys

body = json.loads(open(sys.argv[1], encoding="utf-8").read())
messages = body["messages"]
if messages[0].get("role") != "system":
    raise SystemExit("first endpoint message should be a system prompt")
if "Endpoint-only output contract" not in messages[0].get("content", ""):
    raise SystemExit("endpoint system prompt missing endpoint contract")
if messages[1].get("role") != "user":
    raise SystemExit("second endpoint message should be the user translation prompt")
if "Input JSON:" not in messages[1].get("content", ""):
    raise SystemExit("user translation prompt missing input payload")
if "Endpoint-only output contract" in messages[1].get("content", ""):
    raise SystemExit("endpoint contract should live in system prompt, not user prompt")
PY

  endpoint_prompt="$work_dir/endpoint-work/chunk-001/chunk-001-translate-attempt-1.prompt.txt"
  if grep -q 'Endpoint-only output contract' "$endpoint_prompt"; then
    fail "debug prompt file should contain the user translation prompt only"
  fi

  fake_cli="$work_dir/fake-cli.py"
  cat > "$fake_cli" <<'PY'
import json
import re
import sys

prompt = sys.stdin.read()
match = re.search(r"Input JSON:\n(\{.*\})\s*$", prompt, re.S)
if not match:
    raise SystemExit("missing Input JSON")
payload = json.loads(match.group(1))
translations = [
    {"number": item["number"], "translation": f"CLI {item['text']}"}
    for item in payload["items"]
]
print(json.dumps({"translations": translations}, ensure_ascii=False))
PY

  python3 "$PROJECT_DIR/scripts/translate-srt-v2.py" \
    --input "$input" \
    --output "$work_dir/movie-cli.zh.srt" \
    --backend cli-command \
    --cli-command "python3 $fake_cli" \
    --work-dir "$work_dir/cli-work" \
    --keep-work-dir >/dev/null

  cli_prompt="$work_dir/cli-work/chunk-001/chunk-001-translate-attempt-1.prompt.txt"
  if grep -q 'Endpoint-only output contract' "$cli_prompt"; then
    fail "cli-command backend should keep the existing non-endpoint prompt"
  fi

  rm -rf "$work_dir"
}

test_alignment_check_ignores_non_hard_issues() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-v2-test.XXXXXX")
  input="$work_dir/movie.en.srt"
  output="$work_dir/movie.zh.srt"
  fake_cli="$work_dir/fake-cli.py"

  make_sample_srt "$input"
  cat > "$fake_cli" <<'PY'
import json
import re
import sys

prompt = sys.stdin.read()
if "Semantic alignment" in prompt:
    print(json.dumps({
        "issues": [
            {
                "number": "1",
                "severity": "warn",
                "reason": "translation is slightly less literal but still belongs to this cue",
            },
            {
                "number": "2",
                "issue": "candidate translation is acceptable, no issue",
            },
        ]
    }, ensure_ascii=False))
    raise SystemExit(0)

match = re.search(r"Input JSON:\n(\{.*\})\s*$", prompt, re.S)
if not match:
    raise SystemExit("missing Input JSON")
payload = json.loads(match.group(1))
translations = [
    {"number": item["number"], "translation": f"CLI {item['text']}"}
    for item in payload["items"]
]
print(json.dumps({"translations": translations}, ensure_ascii=False))
PY

  python3 "$PROJECT_DIR/scripts/translate-srt-v2.py" \
    --input "$input" \
    --output "$output" \
    --backend cli-command \
    --cli-command "python3 $fake_cli" \
    --alignment-check model \
    --max-retries 1 >/dev/null

  grep -q 'CLI Hello there' "$output" || fail "non-hard alignment issues should not block cue 1"
  grep -q 'CLI How are you?' "$output" || fail "non-hard alignment issues should not block cue 2"

  rm -rf "$work_dir"
}

test_alignment_check_rejects_shifted_cli_output() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-v2-test.XXXXXX")
  input="$work_dir/movie.en.srt"
  output="$work_dir/movie.zh.srt"
  fake_cli="$work_dir/fake-cli.py"

  make_sample_srt "$input"
  cat > "$fake_cli" <<'PY'
import json
import re
import sys

prompt = sys.stdin.read()
if "Semantic alignment" in prompt:
    print(json.dumps({
        "issues": [
            {
                "number": "1",
                "issue_type": "wrong_cue",
            },
            {
                "number": "2",
                "issue": "cross_cue_shift",
            }
        ]
    }, ensure_ascii=False))
    raise SystemExit(0)

match = re.search(r"Input JSON:\n(\{.*\})\s*$", prompt, re.S)
if not match:
    raise SystemExit("missing Input JSON")
payload = json.loads(match.group(1))
items = payload["items"]
translations = []
for index, item in enumerate(items):
    shifted = items[(index + 1) % len(items)]
    translations.append({"number": item["number"], "translation": f"CLI {shifted['text']}"})
print(json.dumps({"translations": translations}, ensure_ascii=False))
PY

  set +e
  output_text=$(python3 "$PROJECT_DIR/scripts/translate-srt-v2.py" \
    --input "$input" \
    --output "$output" \
    --backend cli-command \
    --cli-command "python3 $fake_cli" \
    --alignment-check model \
    --max-retries 1 2>&1)
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    fail "expected semantic alignment issue to fail validation"
  fi

  case "$output_text" in
    *"semantic alignment"*) ;;
    *) fail "expected semantic alignment error, got: $output_text" ;;
  esac

  if [ -e "$output" ]; then
    fail "semantic alignment failure should not write final SRT"
  fi

  rm -rf "$work_dir"
}

test_validator_rejects_dropped_leading_speaker_label() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-v2-test.XXXXXX")
  input="$work_dir/movie.en.srt"
  output="$work_dir/movie.zh.srt"
  fake_cli="$work_dir/fake-cli.py"

  cat > "$input" <<'EOF'
1
00:00:01,000 --> 00:00:03,000
Man 1: Hey, I just need to know.

2
00:00:04,000 --> 00:00:06,000
Reporter:
Record temperatures in the New York area.
EOF

  cat > "$fake_cli" <<'PY'
import json
print(json.dumps({
    "translations": [
        {"number": "1", "translation": "伙计，我只是想知道"},
        {"number": "2", "translation": "记者：纽约地区创下纪录气温"},
    ]
}, ensure_ascii=False))
PY

  set +e
  output_text=$(python3 "$PROJECT_DIR/scripts/translate-srt-v2.py" \
    --input "$input" \
    --output "$output" \
    --backend cli-command \
    --cli-command "python3 $fake_cli" \
    --max-retries 1 2>&1)
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    fail "expected dropped leading speaker label to fail validation"
  fi

  case "$output_text" in
    *"speaker label"*) ;;
    *) fail "expected speaker label error, got: $output_text" ;;
  esac

  if [ -e "$output" ]; then
    fail "speaker label validation failure should not write final SRT"
  fi

  rm -rf "$work_dir"
}

test_validator_does_not_treat_time_as_speaker_label() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-v2-test.XXXXXX")
  input="$work_dir/movie.en.srt"
  output="$work_dir/movie.zh.srt"
  fake_cli="$work_dir/fake-cli.py"

  cat > "$input" <<'EOF'
1
00:00:01,000 --> 00:00:03,000
You wanna talk about our 10:00 A.M.'s?
EOF

  cat > "$fake_cli" <<'PY'
import json
print(json.dumps({
    "translations": [
        {"number": "1", "translation": "你想聊聊我们上午10点的安排吗？"}
    ]
}, ensure_ascii=False))
PY

  python3 "$PROJECT_DIR/scripts/translate-srt-v2.py" \
    --input "$input" \
    --output "$output" \
    --backend cli-command \
    --cli-command "python3 $fake_cli" >/dev/null

  grep -q '上午10点' "$output" || fail "time-like colon should not require a leading speaker label"

  rm -rf "$work_dir"
}

test_validator_rejects_copied_generic_speaker_label() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-v2-test.XXXXXX")
  input="$work_dir/movie.en.srt"
  output="$work_dir/movie.zh.srt"
  fake_cli="$work_dir/fake-cli.py"

  cat > "$input" <<'EOF'
1
00:00:01,000 --> 00:00:03,000
Reporter:
Record temperatures in the New York area.
EOF

  cat > "$fake_cli" <<'PY'
import json
print(json.dumps({
    "translations": [
        {"number": "1", "translation": "Reporter：纽约地区创下纪录气温"}
    ]
}, ensure_ascii=False))
PY

  set +e
  output_text=$(python3 "$PROJECT_DIR/scripts/translate-srt-v2.py" \
    --input "$input" \
    --output "$output" \
    --backend cli-command \
    --cli-command "python3 $fake_cli" \
    --max-retries 1 2>&1)
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    fail "expected copied generic speaker label to fail validation"
  fi

  case "$output_text" in
    *"generic speaker label"*) ;;
    *) fail "expected generic speaker label error, got: $output_text" ;;
  esac

  if [ -e "$output" ]; then
    fail "generic speaker label validation failure should not write final SRT"
  fi

  rm -rf "$work_dir"
}

test_retry_prompt_includes_previous_validation_error() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-v2-test.XXXXXX")
  input="$work_dir/movie.en.srt"
  output="$work_dir/movie.zh.srt"
  fake_cli="$work_dir/fake-cli.py"

  cat > "$input" <<'EOF'
1
00:00:01,000 --> 00:00:03,000
Reporter:
Record temperatures in the New York area.
EOF

  cat > "$fake_cli" <<'PY'
import json
import sys

prompt = sys.stdin.read()
if "Previous attempt failed validation" in prompt:
    translation = "记者：纽约地区创下纪录气温"
else:
    translation = "Reporter：纽约地区创下纪录气温"
print(json.dumps({
    "translations": [
        {"number": "1", "translation": translation}
    ]
}, ensure_ascii=False))
PY

  python3 "$PROJECT_DIR/scripts/translate-srt-v2.py" \
    --input "$input" \
    --output "$output" \
    --backend cli-command \
    --cli-command "python3 $fake_cli" \
    --max-retries 2 >/dev/null

  grep -q '记者：纽约地区创下纪录气温' "$output" \
    || fail "retry prompt should include previous validation error and allow corrected output"

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

  grep -F -q -- 'Style: Primary,PingFang SC,56,&H00FFFFFF' "$output" \
    || fail "bilingual ASS should define a primary-language style"
  grep -F -q -- 'Style: Secondary,Arial,36,&H00D6F4FF' "$output" \
    || fail "bilingual ASS should define a secondary-language style"
  grep -F -q -- 'Dialogue: 1,0:00:01.00,0:00:03.00,Primary,,0,0,0,,- 小心点，混蛋 - 那么，呃，下次约会什么时候？' "$output" \
    || fail "bilingual ASS should flatten target text into one styled dialogue line"
  grep -F -q -- 'Dialogue: 0,0:00:01.00,0:00:03.00,Secondary,,0,0,0,,- Watch it, asshole - So, uh, when'\''s the next date?' "$output" \
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

test_bilingual_ass_supports_latin_primary_template() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-v2-test.XXXXXX")
  source="$work_dir/movie.en.srt"
  target="$work_dir/movie.fr.srt"
  output="$work_dir/movie.fr.ass"

  cat > "$source" <<'EOF'
1
00:00:01,000 --> 00:00:03,000
You are late.

2
00:00:04,000 --> 00:00:06,000
Wait...
EOF

  cat > "$target" <<'EOF'
1
00:00:01,000 --> 00:00:03,000
Tu es en retard.

2
00:00:04,000 --> 00:00:06,000
Attends...
EOF

  python3 "$PROJECT_DIR/scripts/build-ass-subtitle.py" \
    --source "$source" \
    --target "$target" \
    --output "$output" \
    --mode bilingual \
    --height 1080 \
    --primary-script latin \
    --secondary-script latin >/dev/null

  grep -F -q -- 'Style: Primary,Arial,48,&H00FFFFFF' "$output" \
    || fail "latin-primary bilingual ASS should use the latin primary preset"
  grep -F -q -- 'Style: Secondary,Arial,34,&H00D6F4FF' "$output" \
    || fail "latin-primary bilingual ASS should use the latin secondary preset"
  grep -F -q -- 'Dialogue: 1,0:00:01.00,0:00:03.00,Primary,,0,0,0,,Tu es en retard' "$output" \
    || fail "latin primary text should remove terminal period"
  grep -F -q -- 'Dialogue: 0,0:00:01.00,0:00:03.00,Secondary,,0,0,0,,You are late' "$output" \
    || fail "latin secondary text should remove terminal period"
  grep -F -q -- 'Attends...' "$output" \
    || fail "latin primary text should preserve ellipsis"
  grep -F -q -- 'Wait...' "$output" \
    || fail "latin secondary text should preserve ellipsis"

  rm -rf "$work_dir"
}

test_auto_concurrency_policy_uses_internal_thresholds
test_fake_worker_rebuilds_srt_from_source_structure
test_validator_rejects_extra_worker_cue
test_cli_command_backend_rebuilds_srt
test_openai_compatible_backend_rebuilds_srt
test_openai_compatible_backend_accepts_text_aliases
test_endpoint_backend_uses_endpoint_prompt_only_for_endpoint
test_alignment_check_ignores_non_hard_issues
test_alignment_check_rejects_shifted_cli_output
test_validator_rejects_dropped_leading_speaker_label
test_validator_does_not_treat_time_as_speaker_label
test_validator_rejects_copied_generic_speaker_label
test_retry_prompt_includes_previous_validation_error
test_ass_header_includes_playres
test_bilingual_ass_uses_layered_two_line_layout
test_bilingual_ass_flattens_cjk_without_extra_spaces
test_display_punctuation_cleanup_preserves_non_statement_endings
test_bilingual_ass_supports_latin_primary_template

echo "v2-translator: ok"

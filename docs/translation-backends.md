# Translation Backends

The subtitle workflow separates subtitle structure from translation execution.
Local code owns SRT parsing, chunking, validation, retry, SRT composition, and
optional ASS composition. A translation backend only has one job:

```text
prompt + JSON schema -> {"translations": [...]}
```

Every backend must return exactly one translation object per input cue.
When semantic alignment checking is enabled, the same backend receives a second
prompt and schema for the translated chunk:

```text
alignment prompt + JSON schema -> {"issues": [...]}
```

This second call is a quality gate. It should not rewrite translations; it only
reports clear cue-level meaning shifts.

## Public API Target

```text
openai-compatible  Any OpenAI-compatible chat completions endpoint.
```

The backend is selected with:

```bash
--backend openai-compatible
```

or:

```bash
SUBTRANS_BACKEND=openai-compatible
```

The public integration contract is intentionally narrow. OpenAI-compatible
HTTP endpoints have a stable request/response shape, predictable timeout
handling, and are easy to run in parallel without tool-specific shell wrappers.

For translation requests, the endpoint backend sends two chat messages:

```text
system -> endpoint API-worker contract
user   -> translation instructions, retry note, and input chunk JSON
```

The default system prompt lives at:

```text
prompts/endpoint-format-contract-system.md
```

It is endpoint-only. Developer CLI adapters keep their existing prompt path.

## Current Stable Local Profile

For this version, the most trustworthy practical runner is the lower-level
Codex CLI backend:

```text
codex-cli
```

This is a local execution profile, not a promise that every AI CLI works. It
has higher startup overhead than a direct API call and depends on the user's
local Codex authentication, but it is currently the path with the strongest
instruction-following baseline in this project.

Use it through the workflow CLI:

```bash
python3 scripts/subtitle-workflow.py \
  --input /path/to/movie.en.srt \
  --source-language English \
  --target-language Simplified\ Chinese \
  --target-suffix zh \
  --backend codex-cli \
  --model gpt-5.4-mini
```

## Developer-Only CLI Experiments

Development and compatibility backends such as `cli-command`, `fake`, and
`fake-extra` may exist in the lower-level translation engine for local
experiments and tests. They are not official product support surfaces.

Local validation showed that other AI CLIs have tool-specific wrapper behavior,
startup overhead, hook output, and model-name drift. For that reason, Claude
Code, Gemini CLI, OpenCode, and similar tools are not guaranteed by this
project. Advanced users can still adapt the lower-level engine in their own
fork or local workflow.

## OpenAI-Compatible Endpoint

Use `openai-compatible` to call a chat completions endpoint directly:

```bash
python3 scripts/subtitle-workflow.py \
  --input /path/to/movie.en.srt \
  --source-language English \
  --target-language Spanish \
  --target-suffix es \
  --backend openai-compatible \
  --model gpt-5.4-mini \
  --openai-base-url https://api.example.com/v1 \
  --openai-api-key "$API_KEY"
```

Equivalent environment variables:

```bash
OPENAI_BASE_URL=https://api.example.com/v1
OPENAI_API_KEY=...
SUBTRANS_BACKEND=openai-compatible
SUBTRANS_MODEL=gpt-5.4-mini
SUBTRANS_ENDPOINT_PROMPT_FILE=/path/to/endpoint-format-contract-system.md
```

`--openai-response-format` controls whether the request asks for JSON mode:

```text
none         Do not send response_format.
json_object  Send {"type": "json_object"}.
json_schema  Send a strict JSON schema response_format.
```

Default is `json_schema`, because subtitle translation is sensitive to missing
cue ids and wrong field names. Use `json_object` or `none` for endpoints that
reject strict schema responses.

## Contract

Regardless of backend, the returned JSON must match:

```json
{
  "translations": [
    {
      "number": "1",
      "translation": "Translated subtitle text"
    }
  ]
}
```

The validator rejects:

- missing or extra translations
- changed cue numbers
- empty translations
- timestamps inside returned translation text
- dropped leading speaker-label structure
- copied source generic speaker labels when translating between different
  languages
- malformed JSON

When a chunk fails validation and retries remain, the next prompt includes the
previous validation error. Backends do not need a special retry API; they only
need to follow the prompt they receive for that attempt.

Endpoint testing on 2026-06-09 found that `gpt-5.4-mini` was the best current
endpoint model candidate. `gpt-5.3-codex-spark` followed JSON/count structure
well, but had weaker translation quality on the Daredevil sample and one full
run hit a long endpoint 502 retry. Treat endpoint model choice as deployment
evidence, not a permanent rule. The current stable local runner remains Codex
CLI.

If `--alignment-check model` or `SUBTRANS_ALIGNMENT_CHECK=model` is enabled, the
backend must also support the alignment response:

```json
{
  "issues": [
    {
      "number": "470",
      "severity": "fail",
      "reason": "Candidate translation appears to belong to cue 469."
    }
  ]
}
```

Return an empty array when every translation still matches the source cue with
the same number:

```json
{
  "issues": []
}
```

Any reported issue fails the chunk and triggers retry. This catches the class of
errors where a model returns the right number of translations with the right cue
numbers, but the translated meanings are shifted by one or more cues.

This is the key architectural rule: backends are replaceable, but subtitle
structure remains deterministic and local.

## Style Prompt Boundary

The default style prompt is language-neutral. It preserves specific names and
named entities, but generic role or speaker labels are not names. Labels such
as `Reporter`, `Man 1`, `Woman 2`, and `Officer 3` should be translated into the
configured target language. If a source cue begins with a speaker label, the
target cue should also begin with a translated speaker label. Copying `Reporter`
as `Reporter:` in a Chinese or French target file is rejected; preserving
specific names such as character names is still allowed.

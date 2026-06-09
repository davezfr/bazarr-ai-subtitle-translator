# Project History

## 2026-06-09 - Finalize V2/V3 milestone status before commit

- Reconciled the documented product stance after endpoint and Codex Spark
  testing.
- The current stable local runner is `codex-cli`; OpenAI-compatible endpoints
  remain the long-term public API target.
- Exposed `codex-cli` through the generic workflow CLI while keeping arbitrary
  `cli-command` support out of the public workflow surface.
- Updated README, backend docs, decisions, implementation plan, and handoff so
  the next session starts from the stable-runner boundary instead of the earlier
  endpoint-only assumption.

Verification:

```bash
sh tests/workflow-cli.sh
git diff --check
```

## 2026-06-09 - Add endpoint system prompt and retest Codex Spark

- Moved endpoint-specific response-shape rules into
  `prompts/endpoint-format-contract-system.md` and send that file as the
  OpenAI-compatible `system` message. The chunk translation task remains the
  `user` message.
- Tightened the endpoint contract so `translations` length must match the input
  item count and cue boundaries have higher priority than fluent sentence
  completion.
- Added tests that verify OpenAI-compatible calls send the endpoint contract as
  a system message while `cli-command` keeps the existing non-endpoint prompt.
- Retested the 621-cue Daredevil episode through the Mac mini endpoint:
  - `gpt-5.4-mini`, endpoint system prompt, alignment off: 41.086s total; one
    deterministic retry for a dropped speaker label; known shifted cues
    469/470, 472/473, and 500 were corrected compared with the earlier
    endpoint run.
  - `gpt-5.3-codex-spark`, endpoint system prompt, alignment off: first run
    48.492s with zero retries, but it borrowed neighboring cue context at
    111/112.
  - After strengthening cue-boundary priority, a focused 107-116 Spark sample
    kept 111/112 separated, but the full Spark rerun hit a 208s endpoint 502
    on chunk 3 and finished in 276.103s after retries.
- Translation quality note: Spark followed JSON/count structure well, but the
  tested output had quality regressions such as `100-degree` becoming
  `百度高温`. Do not promote Spark to the default translation model based on
  this run.
- Model alignment remains diagnostic, not default: the endpoint system prompt
  reduced the original hard cue shifts, while model alignment added substantial
  cost and retry noise.
- Product stance after this retest: OpenAI-compatible endpoints remain the
  long-term public API target, but the lower-level Codex CLI backend is the
  only stable local runner for this version. Other AI CLI tools remain
  unsupported.

Verification:

```bash
sh tests/v2-translator.sh
sh tests/workflow-cli.sh
python3 -m py_compile scripts/translate-srt-v2.py scripts/subtitle-workflow.py
```

## 2026-06-09 - Verify Mac mini OpenAI-compatible endpoint

- Tested the Mac mini Sub2API endpoint with `gpt-5.4-mini`.
- Found that `OPENAI_BASE_URL=http://mini:8080` hits the web UI and returns
  HTML. The working API base is `http://mini:8080/v1`.
- Added tolerant JSON extraction for endpoint responses that prepend a short
  explanation before the JSON object.
- Accepted common endpoint/model field aliases (`items[].text` and
  `translations[].text`) while keeping cue count and cue id validation strict.
- Accepted `issue` as an alignment issue reason alias when a gateway/model does
  not follow the exact alignment schema.
- Changed the default OpenAI-compatible response format to `json_schema`.
- Verified the Daredevil 621-cue endpoint run with deterministic validation and
  `--alignment-check off`: total runtime 72.003 seconds, seven chunks, one
  structural retry for a 99/100 count mismatch.
- Confirmed that `--alignment-check model` catches real cue shifts but is too
  noisy as a default gate for this endpoint/model combination.

Verification:

```bash
sh tests/v2-translator.sh
python3 -m py_compile scripts/translate-srt-v2.py
python3 scripts/translate-srt-v2.py ... --backend openai-compatible --openai-base-url http://mini:8080/v1 --model gpt-5.4-mini --alignment-check off
```

## 2026-06-09 - Narrow official backend support to OpenAI-compatible endpoints

- Tested local AI CLI behavior with the Daredevil subtitle workflow.
- Confirmed Codex CLI can be made to run this workflow, but other AI CLIs need
  tool-specific wrappers and are not stable enough to be an official product
  surface.
- Verified Gemini CLI with `gemini-3-flash-preview` can finish the 621-cue
  Daredevil test in 288.378 seconds, but it required wrapper-specific JSON
  extraction and two semantic alignment retries.
- Updated the top-level workflow to expose only `openai-compatible` as the
  official backend interface. Lower-level CLI adapters remain developer/test
  helpers only.
- Updated README, backend docs, decisions, implementation plan, handoff, and
  environment examples to match the new product boundary.

Verification:

```bash
python3 scripts/translate-srt-v2.py ... --backend cli-command --cli-command '... gemini --model gemini-3-flash-preview ...'
```

## 2026-06-09 - Add generic subtitle workflow CLI

- Added `scripts/subtitle-workflow.py` as the first-class CLI for translating
  an existing SRT into a primary-language SRT and optional ASS sidecar.
- Kept Bazarr integration as an adapter path instead of the product boundary.
- Added workflow tests for default primary SRT output, bilingual-SRT rejection,
  bilingual ASS output, and target-only ASS output.
- Updated README and decisions to define the core output matrix:
  primary-only SRT by default, target-only ASS optional, bilingual ASS only.

Verification:

```bash
python3 -m py_compile scripts/subtitle-workflow.py scripts/translate-srt-v2.py scripts/build-ass-subtitle.py scripts/clean-srt-display.py scripts/subtitle_text.py
sh tests/workflow-cli.sh
```

## 2026-06-09 - Add pluggable translation backends

- Extended `scripts/translate-srt-v2.py` with early pluggable backend
  interfaces: `cli-command` and `openai-compatible`.
- Added custom command placeholders for `{prompt_file}`, `{output_file}`,
  `{schema_file}`, `{log_file}`, and `{model}` so users can adapt AI CLIs,
  local agents, or other commands.
- Added direct OpenAI-compatible `/chat/completions` support with configurable
  base URL, API key, timeout, and response format mode.
- Passed backend settings through `scripts/subtitle-workflow.py`.
- Added backend documentation in `docs/translation-backends.md`.
- Added tests for custom CLI command and mocked OpenAI-compatible endpoint
  execution.
- Updated the default backend to `openai-compatible` so the generic open-source
  path is not tied to one specific CLI tool.

Verification:

```bash
sh tests/v2-translator.sh
sh tests/workflow-cli.sh
```

## 2026-06-08 - Bootstrap verification and wrapper guard hardening

- Verified the pinned upstream installer at commit `1c86a8a36a8900e5476b7b035d6e991a6870214c`.
- Confirmed local Ollama responds on `http://127.0.0.1:11434` with `gemma4:latest`.
- Added fast wrapper behavior tests that use a fake upstream translator instead of calling a model.
- Moved the English subtitle filename guard into `scripts/translate-srt-upstream.sh`.
- Aligned Bazarr intake filename matching with the core wrapper.
- Fixed case-insensitive English SRT output naming so `.en.SRT` and similar
  forms write `.zh.srt` instead of `.en.zh.srt`.
- Created local `.env` from `.env.example` for the Ollama bootstrap path. This file is ignored by Git.

Verification:

```bash
sh tests/wrapper-behavior.sh
./scripts/install-upstream.sh
./scripts/smoke-test.sh
```

## 2026-06-08 - Reject empty translated subtitle entries

- Added wrapper validation that rejects translated SRT output when any timestamp
  entry has no non-empty subtitle text.
- Extended `tests/wrapper-behavior.sh` with a fake upstream translator that
  returns a timestamp-only cue.
- Updated README status and roadmap so completed empty-entry validation is no
  longer listed as a broad missing MVP item.

Verification:

```bash
sh tests/wrapper-behavior.sh
```

## 2026-06-09 - Configurable languages and ASS bilingual output

- Added configurable source language, source suffixes, target language, and
  target suffix.
- Added `SUBTRANS_OUTPUT_FORMAT=srt|ass` and `SUBTRANS_OUTPUT_MODE=target|bilingual`.
- Rejected SRT bilingual output because bilingual presentation needs ASS styling.
- Added `scripts/build-ass-subtitle.py` to compose target-only or bilingual ASS
  from the validated target-language SRT and original source SRT.
- Updated Bazarr intake to use `SUBTRANS_SOURCE_SUFFIXES` instead of hard-coded
  English suffixes.
- Added wrapper tests for French source suffixes, SRT bilingual rejection,
  bilingual ASS composition, and font names with spaces.
- Added support for underscore source suffixes such as `2_English.srt`, with
  default output preserving the same separator style.

Verification:

```bash
sh tests/wrapper-behavior.sh
```

## 2026-06-09 - Separate format contract from translation style prompt

- Added `prompts/format-contract-system.md` as the stable subtitle output
  contract.
- Updated `scripts/translate-srt-upstream.sh` to prepend the format contract
  before the style/custom prompt passed to upstream.
- Narrowed `prompts/xiaohu-style-system.md` so it focuses on translation style
  instead of repeating all pipeline format rules.
- Added wrapper behavior coverage to verify both prompt layers reach the
  upstream translator.
- Updated `.env.example`, README, DECISIONS, and HANDOFF with the new prompt
  boundary.

Verification:

```bash
sh tests/wrapper-behavior.sh
```

## 2026-06-09 - Document V2 deterministic chunked translator direction

- Recorded the V2 architecture decision that existing timed SRT files are the
  structure source of truth.
- Added `IMPLEMENTATION_PLAN.md` with the parser, chunk planner, parallel
  translation worker, deterministic validator, retry manager, SRT composer, ASS
  composer, and QA sampler responsibilities.
- Updated README with the V2 boundary: model owns language, program owns
  subtitle structure.
- Updated HANDOFF so the next full-episode test starts from the V2 plan instead
  of the temporary direct-SRT Codex chunk runner.

Verification:

```bash
git diff --check
```

## 2026-06-09 - Implement and benchmark standalone V2 translator

- Added `scripts/translate-srt-v2.py` as an experimental standalone V2 runner.
- Added `tests/v2-translator.sh` with fake-worker coverage for deterministic
  SRT reconstruction and rejection of extra worker-returned cues.
- Ran the Daredevil S02E01 English subtitle through `gpt-5.4-mini` with chunk
  size 100, concurrency 3, and 7 chunks.
- Validated that source and target both contain 621 subtitle cues.
- Measured total runtime at 118.485s, with 118.479s in translation and only
  milliseconds in parse, chunk planning, composition, final validation, and
  writing.

Verification:

```bash
sh tests/v2-translator.sh
python3 -m py_compile scripts/translate-srt-v2.py scripts/build-ass-subtitle.py
git diff --check
```

## 2026-06-09 - Tune speaker labels and personal-name style

- Initially updated the default style prompt so foreign personal names stay in
  original Latin spelling instead of being transliterated. This was later
  generalized into a language-neutral source-name-form rule.
- Allowed generic speaker labels to be translated naturally for target-language
  readability.
- Added `tests/prompt-contract.sh` so this style decision remains visible in
  future prompt edits.

Verification:

```bash
sh tests/prompt-contract.sh
```

## 2026-06-09 - Benchmark V2 concurrency 6

- Re-ran the Daredevil S02E01 English subtitle through `gpt-5.4-mini` after the
  prompt update.
- Increased V2 worker concurrency from 3 to 6 while keeping chunk size 100.
- Validated that source and target both contain 621 subtitle cues.
- Measured total runtime at 84.467s, compared with 118.485s for concurrency 3.
- Confirmed the bottleneck remains translation worker time; parse, composition,
  final validation, and write stayed in the millisecond range.

Verification:

```bash
grep -c -- '-->' <source.srt>
grep -c -- '-->' <target.srt>
git diff --check
```

## 2026-06-09 - Add ASS PlayRes scaling baseline

- Added `PlayResX` and `PlayResY` to generated ASS headers.
- Mapped common video heights to PlayRes baselines, such as 1080 -> 1920x1080.
- Re-generated the Daredevil bilingual ASS test file and verified ffmpeg/libass
  no longer warns that PlayRes is missing.

Verification:

```bash
sh tests/v2-translator.sh
ffmpeg -f lavfi -i color=size=1920x1080:duration=1:rate=1 \
  -vf "ass=<bilingual.ass>" -frames:v 1 -f null -
```

## 2026-06-09 - Fix bilingual ASS inline font inheritance

- Updated bilingual ASS composition to interleave matching target/source lines.
- Explicitly emits target font size before each target line and source font size
  before each source line so later Chinese lines do not inherit the smaller
  English size.
- Increased the 1080p default bilingual ASS sizing to Chinese 48 / source 32
  after Plex visual inspection showed the previous output was too small.
- Re-generated and uploaded the Daredevil S02E01 `.Chinese.ass` sidecar to the
  NAS test path.

Verification:

```bash
sh tests/v2-translator.sh
ffmpeg -f lavfi -i color=size=1920x1080:duration=1:rate=1 \
  -vf "ass=<bilingual.ass>" -frames:v 1 -f null -
```

## 2026-06-09 - Switch bilingual ASS to layered two-line preset

- Replaced the inline mixed-language bilingual ASS dialogue with two same-time
  dialogue events.
- Adopted a 1080p film-default preset: target 56, source 36, white target text,
  near-white pale yellow source text, black outline, light shadow, and separate bottom
  margins.
- Flattened existing SRT line breaks into one line per language in bilingual
  ASS mode so wrapped source cues do not render as four-line bilingual blocks.
- Added `SUBTRANS_ASS_SOURCE_FONT` so target and source fonts can be tuned
  separately.

Verification:

```bash
sh tests/v2-translator.sh
sh tests/wrapper-behavior.sh
python3 -m py_compile scripts/translate-srt-v2.py scripts/build-ass-subtitle.py
git diff --check
```

## 2026-06-09 - Add V3 primary/secondary ASS template

- Added `docs/subtitle-output-template.md` as the standard display-layer
  contract for bilingual ASS output.
- Renamed generated bilingual ASS styles from language-specific `ZH` / `EN` to
  reusable `Primary` / `Secondary` roles.
- Added CJK-primary and Latin-primary size/font presets so Chinese-English and
  French-English bilingual subtitles can share the same output workflow.
- Added `--primary-script`, `--secondary-script`, `--primary-size`,
  `--secondary-size`, `--primary-font`, and `--secondary-font` to the ASS
  builder while keeping legacy target/source options compatible.
- Added wrapper environment support for `SUBTRANS_ASS_PRIMARY_*` and
  `SUBTRANS_ASS_SECONDARY_*` variables while keeping legacy V2 names accepted.

Verification:

```bash
sh tests/v2-translator.sh
sh tests/wrapper-behavior.sh
```

## 2026-06-09 - Document Plex primary-language sidecar naming

- Added Plex-facing sidecar naming rules to `docs/subtitle-output-template.md`.
- Documented that bilingual ASS files use the primary display language as the
  filename language code, such as `.zh.ass` for Chinese-English and `.fr.ass`
  for French-English.
- Added wrapper coverage to ensure default bilingual ASS output uses the target
  / primary language suffix instead of source, pair, or generic bilingual
  suffixes.

Verification:

```bash
sh tests/wrapper-behavior.sh
```

## 2026-06-09 - Generalize translation prompt for V3 language pairs

- Updated `prompts/xiaohu-style-system.md` so personal-name and speaker-label
  guidance is language-neutral instead of Chinese-specific.
- Kept the same product rule: names, organizations, brands, products, acronyms,
  and code identifiers are protected source terms unless an explicit glossary
  or project-specific instruction says otherwise, while generic speaker labels
  translate into the configured target language.

Verification:

```bash
sh tests/prompt-contract.sh
```

## 2026-06-09 - Run High-Rise bilingual movie test

- Translated `High-Rise 2015 1080p BluRay x264 DTS-JYK.EN.srt` from English
  into Simplified Chinese and French with `gpt-5.4-mini`, chunk size 100, and
  concurrency 6.
- Source had 1018 SRT cues, split into 11 chunks. Both language runs completed
  with zero retries and validated one translation per cue.
- Chinese run completed in 129.739s total; translation took 129.728s.
- French run completed in 142.763s total; translation took 142.757s.
- Generated and uploaded Plex-facing bilingual ASS sidecars:
  - `High-Rise 2015 1080p BluRay x264 DTS-JYK.zh.ass`
  - `High-Rise 2015 1080p BluRay x264 DTS-JYK.fr.ass`
- Both ASS outputs have 2036 dialogue lines and passed ffmpeg/libass parsing.

Verification:

```bash
sh tests/prompt-contract.sh
ffmpeg -hide_banner -loglevel error -f lavfi -i color=s=1920x1080:d=1 -vf "ass=<output.ass>" -frames:v 1 -f null -
```

## 2026-06-09 - Add display punctuation cleanup

- Added `scripts/subtitle_text.py` as a shared display-layer cleanup helper.
- Added `scripts/clean-srt-display.py` so the upstream wrapper can clean target
  SRT output before writing final SRT or composing ASS.
- Applied the same cleanup in V2 SRT composition and ASS composition.
- Removed ordinary terminal statement punctuation (`。`, `，`, `.`, `,`) while
  preserving questions, exclamations, ellipses, and protected English
  abbreviations such as `Mr.` and `U.S.`.

Verification:

```bash
sh tests/prompt-contract.sh
sh tests/v2-translator.sh
sh tests/wrapper-behavior.sh
python3 -m py_compile scripts/translate-srt-v2.py scripts/build-ass-subtitle.py scripts/clean-srt-display.py scripts/subtitle_text.py
git diff --check
```

## 2026-06-09 - Add semantic alignment gate

- Added optional `--alignment-check off|model` /
  `SUBTRANS_ALIGNMENT_CHECK=off|model` support to the V2 translator and generic
  workflow CLI.
- Added an alignment prompt and schema that ask the backend to report clear
  cue-level meaning shifts after deterministic structure validation.
- Failed chunks retry when the alignment checker returns any issue.
- Added regression coverage for the real failure mode where a backend returns
  the right cue count and cue numbers, but shifts translated meanings to
  neighboring cues.
- Added deterministic validation that rejects translations which drop a leading
  speaker-label structure from cues such as `Reporter:` or `Man 1:`.
- Added deterministic validation for copied source generic speaker labels and
  retry prompts that include the previous validation error.
- Tightened the default language-neutral style prompt: specific names are
  protected, while generic role/speaker labels such as Reporter and Man 1 are
  not names and should be translated.

Verification:

```bash
sh tests/prompt-contract.sh
sh tests/v2-translator.sh
sh tests/workflow-cli.sh
```

## 2026-06-09 - Make worker scheduling internal

- Removed normal user-facing concurrency and chunk-size settings from the
  generic workflow path.
- Fixed the internal chunk size at 100 cues.
- Added automatic concurrency selection by source cue count:
  `<=250 -> 2`, `251-500 -> 3`, `501-800 -> 4`, `>800 -> 6`.
- Kept the selected concurrency and policy name in summary JSON for
  observability without turning it into a product knob.
- Added tests for the auto policy and for rejecting the public
  `--concurrency` flag on the workflow CLI.

Verification:

```bash
sh tests/v2-translator.sh
sh tests/workflow-cli.sh
```

# Project History

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

- Updated the default style prompt so foreign personal names stay in original
  Latin spelling instead of being transliterated.
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

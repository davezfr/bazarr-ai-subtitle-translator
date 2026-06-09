# Implementation Plan

## V2 Deterministic Chunked Translator

Date: 2026-06-09

Status: V2 deterministic translation engine and V3 ASS display template are
implemented and tested. The current stable local runner is `codex-cli` through
`scripts/translate-srt-v2.py` / `scripts/subtitle-workflow.py`. The
OpenAI-compatible endpoint remains the long-term public API target, but
endpoint model quality is still under validation. Bazarr wrapper integration is
an adapter task.

### Goal

Build a translation workflow for existing timed subtitle files. It should
translate a complete subtitle file into target-language SRT while preserving the
source subtitle structure exactly, then optionally compose target-only or
bilingual ASS.

### Product Boundary

This project translates existing sidecar subtitles. It does not download video,
extract audio, run Whisper, repair ASR timing, or burn subtitles into video.
It is not coupled to Bazarr; Bazarr is one possible caller.

The source SRT is treated as the timing and segmentation source of truth.

### Architecture

```text
source SRT
  -> parser
  -> chunk planner
  -> parallel translation workers
  -> deterministic chunk validator
  -> optional semantic alignment gate
  -> retry manager
  -> SRT composer
  -> final file validator
  -> optional ASS composer
  -> optional semantic QA sampler
```

### Module Responsibilities

Parser:

- Read SRT blocks.
- Preserve cue number, start timestamp, end timestamp, and original text.
- Normalize timestamp separators for validation only.

Chunk planner:

- Split parsed cues into bounded chunks.
- Keep original cue ids with every chunk item.
- Use the internal 100-cue chunk size.
- Select worker concurrency automatically from total source cue count.

Translation workers:

- Translate source text into target-language text.
- Return structured data only, such as cue id plus translated text.
- Never return full SRT, timestamps, commentary, markdown, or extra cues.
- May run in parallel through an OpenAI-compatible endpoint or a future worker
  pool.

Validator:

- Check every source cue has exactly one returned translation.
- Check cue ids match exactly and order is preserved.
- Reject empty translations.
- Reject returned timestamps or accidental SRT blocks inside translation text.
- Reject extra explanations, markdown fences, and metadata.
- Reject dropped leading speaker-label structure when the source cue begins
  with a speaker label.
- Reject copied source generic speaker labels when translating between different
  languages.

Semantic alignment gate:

- Optional model-based check after deterministic chunk validation.
- Compare each source cue with the candidate translation carrying the same cue
  number.
- Reject clear cases where meanings are shifted from neighboring cues, merged
  across cue boundaries, or no longer match the source cue.
- Do not rewrite or polish translations; it is a quality gate, not a second
  translation pass.

Retry manager:

- Retry only failed chunks, not the whole episode.
- Include the previous validation error in the next attempt prompt.
- Keep attempt logs per chunk.
- Stop after a configured retry limit and report the failed chunk range.

SRT composer:

- Rebuild the final target-language SRT from source cue numbers and timestamps.
- Insert only validated target-language text from workers.
- Do not allow the model to change numbering or timing.

ASS composer:

- For target-only ASS, use target-language text.
- For bilingual ASS, combine target-language text on top with original source
  text below.
- Keep bilingual output ASS-only; do not generate bilingual SRT.

QA sampler:

- Optional semantic review layer.
- Sample translated cues or whole chunks for naturalness, terminology
  consistency, tone, and obvious mistranslation.
- Never replace deterministic structure validation.

### Current Configuration Targets

```text
SUBTRANS_BACKEND=codex-cli
SUBTRANS_MODEL=gpt-5.4-mini
SUBTRANS_MAX_RETRIES=3
SUBTRANS_ALIGNMENT_CHECK=off
SUBTRANS_OUTPUT_FORMAT=srt
SUBTRANS_OUTPUT_MODE=target
```

For endpoint experiments, use:

```text
SUBTRANS_BACKEND=openai-compatible
SUBTRANS_OPENAI_RESPONSE_FORMAT=json_schema
SUBTRANS_ENDPOINT_PROMPT_FILE=prompts/endpoint-format-contract-system.md
```

Chunk size and worker concurrency are internal policy:

```text
chunk size:    100 cues
<= 250 cues    -> 2 workers
251-500 cues   -> 3 workers
501-800 cues   -> 4 workers
> 800 cues     -> 6 workers
```

### First Real-Episode Test

Input:

```text
/volume1/Media Library/TV - EN/Marvel Daredevil/Marvels.Daredevil.S02.1080p.BluRay.x265-RARBG/Subs/Marvels.Daredevil.S02E01.1080p.BluRay.x265-RARBG/2_English.srt
```

Expected target output:

```text
2_Chinese.srt
```

Test procedure:

1. Copy or stream the source SRT from `ssh dcloud` to a local temp workdir.
2. Count source cues before translation.
3. Run V2 with `gpt-5.4-mini`, target-language SRT, and internal auto
   scheduling.
4. Validate final cue count, cue numbers, timestamps, and non-empty text.
5. Inspect representative early, middle, and late subtitle ranges.
6. Measure elapsed time, chunk retries, and token usage if available.
7. Upload to the NAS path only after validation passes.

Result from the first local full-episode run:

```text
model: gpt-5.4-mini
backend: codex-cli
cue count: 621
chunk size: 100
chunks: 7
concurrency: 3
retries: 0
total: 118.485s
parse: 0.002s
chunk plan: 0.000s
translation: 118.479s
compose: 0.001s
final validation: 0.002s
write: 0.001s
```

Conclusion: the bottleneck is translation worker time. Parsing, chunking,
composition, final validation, and writing are effectively negligible.

Result from the second local full-episode run after prompt tuning and higher
concurrency:

```text
model: gpt-5.4-mini
backend: codex-cli
cue count: 621
chunk size: 100
chunks: 7
concurrency: 6
retries: 0
total: 84.467s
parse: 0.002s
chunk plan: 0.000s
translation: 84.461s
compose: 0.000s
final validation: 0.002s
write: 0.001s
```

Compared with concurrency 3, concurrency 6 reduced total runtime from 118.485s
to 84.467s. The speedup was meaningful but not 2x because the run was gated by
the slowest chunk, which took 84.455s.

### Rollback

V2 writes a new sidecar file such as `2_Chinese.srt`. Rollback is deleting that
generated file. Source subtitles are not modified.

### Next Implementation Steps

1. Decide whether to package the generic workflow as a cross-agent Skill, a
   small installable CLI, or both.
2. Integrate `scripts/subtitle-workflow.py` into the Bazarr wrapper adapter.
3. Add a small real-model test mode against a tiny fixture.
4. Add backend usage/cost extraction when a backend exposes stable usage fields.

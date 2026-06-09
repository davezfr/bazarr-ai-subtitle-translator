# Decisions

## Core wrapper owns source suffix safety checks

Date: 2026-06-08, updated 2026-06-09

`scripts/translate-srt-upstream.sh` rejects subtitle inputs that do not match
the configured source suffixes before the `.srt` extension. Defaults are
`en,eng,english`, but deployments can set `SUBTRANS_SOURCE_SUFFIXES`, such as
`fr,fra,french`.

Reasoning:

- Bazarr custom post-processing is an intake layer, so it should skip unrelated
  files without failing Bazarr.
- The core translation wrapper is the execution layer, so it should reject
  direct misuse before calling the upstream translator.
- Keeping the guard in the core wrapper prevents manual commands from
  accidentally translating target-language sidecars or generic `.srt` files into
  misleading output sidecars.

## Format contract is separate from style prompt

Date: 2026-06-09

The wrapper composes the upstream system instruction from two files:

```text
prompts/format-contract-system.md
prompts/xiaohu-style-system.md
```

Reasoning:

- The format contract is a pipeline safety layer. It should remain stable even
  when the translation style changes.
- The style prompt is a product-quality layer. It can evolve as we tune tone,
  vocabulary, and subtitle readability.
- Keeping these separate lets the user provide a richer translation skill
  without accidentally removing output-format constraints.

## Bilingual output requires ASS

Date: 2026-06-09

SRT output is target-language only. Bilingual output is only allowed when
`SUBTRANS_OUTPUT_FORMAT=ass` and `SUBTRANS_OUTPUT_MODE=bilingual`.

Reasoning:

- SRT can technically contain two text lines, but it cannot express visual
  hierarchy such as target-language text larger than source-language text.
- Xiaohu's workflow uses ASS for bilingual presentation for this same reason.
- The model still produces only target-language SRT. The wrapper composes ASS
  from the translated target SRT and the original source SRT so source text is
  preserved exactly.

## V2 translator separates language work from subtitle structure

Date: 2026-06-09

The next translator implementation should treat the existing timed SRT as an
already-structured source of truth. The model should translate text only; local
code should own cue parsing, chunking, validation, retry, numbering, timestamps,
SRT reconstruction, and optional ASS composition.

Reasoning:

- This project starts from existing sidecar subtitles, not Whisper/ASR output.
  It does not need Xiaohu's ASR repair rules such as aggressive de-redundancy,
  punctuation removal, retiming, or re-segmentation.
- Direct model-generated SRT is fragile. A full-episode test chunk produced 82
  cues from an 80-cue source chunk because the model split one subtitle and
  invented duplicate timestamps.
- Translation is a language task, so it can be delegated to parallel workers or
  sub-agents. Cue counts, cue ids, timestamps, and final file structure are
  deterministic checks and should be validated by code.
- Bilingual output still follows the Xiaohu lesson: compose ASS from the
  target-language translation and original source text instead of asking the
  model to generate bilingual SRT.

V2 execution shape:

```text
source SRT
  -> parse cue list
  -> split into bounded chunks
  -> translate chunks in parallel workers
  -> each worker returns structured target text only
  -> deterministic validator checks every chunk
  -> failed chunks are retried
  -> local code rebuilds target-language SRT from original ids/timestamps
  -> optional ASS builder combines target text with source text
  -> optional QA agent performs semantic sampling, not structural validation
```

Initial tuning target:

- Start with `SUBTRANS_CHUNK_SIZE` around 80-120 cues.
- Start with `SUBTRANS_CONCURRENCY` around 3-5 workers.
- Increase concurrency only after measuring model rate limits, elapsed time,
  failure rate, and cost on a real episode.

## Personal names stay in Latin spelling

Date: 2026-06-09

Subtitle translations should keep foreign personal names in their original
Latin spelling. Generic speaker labels may be translated into the target
language.

Examples:

```text
Foggy: Good thinking.  -> Foggy: 想得好。
Karen asked questions. -> Karen 一直在问。
Reporter: ...         -> 记者：...
Officer: ...          -> 警官：...
Man 1: ...            -> 男1：...
Woman 2: ...          -> 女2：...
```

Reasoning:

- Sidecar subtitles often already contain canonical character names.
- Transliteration can create inconsistency, especially across episodes and
  media libraries.
- Generic labels are not names; translating them improves readability for the
  target-language viewer without changing character identity.

## Bilingual ASS uses two layered dialogue styles

Date: 2026-06-09

For bilingual ASS, each cue is rendered as two same-time ASS dialogue events:

```text
Dialogue: ...,ZH,...,<target-language text>
Dialogue: ...,EN,...,<source-language text>
```

The target-language style is larger, white, and positioned above the
source-language style. The source-language style is smaller, near-white pale
yellow, and positioned closer to the bottom edge.

Reasoning:

- A bilingual cue should visually read as two lines: target language above,
  source language below.
- Keeping both languages inside one ASS dialogue requires fragile inline
  overrides such as `{\fs...}` and can accidentally inherit the wrong font size.
- Separate styles make typography, color, border, shadow, and bottom margins
  easy to tune without involving the translation model.
- Existing SRT line breaks are presentation hints for single-language subtitles.
  The bilingual builder flattens them into one line per language so a wrapped
  source cue does not become a four-line bilingual block.

## Display punctuation cleanup stays outside the prompt

Date: 2026-06-09

Subtitle display output removes ordinary statement punctuation at line endings:
Chinese `。` / `，` and English `.` / `,`. It preserves `？`, `?`, `！`, `!`,
ellipses, and protected English abbreviations such as `Mr.` and `U.S.`.

Reasoning:

- Subtitle punctuation is a presentation rule, not a translation-quality rule.
- Keeping this out of the prompt avoids making the model over-optimize for
  formatting instead of translation.
- Deterministic cleanup is easier to test and keeps the behavior consistent
  across V2, the upstream wrapper, target SRT output, and ASS composition.
- The cleanup is intentionally narrow: it removes only ordinary line-ending
  statement punctuation and does not rewrite internal punctuation.

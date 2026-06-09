# Decisions

## Core product is a generic SRT translation workflow

Date: 2026-06-09

The primary product boundary is:

```text
existing SRT
  -> target-language SRT
  -> optional target-only or bilingual ASS
```

Bazarr is an optional adapter that can call the workflow later. It is not the
core workflow identity.

Reasoning:

- The core capability is translating an existing timed subtitle file while
  preserving cue structure.
- Users should be able to run the workflow manually, through a CLI, through a
  Skill, or through future automation without installing Bazarr.
- Keeping Bazarr at the intake/adapter layer avoids coupling the translator to
  a specific media-library manager.
- The canonical output of the translation layer is primary-language SRT; ASS is
  a display-layer artifact for styled or bilingual presentation.

## Public API target and current stable local runner

Date: 2026-06-09

The long-term public API target is an OpenAI-compatible endpoint. The current
stable local runner for this version is Codex CLI through the lower-level V2
backend.

Both paths use the same chunk contract:

```text
prompt + schema -> {"translations": [...]}
```

Public API target:

```text
openai-compatible
```

Current stable local profile:

```text
codex-cli
```

Reasoning:

- An OpenAI-compatible endpoint path lets users connect local model servers,
  hosted proxies, or their own API gateways.
- OpenAI-compatible HTTP calls have a stable enough request/response shape for
  batching, retries, timeouts, and parallel chunk execution, so it remains the
  right open-source integration shape.
- Actual endpoint/model quality is still being validated. On 2026-06-09,
  `gpt-5.4-mini` through the endpoint became much better after adding an
  endpoint system prompt, but model alignment stayed noisy. `gpt-5.3-codex-spark`
  followed JSON structure well but had translation-quality regressions and one
  long endpoint 502 retry.
- The local Codex CLI path remains the only runner we have treated as stable
  enough for this version's practical use. It is not as clean as an API
  contract, and it has higher startup/cost overhead, but its instruction
  following produced the most trustworthy baseline so far.
- Other AI CLI tools are too wrapper-specific to support as a product surface.
  Local testing on 2026-06-09 found that Claude Code required wrapper-specific
  extraction and was slow, Gemini CLI required a model-specific wrapper plus
  alignment retries, and OpenCode was only smoke-tested on a tiny sample.
- Development and compatibility adapters such as `cli-command`, `fake`, and
  `fake-extra` can still exist in the lower-level engine for local experiments
  and tests, but README and the top-level workflow should not promise support
  for Claude Code, Gemini CLI, OpenCode, or arbitrary AI CLIs.
- All model-backed calls still pass through deterministic local validation.
  Backend flexibility does not relax cue count, cue id, timestamp, empty-text,
  semantic alignment, or JSON checks.

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

## Endpoint calls use a dedicated system prompt

Date: 2026-06-09

OpenAI-compatible endpoint calls send `prompts/endpoint-format-contract-system.md`
as the first chat message:

```json
{"role": "system", "content": "...endpoint contract..."}
```

The normal translation task, format contract, style prompt, retry note, and
input chunk JSON stay in the user message.

Reasoning:

- Endpoint models can behave differently from AI CLI wrappers even when the
  model name is similar. The API path needs a stricter API-worker contract.
- The endpoint system prompt owns response shape, JSON-only behavior, exact
  translation count, and cue-boundary priority.
- The user prompt owns the actual translation request and chunk payload.
- Keeping endpoint rules in a system message avoids polluting the CLI prompt
  path that was tested separately, while making the API request hierarchy more
  explicit.
- Cue-boundary instructions must override fluent sentence completion. A
  translated cue may be a fragment if the source cue is a fragment.

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

Internal scheduling target:

- Use 100 cues per translation chunk.
- Select worker concurrency automatically from source subtitle length.
- Keep endpoint/sub-agent concurrency conservative, with a hard default cap of
  6 workers.

```text
<= 250 cues   -> 2 workers
251-500 cues  -> 3 workers
501-800 cues  -> 4 workers
> 800 cues    -> 6 workers
```

This is workflow policy, not a normal user setting.

## Chunk and concurrency scheduling is internal policy

Date: 2026-06-09

The generic workflow does not expose `--concurrency`, `SUBTRANS_CONCURRENCY`,
`--chunk-size`, or `SUBTRANS_CHUNK_SIZE` as normal user configuration. The
translator uses 100 cues per chunk and chooses concurrency from source cue
count:

```text
<= 250 cues   -> 2 workers
251-500 cues  -> 3 workers
501-800 cues  -> 4 workers
> 800 cues    -> 6 workers
```

Reasoning:

- Subtitle translation users should choose language direction and output shape,
  not tune worker scheduling.
- Too much endpoint/sub-agent concurrency can cause queueing, rate limits,
  retry storms, and less predictable elapsed time.
- A fixed internal policy keeps behavior understandable while still scaling
  from short episodes to films.
- Advanced users can change the code if they need a different deployment
  policy; it should not be a prominent product knob.

## Default style prompt is language-neutral

Date: 2026-06-09

The default style prompt is written in English, but it must not assume a
specific source or target language. The workflow supplies source and target
language labels for each run.

Subtitle translations should treat specific names as protected source terms:
personal names, character nicknames, family names, named organizations, brands,
products, acronyms, and code identifiers. They should be copied from the source
subtitles instead of being translated, transliterated, localized, or renamed
unless the user provides an explicit glossary or project-specific instruction.
Generic speaker or role labels are not names and should be translated naturally
into the configured target language.

Reasoning:

- Sidecar subtitles often already contain canonical character names.
- Automatic transliteration or localization can create inconsistency, especially
  across episodes and media libraries.
- Generic labels are not names; translating them improves readability for the
  target-language viewer without changing character identity.
- Leading speaker labels are subtitle structure, not just wording. If the
  source cue begins with a label, the target cue should keep a translated label
  at the beginning.
- Generic speaker labels should not be copied from the source language when
  translating between different languages. If a retry is needed, the previous
  validation error is fed back into the next attempt prompt.
- Prompt precedence matters: role labels such as Reporter, Man 1, Woman 2,
  Officer 3, Guard, Nurse, and similar labels should be translated, while
  character names and other protected source terms should be copied.
- The style prompt must stay target-language neutral so the same translation
  layer can support arbitrary language pairs such as English to Chinese,
  English to French, Chinese to Spanish, and future combinations.
- Glossary-based overrides are the right place for project-specific official
  names; the default prompt should not guess them.
- This rule is intentionally language-neutral: it protects source terms without
  assuming that the target language is Chinese, French, Spanish, or any other
  specific language.

## Semantic alignment gate is optional and diagnostic

Date: 2026-06-09

The deterministic V2 validator still owns structure: cue count, cue ids,
timestamps, empty text, and SRT reconstruction. A separate optional semantic
alignment gate can be enabled with:

```bash
--alignment-check model
```

or:

```bash
SUBTRANS_ALIGNMENT_CHECK=model
```

When enabled, each translated chunk receives a second backend call after
structure validation. The checker compares each source cue with the candidate
translation carrying the same cue number and returns:

```json
{"issues": []}
```

or issue objects for clear cue-level meaning shifts.

Reasoning:

- Structure validation can catch extra, missing, reordered, or malformed cues,
  but it cannot prove the translation for cue 470 still means cue 470.
- A real Daredevil retest produced correct cue numbers and counts while a
  sequence of translations was semantically shifted to neighboring cues.
- Keeping this gate optional avoids doubling backend calls for fast local tests
  or low-cost drafts.
- The checker is not a second translator. It should not polish text; it only
  reports clear alignment failures so the chunk can retry.
- Endpoint testing with `gpt-5.4-mini` on 2026-06-09 showed that the checker can
  also be too noisy: it caught real shifted cue ranges such as 469/470 and
  472/473, but also flagged acceptable phrasing and sometimes returned
  non-issues inside the `issues` array.
- The production default should remain deterministic structure validation with
  `alignment-check=off`. Enable model alignment for high-quality diagnostics,
  suspected problem ranges, or future specialized checker models.

## Bilingual ASS uses primary/secondary dialogue styles

Date: 2026-06-09

For bilingual ASS, each cue is rendered as two same-time ASS dialogue events:

```text
Dialogue: ...,Primary,...,<primary-language text>
Dialogue: ...,Secondary,...,<secondary-language text>
```

The primary-language style is larger, white, and positioned above the
secondary-language style. The secondary-language style is smaller, near-white
pale yellow, and positioned closer to the bottom edge.

Reasoning:

- A bilingual cue should visually read as two lines: primary language above,
  secondary language below.
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

## V3 ASS template abstracts language pairs into roles

Date: 2026-06-09

V3 treats bilingual output as a reusable display template with two roles:

```text
Primary language   main comprehension language
Secondary language reference or learning language
```

Examples:

```text
Chinese-English: Primary = Simplified Chinese, Secondary = English
French-English:  Primary = French, Secondary = English
```

Reasoning:

- The translation layer is still source language -> target language; it does
  not need a separate Chinese-only or French-only pipeline.
- The ASS output layer owns typography and display behavior, so it should be
  configurable by script profile rather than hard-coded language names.
- Latin primary subtitles need smaller default sizes than CJK primary subtitles
  because French and other Latin-script text is wider on screen.
- Keeping legacy target/source config names compatible lets V2 deployments
  upgrade without breaking existing wrappers.

## Plex-facing sidecar filenames use the primary language

Date: 2026-06-09

Generated external subtitle filenames use the primary display language as the
Plex language code. The project standard is lowercase ISO 639-1 two-letter
codes.

Examples:

```text
Chinese-English, Chinese primary -> .zh.ass
French-English, French primary   -> .fr.ass
English-French, English primary  -> .en.ass
```

Reasoning:

- Plex identifies external subtitle language from the sidecar filename language
  code.
- A bilingual ASS file can still expose only one language label to Plex.
- The primary language is the language the viewer uses for comprehension, so it
  is the least surprising label in Plex.
- Pair suffixes such as `.zh-en.ass` or generic suffixes such as
  `.bilingual.ass` are not Plex language identifiers and can lead to unknown or
  poorly selectable subtitle tracks.

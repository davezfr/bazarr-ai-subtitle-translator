# Handoff

## Current State

Date: 2026-06-09

The project is now positioned as a generic SRT subtitle translation workflow.
Bazarr is an optional adapter path, not the core product identity. `.env`
exists locally with the same non-secret defaults as `.env.example` and is
ignored by Git.

Pinned upstream is installed under `.runtime/chatgpt-subtitle-translator` at:

```text
1c86a8a36a8900e5476b7b035d6e991a6870214c
```

Verified commands:

```bash
sh tests/wrapper-behavior.sh
./scripts/install-upstream.sh
./scripts/smoke-test.sh
```

## Notes For Next Session

- `scripts/bazarr-postprocess.sh` is the tolerant Bazarr intake layer. It skips
  unrelated subtitles with exit code 0.
- `scripts/subtitle-workflow.py` is the first-class generic CLI. It accepts an
  existing SRT, source/target language labels, target suffix, output mode, and
  output format. It always writes a primary-language SRT, then optionally
  composes target-only or bilingual ASS.
- Translation execution officially uses the `openai-compatible` backend.
  Compatibility/test adapters may still exist internally, but AI CLI wrappers
  are not guaranteed product support targets. The backend documentation lives
  in `docs/translation-backends.md`.
- `scripts/translate-srt-upstream.sh` is the core execution layer. It rejects
  SRT sidecars that do not match `SUBTRANS_SOURCE_SUFFIXES` before calling
  upstream.
- The core wrapper also rejects translated output where any timestamp entry has
  no non-empty subtitle text.
- The upstream system instruction is composed from a stable format contract
  prompt plus a replaceable translation style prompt.
- SRT output is target-language only. Bilingual output requires ASS and is
  composed by `scripts/build-ass-subtitle.py` after translation validation.
- `tests/wrapper-behavior.sh` is a fast local test that does not call a model.
- `scripts/smoke-test.sh` calls the real upstream translator and local Ollama,
  so it depends on `OPENAI_BASE_URL`, `OPENAI_API_KEY`, and `SUBTRANS_MODEL`.
- The approved V2 direction is documented in `IMPLEMENTATION_PLAN.md` and
  `DECISIONS.md`: model workers translate text only, while local code owns SRT
  parsing, chunking, validation, retry, numbering, timestamps, and output
  composition.
- Do not use the temporary direct-SRT Codex chunk runner for the next full
  episode test. It failed the first 80-cue chunk by returning 82 cues after
  splitting one subtitle and inventing duplicate timestamps.
- User selected `gpt-5.4-mini` as the first model for the V2 full-episode
  Chinese single-language SRT test.
- `scripts/subtitle-workflow.py` is still shaped around the OpenAI-compatible
  endpoint as the long-term public API target. For this version, the stable
  local runner is the lower-level `codex-cli` backend in
  `scripts/translate-srt-v2.py`. Other development/test adapters such as
  `cli-command`, `fake`, and `fake-extra` may exist, but Claude Code, Gemini
  CLI, OpenCode, and other AI CLIs are not guaranteed product support targets.
  Summary JSON records stage timings and per-chunk worker timings.
- `scripts/translate-srt-v2.py` and `scripts/subtitle-workflow.py` now support
  `--alignment-check off|model` / `SUBTRANS_ALIGNMENT_CHECK`. `model` adds a
  second per-chunk backend call after deterministic structure validation to
  reject clear semantic cue shifts.
- V2 deterministic validation now also rejects translations that drop a leading
  speaker-label structure when the source cue begins with a label such as
  `Reporter:` or `Man 1:`.
- V2 also rejects copied source generic speaker labels when translating between
  different languages, and includes the previous validation error in the next
  retry prompt.
- V2 scheduling is internal policy. The workflow uses 100 cues per chunk and
  auto-selects concurrency from cue count: `<=250 -> 2`, `251-500 -> 3`,
  `501-800 -> 4`, `>800 -> 6`. Do not expose or recommend user-level
  concurrency/chunk-size tuning.
- Mac mini Sub2API endpoint testing found that the working OpenAI-compatible
  base URL is `http://mini:8080/v1`; `http://mini:8080` returns web UI HTML.
- OpenAI-compatible translation calls now send
  `prompts/endpoint-format-contract-system.md` as the chat `system` message.
  The normal translation task and input chunk JSON remain in the `user`
  message. The endpoint system prompt is not included in the CLI prompt path.
- `gpt-5.4-mini` through that endpoint completed the 621-cue Daredevil run in
  72.003 seconds with `--alignment-check off`. The same endpoint/model with
  `--alignment-check model` caught real shifted ranges but was too noisy to use
  as the default production gate.
- After adding the endpoint system prompt, `gpt-5.4-mini` completed the same
  621-cue Daredevil run in 41.086s with `--alignment-check off`; known shifted
  cues 469/470, 472/473, and 500 were corrected.
- `gpt-5.3-codex-spark` was tested through the same endpoint. It followed JSON
  and cue-count structure strongly, but translation quality was weaker in the
  sample/full run and one full rerun hit a 208s endpoint 502. Do not switch the
  default model to Spark unless a later retest shows better quality and
  endpoint stability.
- Current product stance after the endpoint/Spark retests: keep
  OpenAI-compatible endpoints as the long-term public API target, but treat the
  lower-level Codex CLI backend as the only stable local runner for this
  version. Do not generalize that to Claude Code, Gemini CLI, OpenCode, or
  arbitrary AI CLI support.
- First full-episode local V2 run used `gpt-5.4-mini`, chunk size 100,
  concurrency 3, and 7 chunks for 621 cues. It completed in 118.485s with zero
  retries. Translation took 118.479s; parse, chunk plan, compose, final
  validation, and write together took only milliseconds.
- First full-episode local output lives under the temp workdir recorded in
  `/tmp/daredevil-subtitle-workdir.txt`, with latest run dir recorded at
  `latest-v2-run-dir.txt` inside that workdir. It has not been uploaded to the
  NAS yet.
- Style prompt decision: keep the default prompt language-neutral. Specific
  names and named entities are protected unless an explicit glossary or
  project-specific instruction says otherwise. Generic role/speaker labels such
  as Reporter, Man 1, and Officer 3 are not names and should be translated
  naturally into the configured target language.
- Second full-episode local V2 run used the updated prompt, `gpt-5.4-mini`,
  chunk size 100, concurrency 6, and 7 chunks for 621 cues. It completed in
  84.467s with zero retries. Translation took 84.461s; the slowest chunk was
  chunk 2 at 84.455s. Source and target both validated at 621 cues.
- Bilingual ASS layout after Plex inspection: 1080p CJK-primary defaults are
  primary size 56 and secondary size 36. The builder now emits two same-time
  dialogue events with `Primary` and `Secondary` styles instead of mixing both
  languages in one dialogue with inline font-size overrides. The secondary line
  is near-white pale yellow and the bilingual line gap is intentionally tight.
  Existing SRT line breaks are flattened to one line per language to avoid
  four-line bilingual blocks.
- V3 output template docs live in `docs/subtitle-output-template.md`. V3 adds
  `SUBTRANS_ASS_PRIMARY_SCRIPT` / `SUBTRANS_ASS_SECONDARY_SCRIPT`, primary and
  secondary size/font overrides, and a Latin-primary preset for French-English
  bilingual subtitles.
- The style prompt is now language-neutral for arbitrary language pairs rather
  than assuming Chinese output.
- High-Rise movie test baseline: English source with 1018 cues, chunk size 100,
  concurrency 6, `gpt-5.4-mini`. Chinese-English ASS took 129.739s total;
  French-English ASS took 142.763s total. Outputs were uploaded to the NAS as
  `High-Rise 2015 1080p BluRay x264 DTS-JYK.zh.ass` and
  `High-Rise 2015 1080p BluRay x264 DTS-JYK.fr.ass`.
- Display punctuation cleanup now lives in `scripts/subtitle_text.py` and is
  applied by V2 SRT composition, the upstream wrapper via
  `scripts/clean-srt-display.py`, and ASS composition. It removes ordinary
  terminal `。` / `，` / `.` / `,` while preserving questions, exclamations,
  ellipses, and protected abbreviations.

## Sensible Next Steps

- Commit and push the current V2/V3 milestone once the user approves the
  staged diff.
- Use the Codex CLI backend as the stable local runner for the next real
  subtitle output test.
- Integrate the V2 runner into `scripts/translate-srt-upstream.sh` or add a
  Bazarr-facing switch so V2 can replace the upstream wrapper path.
- Add a small README section for Docker/Bazarr volume mount examples.
- Continue endpoint model evaluation separately from the stable Codex CLI path.
- Add validation for malformed SRT blocks and suspicious untranslated output.
- Add optional ASS sidecar smoke tests with a real model once a sample target
  library path is available.

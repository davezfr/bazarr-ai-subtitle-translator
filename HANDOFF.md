# Handoff

## Current State

Date: 2026-06-09

The project is bootstrapped locally for the Ollama path. `.env` exists locally
with the same non-secret defaults as `.env.example` and is ignored by Git.

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
- `scripts/translate-srt-v2.py` is now the experimental standalone V2 runner.
  It supports `fake`, `fake-extra`, and `codex-cli` backends. It writes a
  summary JSON with stage timings and per-chunk worker timings.
- First full-episode local V2 run used `gpt-5.4-mini`, chunk size 100,
  concurrency 3, and 7 chunks for 621 cues. It completed in 118.485s with zero
  retries. Translation took 118.479s; parse, chunk plan, compose, final
  validation, and write together took only milliseconds.
- First full-episode local output lives under the temp workdir recorded in
  `/tmp/daredevil-subtitle-workdir.txt`, with latest run dir recorded at
  `latest-v2-run-dir.txt` inside that workdir. It has not been uploaded to the
  NAS yet.
- Style prompt decision: keep foreign personal names in Latin spelling
  (`Foggy`, `Karen`, `Matt`, `Nelson`, `Murdock`), while generic speaker labels
  may be translated (`Reporter` -> `记者`, `Officer` -> `警官`, `Man 1` ->
  `男1`, `Woman 2` -> `女2`).
- Second full-episode local V2 run used the updated prompt, `gpt-5.4-mini`,
  chunk size 100, concurrency 6, and 7 chunks for 621 cues. It completed in
  84.467s with zero retries. Translation took 84.461s; the slowest chunk was
  chunk 2 at 84.455s. Source and target both validated at 621 cues.

## Sensible Next Steps

- Rerun the Daredevil S02E01 subtitle with the updated speaker-label/name
  prompt through an endpoint backend once implemented, to measure CLI overhead.
- Upload the validated `2_Chinese.srt` to the NAS path if the user accepts this
  first translation result.
- Integrate the V2 runner into `scripts/translate-srt-upstream.sh` or add a
  Bazarr-facing switch so V2 can replace the upstream wrapper path.
- Add a small README section for Docker/Bazarr volume mount examples.
- Add validation for malformed SRT blocks and suspicious untranslated output.
- Tune `prompts/xiaohu-style-system.md` for existing sidecar subtitles rather
  than ASR cleanup once the V2 runner is ready.
- Add optional ASS sidecar smoke tests with a real model once a sample target
  library path is available.

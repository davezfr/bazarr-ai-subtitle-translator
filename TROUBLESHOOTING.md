# Troubleshooting

## Direct wrapper translates an unconfigured source SRT

Symptom:

Running `scripts/translate-srt-upstream.sh` directly on a subtitle whose
language suffix is not listed in `SUBTRANS_SOURCE_SUFFIXES` succeeds or attempts
to call the upstream translator.

Expected behavior:

The wrapper should reject the file before any model or upstream translator call,
with a message that the subtitle does not match configured source suffixes.

Fixed on: 2026-06-08

Verification:

```bash
sh tests/wrapper-behavior.sh
```

## Translated SRT contains empty subtitle entries

Symptom:

The upstream translator writes an SRT file with valid timestamp rows, but one or
more entries have no subtitle text.

Expected behavior:

The wrapper should delete the temporary output, fail the command, and avoid
publishing a final sidecar.

Fixed on: 2026-06-08

Verification:

```bash
sh tests/wrapper-behavior.sh
```

## Mixed-case English SRT writes `.en.zh.srt`

Symptom:

An input named `movie.en.SRT` or `movie.Eng.SrT` writes `movie.en.zh.srt`.

Expected behavior:

It should write `movie.zh.srt`.

Fixed on: 2026-06-08

Verification:

```bash
sh tests/wrapper-behavior.sh
```

## Model-generated SRT adds extra cues

Symptom:

Directly asking a model to translate and return full SRT can change subtitle
structure. In one full-episode test, an 80-cue source chunk returned 82 cues
because the model split one subtitle into multiple new SRT entries and invented
duplicate timestamps.

Expected behavior:

The model should translate text only. Local code should preserve source cue
numbers and timestamps, validate one returned translation per source cue, and
rebuild the final SRT itself.

Fixed on: 2026-06-09 for the experimental V2 standalone runner.

Verification:

```bash
sh tests/v2-translator.sh
```

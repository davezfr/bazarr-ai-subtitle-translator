# Troubleshooting

## OpenAI-compatible endpoint returns HTML instead of JSON

Symptom:

The OpenAI-compatible backend fails with a JSON parse error, and the saved
`.response.json` file starts with `<!doctype html>` or a web app title such as
`Sub2API - AI API Gateway`.

Cause:

The configured `OPENAI_BASE_URL` points at the gateway's web UI root instead of
the API base path. For Sub2API on the Mac mini, `http://mini:8080` serves the
web app, while the OpenAI-compatible API is under `http://mini:8080/v1`.

Expected behavior:

Set the base URL to the API root:

```bash
OPENAI_BASE_URL=http://mini:8080/v1
```

Verification:

```bash
curl "$OPENAI_BASE_URL/models"
```

The response should be JSON and include the configured model id.

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

## Translated chunk has correct cue numbers but shifted meanings

Symptom:

The translator returns exactly one translation per source cue and preserves all
cue numbers, but a run of translations semantically belongs to neighboring cues.
For example, cue 470's translated text may actually correspond to source cue
469, while the structural validator still passes.

Expected behavior:

Enable semantic alignment checking for high-quality runs:

```bash
--alignment-check model
```

or:

```bash
SUBTRANS_ALIGNMENT_CHECK=model
```

After deterministic structure validation, the workflow sends the source cue text
and candidate translations back through the same backend with an alignment
schema. Any reported issue fails that chunk and triggers retry.

Fixed on: 2026-06-09 for the experimental V2 standalone runner and generic
workflow CLI.

Known caveat:

The model-based checker can produce false positives on acceptable subtitle
phrasing, or put non-issues inside the `issues` array. Use it for high-quality
diagnostics and retesting suspected problem ranges. The default fast path keeps
`SUBTRANS_ALIGNMENT_CHECK=off` and relies on deterministic structure validation.

Verification:

```bash
sh tests/v2-translator.sh
```

## Synology `scp` fails with missing SFTP subsystem

Symptom:

Copying files with default `scp` from `dcloud` fails with:

```text
subsystem request failed on channel 0
scp: Connection closed
```

Expected workaround:

For NAS paths with spaces, stream the file through SSH instead of relying on
the remote SFTP subsystem or legacy scp quoting:

```bash
ssh dcloud 'cat "/volume1/path/input.srt"' > /tmp/input.srt
ssh dcloud 'cat > "/volume1/path/output.ass.tmp"' < /tmp/output.ass
ssh dcloud 'mv -f "/volume1/path/output.ass.tmp" "/volume1/path/output.ass"'
```

Diagnosed on: 2026-06-09 during the High-Rise bilingual ASS test.

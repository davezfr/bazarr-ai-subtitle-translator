# Bazarr AI Subtitle Translator

Translate Bazarr-downloaded SRT subtitles into target-language SRT or ASS
sidecar subtitles with an OpenAI-compatible LLM endpoint.

This project is intentionally small. It does not manage media libraries, search
subtitle providers, or talk to Plex directly. Bazarr downloads subtitles; this
tool translates the subtitle file Bazarr just downloaded.

## What It Does

```text
Bazarr downloads movie.en.srt or movie.fr.srt
  -> Bazarr custom post-processing calls this project
  -> OpenAI-compatible model translates the SRT text
  -> movie.zh.srt or movie.zh.ass is written next to the media file
  -> Plex sees the target-language sidecar subtitle
```

## Current Status

MVP:

- SRT input
- Configurable source language and source filename suffixes
- Configurable target language and target filename suffix
- SRT target-language output
- ASS target-language output
- ASS bilingual output: target language on top, original/source language below
- Experimental V2 deterministic chunked translator
- OpenAI-compatible API support
- Local Ollama support through `OPENAI_BASE_URL`
- Custom prompt file
- Existing output safety: skips when the configured output file already exists unless forced
- Output validation: timestamp count must match and translated subtitle entries
  must contain non-empty text
- Display-layer punctuation cleanup: ordinary terminal statement punctuation is
  removed from subtitle display text, while questions, exclamations, ellipses,
  and protected abbreviations are preserved
- Bazarr custom post-processing wrapper

Not yet included:

- VTT input support
- Bazarr wrapper integration for the V2 translator
- Built-in web UI
- Translation queue
- Plex refresh API call
- Subtitle sync/retiming

## Upstream Translator

The first implementation wraps
[Cerlancism/chatgpt-subtitle-translator](https://github.com/Cerlancism/chatgpt-subtitle-translator).

Pinned upstream commit:

```text
1c86a8a36a8900e5476b7b035d6e991a6870214c
```

Why this upstream:

- It is a focused Node CLI rather than a full subtitle manager.
- It already handles SRT parsing and translated SRT writing.
- It supports structured output to reduce line-count mismatch risk.
- It supports OpenAI-compatible providers, including Ollama.
- It accepts a custom system instruction, so this project can provide a
  subtitle-specific translation prompt without forking immediately.

This repository does not vendor upstream source code. `scripts/install-upstream.sh`
clones the pinned upstream version into `.runtime/`, which is ignored by Git.

## Requirements

- Node.js 20 or newer
- npm
- An OpenAI-compatible chat completions endpoint

For local translation, Ollama works:

```bash
ollama serve
ollama pull gemma4:latest
```

Use any model that can follow JSON/structured-output instructions reliably.

## Install

```bash
git clone https://github.com/davezfr/bazarr-ai-subtitle-translator.git
cd bazarr-ai-subtitle-translator
./scripts/install-upstream.sh
cp .env.example .env
```

Edit `.env` or export the same variables in your shell.

## Configure

Example for local Ollama and English-to-Chinese target-language SRT:

```bash
export OPENAI_BASE_URL="http://127.0.0.1:11434/v1"
export OPENAI_API_KEY="ollama"
export SUBTRANS_MODEL="gemma4:latest"
export SUBTRANS_SOURCE_LANGUAGE="English"
export SUBTRANS_SOURCE_SUFFIXES="en,eng,english"
export SUBTRANS_TARGET_LANGUAGE="Simplified Chinese"
export SUBTRANS_TARGET_SUFFIX="zh"
export SUBTRANS_OUTPUT_FORMAT="srt"
export SUBTRANS_OUTPUT_MODE="target"
```

When Bazarr runs inside Docker on another machine, do not use `127.0.0.1` for a
model server running elsewhere. Use the model server's LAN hostname or IP.

```bash
export OPENAI_BASE_URL="http://model-server.local:11434/v1"
```

## Translate Manually

```bash
./scripts/translate-srt-upstream.sh /path/to/movie.en.srt
```

This writes:

```text
/path/to/movie.zh.srt
```

You can also pass the output path explicitly:

```bash
./scripts/translate-srt-upstream.sh /path/to/movie.en.srt /path/to/movie.zh.srt
```

For French-to-Chinese:

```bash
SUBTRANS_SOURCE_LANGUAGE="French" \
SUBTRANS_SOURCE_SUFFIXES="fr,fra,french" \
SUBTRANS_TARGET_LANGUAGE="Simplified Chinese" \
SUBTRANS_TARGET_SUFFIX="zh" \
./scripts/translate-srt-upstream.sh /path/to/movie.fr.srt
```

For bilingual ASS output:

```bash
SUBTRANS_OUTPUT_FORMAT=ass \
SUBTRANS_OUTPUT_MODE=bilingual \
./scripts/translate-srt-upstream.sh /path/to/movie.en.srt
```

This writes `movie.zh.ass`. In bilingual ASS mode, the model still produces only
the target-language translation. The wrapper then combines translated text with
the original source text so the target language appears on top and the original
line appears below at a smaller size.

ASS output includes `PlayResX` and `PlayResY` based on
`SUBTRANS_ASS_HEIGHT` or the `--height` argument so libass has an explicit
scaling baseline. With that baseline, the default ASS sizes are real
resolution-relative values, such as Chinese 56 / source 36 for 1080p.

For bilingual ASS, each subtitle cue is rendered as two same-time ASS dialogue
events with separate styles:

```text
ZH style: target-language line, larger, white, higher bottom margin
EN style: source-language line, smaller, near-white pale yellow, lower bottom margin
```

The bilingual builder flattens existing SRT line breaks into one line per
language. This avoids four-line bilingual blocks when an original single-
language SRT cue was wrapped across two lines. Future cue-splitting can improve
very long dialogue, but this builder does not change timing.

Display output removes ordinary statement punctuation at subtitle line endings:
Chinese `。` / `，` and English `.` / `,`. It preserves question marks,
exclamation marks, ellipses, and protected English abbreviations such as
`Mr.` or `U.S.`. This is a post-processing display rule, not part of the
translation prompt.

SRT bilingual output is intentionally rejected because SRT cannot express
different font sizes or visual hierarchy inside a single subtitle cue. Use ASS
for bilingual subtitles.

## Translate With V2

The experimental V2 path keeps SRT structure in local code and asks the model to
return target-language text only:

```bash
python3 scripts/translate-srt-v2.py \
  --input /path/to/movie.en.srt \
  --output /path/to/movie.zh.srt \
  --summary /path/to/movie.zh.summary.json \
  --backend codex-cli \
  --model gpt-5.4-mini \
  --chunk-size 100 \
  --concurrency 3
```

The output SRT is rebuilt from the source cue numbers and timestamps. The model
does not write final SRT, cannot change timestamps, and failed chunks are
retried independently.

## Bazarr Integration

In Bazarr:

```text
Settings -> Subtitles -> Use Custom Post-Processing
```

Enable custom post-processing and set the command to the script path visible
inside the Bazarr container:

```bash
/config/scripts/bazarr-postprocess.sh "{{subtitles}}" 2>&1
```

Important: the script path must exist inside the Bazarr container. If this
project lives on the host, mount it into the Bazarr container or copy the scripts
and `.runtime/` directory into Bazarr's `/config/scripts` area.

## Environment Variables

```text
OPENAI_BASE_URL             OpenAI-compatible base URL.
OPENAI_API_KEY              API key. Use any non-empty value for local Ollama.
SUBTRANS_MODEL              Model name. Default: gemma4:latest.
SUBTRANS_SOURCE_LANGUAGE    Source language label passed to the model. Default: English.
SUBTRANS_SOURCE_SUFFIXES    Comma-separated filename suffixes accepted as source subtitles.
                            Supports dot or underscore separators, such as .en.srt or _English.srt.
SUBTRANS_TARGET_LANGUAGE    Target language label passed to the model. Default: Simplified Chinese.
SUBTRANS_TARGET_SUFFIX      Output filename language suffix. Default: zh.
SUBTRANS_OUTPUT_FORMAT      Output format: srt or ass. Default: srt.
SUBTRANS_OUTPUT_MODE        Output mode: target or bilingual. Bilingual requires ass.
SUBTRANS_BACKEND            V2 backend: codex-cli, fake, or fake-extra.
SUBTRANS_CHUNK_SIZE         V2 cues per translation chunk. Default: 100.
SUBTRANS_CONCURRENCY        V2 parallel translation workers. Default: 3.
SUBTRANS_MAX_RETRIES        V2 retries per failed chunk. Default: 3.
SUBTRANS_CONTEXT_TOKENS     Translation history context budget. Default: 2000.
SUBTRANS_TEMPERATURE        Translation temperature. Default: 0.
SUBTRANS_FORCE              Set to 1 to overwrite existing output.
SUBTRANS_FORMAT_PROMPT_FILE Format contract prompt path.
SUBTRANS_PROMPT_FILE        Style/custom prompt file path appended after the format contract.
SUBTRANS_ASS_TARGET_SIZE    Optional ASS target-language font size.
SUBTRANS_ASS_SOURCE_SIZE    Optional ASS source-language font size.
SUBTRANS_ASS_HEIGHT         Optional video height used to pick ASS default sizes.
SUBTRANS_ASS_MARGINV        Optional ASS bottom margin. In bilingual ASS this controls the source line.
SUBTRANS_ASS_FONT           Optional ASS target-language font name.
SUBTRANS_ASS_SOURCE_FONT    Optional ASS source-language font name.
SUBTRANS_RUNTIME_DIR        Runtime dependency directory. Default: .runtime.
SUBTRANS_UPSTREAM_DIR       Installed upstream directory.
SUBTRANS_UPSTREAM_REF       Upstream commit/ref to install.
SUBTRANS_LOG_LEVEL          Upstream log level. Default: warn.
```

## Prompt

Default format contract:

```text
prompts/format-contract-system.md
```

Default style prompt:

```text
prompts/xiaohu-style-system.md
```

The wrapper prepends the format contract before the style prompt. This keeps
format rules such as one-to-one subtitle correspondence, target-language-only
model output, no extra comments, and tag preservation stable even when the
translation style prompt changes.

Use `SUBTRANS_PROMPT_FILE` for your translation style guide. Use
`SUBTRANS_FORMAT_PROMPT_FILE` only when changing the pipeline contract itself.
When overriding either value from Bazarr or Docker, use paths that are absolute
inside that container.

The default style prompt keeps foreign personal names in Latin spelling, such
as Foggy, Karen, Matt, Nelson, and Murdock. Generic speaker labels may be
translated for readability, such as Reporter -> 记者, Officer -> 警官, Man 1 ->
男1, and Woman 2 -> 女2.

## Development

Run fast wrapper behavior checks without calling a model:

```bash
sh tests/wrapper-behavior.sh
sh tests/prompt-contract.sh
```

Run a smoke test with local Ollama:

```bash
./scripts/smoke-test.sh
```

The wrapper behavior test uses a fake upstream translator to check local shell
logic such as filename guards, output naming, and ASS composition. The smoke
test creates a temporary English SRT, runs the real upstream wrapper with the
default English-to-Chinese SRT configuration, and checks that the output SRT
exists.

## Xiaohu-Inspired Workflow Boundary

This project borrows the proven shape of
[xiaohu-video-translate](https://github.com/xiaohuailabs/xiaohu-video-translate)
from the point where a timed subtitle already exists:

```text
existing SRT
  -> translate target-language SRT
  -> polish through the style prompt
  -> optionally compose ASS sidecar
```

It does not download videos, extract audio, run Whisper, or burn subtitles into
video files. Bazarr already supplies the timed subtitle file, and Plex/Bazarr
consume the sidecar.

For bilingual output, this project follows the same practical lesson as Xiaohu:
SRT is a poor bilingual presentation format, so bilingual output is ASS only.

## V2 Translation Direction

The experimental V2 translator is designed for already-timed sidecar subtitles. Unlike
Whisper output, these subtitles usually do not need ASR cleanup, aggressive
de-redundancy, punctuation stripping, retiming, or re-segmentation.

The V2 boundary is:

```text
model owns language
program owns subtitle structure
```

Current flow:

```text
source SRT
  -> parse cue list
  -> split into chunks of roughly 80-120 cues
  -> translate chunks in parallel workers
  -> validate structured worker output with code
  -> retry failed chunks only
  -> rebuild target-language SRT from original cue ids and timestamps
  -> optionally compose target/source bilingual ASS
```

Translation workers may be parallel sub-agents or CLI worker processes. They
should return structured target-language text only, not full SRT. Cue counts,
cue ids, timestamps, empty translations, and accidental extra output are checked
by deterministic code rather than by another model.

An optional QA agent can sample translations for naturalness, tone, terminology
consistency, and obvious mistranslations. It is a quality layer, not the format
validator.

See `IMPLEMENTATION_PLAN.md` for the V2 module breakdown and first full-episode
test plan.

## Roadmap

- Add VTT input support.
- Integrate the V2 deterministic chunked translator into the Bazarr wrapper.
- Add optional Plex library refresh hook.
- Add stronger validation for malformed SRT blocks and suspicious untranslated
  output.
- Package as a Docker image for easier Bazarr deployment.
- Add a small HTTP service mode for model servers running on a different host.

## License

MIT. See [LICENSE](LICENSE).

This project wraps an MIT-licensed upstream project. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

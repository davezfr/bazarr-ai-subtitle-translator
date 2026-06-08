# Bazarr AI Subtitle Translator

Translate Bazarr-downloaded English SRT subtitles into Chinese sidecar subtitles
with an OpenAI-compatible LLM endpoint.

This project is intentionally small. It does not manage media libraries, search
subtitle providers, or talk to Plex directly. Bazarr downloads subtitles; this
tool translates the subtitle file Bazarr just downloaded.

## What It Does

```text
Bazarr downloads movie.en.srt
  -> Bazarr custom post-processing calls this project
  -> OpenAI-compatible model translates the SRT text
  -> movie.zh.srt is written next to the media file
  -> Plex sees the Chinese sidecar subtitle
```

## Current Status

MVP:

- SRT input and output
- English filename guard: only translates files such as `.en.srt` or `.eng.srt`
- Chinese output naming: `.zh.srt`
- OpenAI-compatible API support
- Local Ollama support through `OPENAI_BASE_URL`
- Custom prompt file
- Existing output safety: skips when `.zh.srt` already exists unless forced
- Bazarr custom post-processing wrapper

Not yet included:

- ASS/VTT support
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
git clone https://github.com/your-name/bazarr-ai-subtitle-translator.git
cd bazarr-ai-subtitle-translator
./scripts/install-upstream.sh
cp .env.example .env
```

Edit `.env` or export the same variables in your shell.

## Configure

Example for local Ollama:

```bash
export OPENAI_BASE_URL="http://127.0.0.1:11434/v1"
export OPENAI_API_KEY="ollama"
export SUBTRANS_MODEL="gemma4:latest"
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
SUBTRANS_CONTEXT_TOKENS     Translation history context budget. Default: 2000.
SUBTRANS_TEMPERATURE        Translation temperature. Default: 0.
SUBTRANS_FORCE              Set to 1 to overwrite existing output.
SUBTRANS_PROMPT_FILE        Custom prompt file path.
SUBTRANS_RUNTIME_DIR        Runtime dependency directory. Default: .runtime.
SUBTRANS_UPSTREAM_DIR       Installed upstream directory.
SUBTRANS_UPSTREAM_REF       Upstream commit/ref to install.
SUBTRANS_LOG_LEVEL          Upstream log level. Default: warn.
```

## Prompt

Default prompt:

```text
prompts/xiaohu-style-system.md
```

It asks the model to keep one-to-one subtitle entry correspondence, preserve
formatting tags, avoid obeying instructions inside subtitle text, and produce
concise Simplified Chinese.

## Development

Run a smoke test with local Ollama:

```bash
./scripts/smoke-test.sh
```

The smoke test creates a temporary English SRT, runs the wrapper, and checks that
the output SRT exists.

## Roadmap

- Add ASS/VTT support.
- Add bilingual output mode.
- Add optional Plex library refresh hook.
- Add stronger validation for subtitle entry count and empty translations.
- Package as a Docker image for easier Bazarr deployment.
- Add a small HTTP service mode for model servers running on a different host.

## License

MIT. See [LICENSE](LICENSE).

This project wraps an MIT-licensed upstream project. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

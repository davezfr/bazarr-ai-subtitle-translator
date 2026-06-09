#!/usr/bin/env python3
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


TIME_RE = re.compile(r"(\d{2}:\d{2}:\d{2}[,.]\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2}[,.]\d{3})")
TIMESTAMP_ARTIFACT_RE = re.compile(r"\d{2}:\d{2}:\d{2}[,.]\d{3}\s*-->\s*\d{2}:\d{2}:\d{2}[,.]\d{3}")


@dataclass(frozen=True)
class Cue:
    number: str
    start: str
    end: str
    text_lines: list[str]

    @property
    def text(self) -> str:
        return "\n".join(self.text_lines)


@dataclass(frozen=True)
class Chunk:
    index: int
    cues: list[Cue]

    @property
    def first_cue(self) -> str:
        return self.cues[0].number

    @property
    def last_cue(self) -> str:
        return self.cues[-1].number


def monotonic() -> float:
    return time.monotonic()


def parse_srt(text: str) -> list[Cue]:
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    blocks = [block for block in re.split(r"\n\s*\n", normalized.strip()) if block.strip()]
    cues: list[Cue] = []

    for block in blocks:
        lines = [line.rstrip() for line in block.split("\n") if line.strip()]
        if len(lines) < 3:
            raise ValueError(f"malformed SRT block: {block[:120]!r}")
        timestamp = TIME_RE.search(lines[1])
        if not timestamp:
            raise ValueError(f"missing timestamp row in block: {block[:120]!r}")
        cues.append(
            Cue(
                number=lines[0].strip(),
                start=timestamp.group(1).replace(".", ","),
                end=timestamp.group(2).replace(".", ","),
                text_lines=lines[2:],
            )
        )

    return cues


def chunk_cues(cues: list[Cue], chunk_size: int) -> list[Chunk]:
    if chunk_size < 1:
        raise ValueError("--chunk-size must be greater than 0")
    return [
        Chunk(index=index + 1, cues=cues[offset : offset + chunk_size])
        for index, offset in enumerate(range(0, len(cues), chunk_size))
    ]


def normalize_translation(value: str) -> str:
    text = value.replace("\r\n", "\n").replace("\r", "\n").strip()
    text = re.sub(r"^```(?:json|srt)?\s*", "", text)
    text = re.sub(r"\s*```$", "", text)
    return "\n".join(line.strip() for line in text.split("\n") if line.strip())


def validate_chunk_response(chunk: Chunk, response: dict[str, Any]) -> tuple[list[dict[str, str]], float]:
    started = monotonic()
    translations = response.get("translations")
    if not isinstance(translations, list):
        raise ValueError(f"chunk {chunk.index}: missing translations array")
    if len(translations) != len(chunk.cues):
        raise ValueError(
            f"chunk {chunk.index}: translation count mismatch "
            f"source={len(chunk.cues)} target={len(translations)}"
        )

    validated: list[dict[str, str]] = []
    for offset, (cue, item) in enumerate(zip(chunk.cues, translations), start=1):
        if not isinstance(item, dict):
            raise ValueError(f"chunk {chunk.index}: translation item {offset} is not an object")
        number = str(item.get("number", "")).strip()
        if number != cue.number:
            raise ValueError(
                f"chunk {chunk.index}: cue number mismatch at item {offset}: "
                f"{cue.number} != {number}"
            )
        translation = normalize_translation(str(item.get("translation", "")))
        if not translation:
            raise ValueError(f"chunk {chunk.index}: empty translation for cue {cue.number}")
        if TIMESTAMP_ARTIFACT_RE.search(translation):
            raise ValueError(f"chunk {chunk.index}: translation for cue {cue.number} contains a timestamp")
        validated.append({"number": cue.number, "translation": translation})

    return validated, monotonic() - started


def format_srt(cues: list[Cue], translations: list[dict[str, str]]) -> str:
    if len(cues) != len(translations):
        raise ValueError(f"final compose count mismatch source={len(cues)} target={len(translations)}")

    blocks: list[str] = []
    for cue, item in zip(cues, translations):
        if cue.number != item["number"]:
            raise ValueError(f"final compose cue mismatch: {cue.number} != {item['number']}")
        text_lines = [line for line in item["translation"].split("\n") if line.strip()]
        blocks.append("\n".join([cue.number, f"{cue.start} --> {cue.end}", *text_lines]))

    return "\n\n".join(blocks) + "\n\n"


def validate_final_srt(source_cues: list[Cue], output_text: str) -> float:
    started = monotonic()
    output_cues = parse_srt(output_text)
    if len(output_cues) != len(source_cues):
        raise ValueError(f"final cue count mismatch source={len(source_cues)} output={len(output_cues)}")
    for source, output in zip(source_cues, output_cues):
        if source.number != output.number:
            raise ValueError(f"final cue number mismatch: {source.number} != {output.number}")
        if source.start != output.start or source.end != output.end:
            raise ValueError(f"final timestamp mismatch at cue {source.number}")
        if not output.text.strip():
            raise ValueError(f"final empty text at cue {source.number}")
    return monotonic() - started


def read_optional(path: Path) -> str:
    if path.exists():
        return path.read_text(encoding="utf-8")
    return ""


def build_prompt(args: argparse.Namespace, chunk: Chunk) -> str:
    format_prompt = read_optional(Path(args.format_prompt_file)) if args.format_prompt_file else ""
    style_prompt = read_optional(Path(args.prompt_file)) if args.prompt_file else ""
    payload = {
        "source_language": args.source_language,
        "target_language": args.target_language,
        "chunk": {
            "index": chunk.index,
            "first_cue": chunk.first_cue,
            "last_cue": chunk.last_cue,
        },
        "items": [{"number": cue.number, "text": cue.text} for cue in chunk.cues],
    }
    return f"""Translate subtitle cue text from {args.source_language} to {args.target_language}.

Pipeline contract:
- Return JSON matching the provided schema.
- Return exactly one translation object for every input item.
- Preserve every number value exactly.
- Do not create, merge, split, remove, or reorder cue objects.
- Translate text only.
- Do not include SRT cue numbers, timestamps, markdown, explanations, or metadata in translations.
- Keep output concise enough for subtitle display.

Format prompt:
{format_prompt}

Style prompt:
{style_prompt}

Input JSON:
{json.dumps(payload, ensure_ascii=False, indent=2)}
"""


def write_schema(path: Path) -> None:
    schema = {
        "type": "object",
        "additionalProperties": False,
        "required": ["translations"],
        "properties": {
            "translations": {
                "type": "array",
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "required": ["number", "translation"],
                    "properties": {
                        "number": {"type": "string"},
                        "translation": {"type": "string"},
                    },
                },
            }
        },
    }
    path.write_text(json.dumps(schema, ensure_ascii=False, indent=2), encoding="utf-8")


def load_json(path: Path) -> dict[str, Any]:
    raw = path.read_text(encoding="utf-8").strip()
    raw = re.sub(r"^```(?:json)?\s*", "", raw)
    raw = re.sub(r"\s*```$", "", raw)
    return json.loads(raw)


def fake_response(chunk: Chunk, *, extra: bool = False) -> dict[str, Any]:
    translations = [
        {"number": cue.number, "translation": f"假译：{cue.text}"}
        for cue in chunk.cues
    ]
    if extra:
        translations.append({"number": "__extra__", "translation": "多余字幕"})
    return {"translations": translations}


def build_codex_home(base_dir: Path, chunk: Chunk, attempt: int) -> Path:
    home = base_dir / f"codex-home-chunk-{chunk.index:03d}-attempt-{attempt}"
    if home.exists():
        shutil.rmtree(home)
    home.mkdir(parents=True)
    auth = Path.home() / ".codex" / "auth.json"
    if not auth.exists():
        raise RuntimeError("missing ~/.codex/auth.json for codex-cli backend")
    shutil.copy2(auth, home / "auth.json")
    return home


def run_codex_chunk(args: argparse.Namespace, chunk: Chunk, attempt: int, work_dir: Path, schema_path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    prompt_path = work_dir / f"chunk-{chunk.index:03d}-attempt-{attempt}.prompt.txt"
    output_path = work_dir / f"chunk-{chunk.index:03d}-attempt-{attempt}.json"
    log_path = work_dir / f"chunk-{chunk.index:03d}-attempt-{attempt}.jsonl"
    prompt_path.write_text(build_prompt(args, chunk), encoding="utf-8")

    codex_home = build_codex_home(work_dir, chunk, attempt)
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    cmd = [
        "codex",
        "exec",
        "--ephemeral",
        "--sandbox",
        "read-only",
        "--ignore-user-config",
        "--ignore-rules",
        "--skip-git-repo-check",
        "--cd",
        str(work_dir),
        "-m",
        args.model,
        "--json",
        "--output-schema",
        str(schema_path),
        "-o",
        str(output_path),
        "-",
    ]

    call_started = monotonic()
    with prompt_path.open("rb") as stdin, log_path.open("wb") as log:
        proc = subprocess.run(cmd, stdin=stdin, stdout=log, stderr=subprocess.STDOUT, env=env)
    call_seconds = monotonic() - call_started

    if proc.returncode != 0:
        log_text = log_path.read_text(encoding="utf-8", errors="replace")
        raise RuntimeError(f"codex failed with exit {proc.returncode}: {log_text[-2000:]}")

    response = load_json(output_path)
    return response, {
        "prompt_path": str(prompt_path),
        "output_path": str(output_path),
        "log_path": str(log_path),
        "worker_seconds": round(call_seconds, 3),
    }


def run_chunk(args: argparse.Namespace, chunk: Chunk, work_dir: Path, schema_path: Path) -> tuple[int, list[dict[str, str]], dict[str, Any]]:
    attempts: list[dict[str, Any]] = []

    for attempt in range(1, args.max_retries + 1):
        attempt_started = monotonic()
        try:
            if args.backend == "fake":
                worker_started = monotonic()
                response = fake_response(chunk)
                worker_meta = {"worker_seconds": round(monotonic() - worker_started, 3)}
            elif args.backend == "fake-extra":
                worker_started = monotonic()
                response = fake_response(chunk, extra=True)
                worker_meta = {"worker_seconds": round(monotonic() - worker_started, 3)}
            elif args.backend == "codex-cli":
                response, worker_meta = run_codex_chunk(args, chunk, attempt, work_dir, schema_path)
            else:
                raise ValueError(f"unsupported backend: {args.backend}")

            translations, validation_seconds = validate_chunk_response(chunk, response)
            attempts.append(
                {
                    "attempt": attempt,
                    "status": "ok",
                    **worker_meta,
                    "validation_seconds": round(validation_seconds, 3),
                    "total_seconds": round(monotonic() - attempt_started, 3),
                }
            )
            return chunk.index, translations, {
                "chunk": chunk.index,
                "first_cue": chunk.first_cue,
                "last_cue": chunk.last_cue,
                "cue_count": len(chunk.cues),
                "attempts": attempts,
            }
        except Exception as error:
            attempts.append(
                {
                    "attempt": attempt,
                    "status": "failed",
                    "error": str(error),
                    "total_seconds": round(monotonic() - attempt_started, 3),
                }
            )
            if attempt >= args.max_retries:
                raise RuntimeError(f"chunk {chunk.index} failed after {attempt} attempts: {error}") from error

    raise RuntimeError(f"chunk {chunk.index} failed unexpectedly")


def run_translation_stage(args: argparse.Namespace, chunks: list[Chunk], work_dir: Path, schema_path: Path) -> tuple[list[dict[str, str]], list[dict[str, Any]], float]:
    started = monotonic()
    by_chunk: dict[int, list[dict[str, str]]] = {}
    summaries: dict[int, dict[str, Any]] = {}

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as executor:
        futures = {
            executor.submit(run_chunk, args, chunk, work_dir / f"chunk-{chunk.index:03d}", schema_path): chunk
            for chunk in chunks
        }
        for future in concurrent.futures.as_completed(futures):
            chunk_index, translations, summary = future.result()
            by_chunk[chunk_index] = translations
            summaries[chunk_index] = summary
            print(
                f"chunk {chunk_index}/{len(chunks)} cues "
                f"{summary['first_cue']}-{summary['last_cue']}: ok",
                flush=True,
            )

    merged: list[dict[str, str]] = []
    for chunk in chunks:
        merged.extend(by_chunk[chunk.index])

    return merged, [summaries[chunk.index] for chunk in chunks], monotonic() - started


def parse_args() -> argparse.Namespace:
    project_dir = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description="Deterministic V2 SRT translator.")
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--summary")
    parser.add_argument("--backend", choices=["fake", "fake-extra", "codex-cli"], default=os.environ.get("SUBTRANS_BACKEND", "codex-cli"))
    parser.add_argument("--model", default=os.environ.get("SUBTRANS_MODEL", "gpt-5.4-mini"))
    parser.add_argument("--source-language", default=os.environ.get("SUBTRANS_SOURCE_LANGUAGE", "English"))
    parser.add_argument("--target-language", default=os.environ.get("SUBTRANS_TARGET_LANGUAGE", "Simplified Chinese"))
    parser.add_argument("--chunk-size", type=int, default=int(os.environ.get("SUBTRANS_CHUNK_SIZE", "100")))
    parser.add_argument("--concurrency", type=int, default=int(os.environ.get("SUBTRANS_CONCURRENCY", "3")))
    parser.add_argument("--max-retries", type=int, default=int(os.environ.get("SUBTRANS_MAX_RETRIES", "3")))
    parser.add_argument(
        "--format-prompt-file",
        default=os.environ.get("SUBTRANS_FORMAT_PROMPT_FILE", str(project_dir / "prompts" / "format-contract-system.md")),
    )
    parser.add_argument(
        "--prompt-file",
        default=os.environ.get("SUBTRANS_PROMPT_FILE", str(project_dir / "prompts" / "xiaohu-style-system.md")),
    )
    parser.add_argument("--work-dir", help="Directory for chunk prompts, outputs, logs, and schemas.")
    parser.add_argument("--keep-work-dir", action="store_true")
    args = parser.parse_args()
    if args.concurrency < 1:
        parser.error("--concurrency must be greater than 0")
    if args.max_retries < 1:
        parser.error("--max-retries must be greater than 0")
    return args


def main() -> int:
    args = parse_args()
    total_started = monotonic()
    input_path = Path(args.input)
    output_path = Path(args.output)
    if not input_path.exists():
        print(f"translate-srt-v2: input not found: {input_path}", file=sys.stderr)
        return 1

    timings: dict[str, float] = {}
    parse_started = monotonic()
    source_cues = parse_srt(input_path.read_text(encoding="utf-8-sig"))
    timings["parse_seconds"] = round(monotonic() - parse_started, 3)
    if not source_cues:
        print("translate-srt-v2: input has no cues", file=sys.stderr)
        return 1

    plan_started = monotonic()
    chunks = chunk_cues(source_cues, args.chunk_size)
    timings["chunk_plan_seconds"] = round(monotonic() - plan_started, 3)

    if args.work_dir:
        work_dir = Path(args.work_dir)
        work_dir.mkdir(parents=True, exist_ok=True)
        cleanup_work_dir = False
    else:
        work_dir = Path(tempfile.mkdtemp(prefix="subtitle-v2-run."))
        cleanup_work_dir = not args.keep_work_dir

    schema_path = work_dir / "translation.schema.json"
    write_schema(schema_path)
    for chunk in chunks:
        (work_dir / f"chunk-{chunk.index:03d}").mkdir(parents=True, exist_ok=True)

    print(
        f"translate-srt-v2: cues={len(source_cues)} chunks={len(chunks)} "
        f"chunk_size={args.chunk_size} concurrency={args.concurrency} backend={args.backend}",
        flush=True,
    )

    try:
        translations, chunk_summaries, translation_seconds = run_translation_stage(args, chunks, work_dir, schema_path)
        timings["translation_seconds"] = round(translation_seconds, 3)

        compose_started = monotonic()
        output_text = format_srt(source_cues, translations)
        timings["compose_seconds"] = round(monotonic() - compose_started, 3)

        final_validation_seconds = validate_final_srt(source_cues, output_text)
        timings["final_validation_seconds"] = round(final_validation_seconds, 3)

        write_started = monotonic()
        output_path.write_text(output_text, encoding="utf-8")
        timings["write_seconds"] = round(monotonic() - write_started, 3)
        timings["total_seconds"] = round(monotonic() - total_started, 3)

        summary = {
            "backend": args.backend,
            "model": args.model,
            "input": str(input_path),
            "output": str(output_path),
            "work_dir": str(work_dir),
            "cue_count": len(source_cues),
            "chunk_size": args.chunk_size,
            "concurrency": args.concurrency,
            "chunks": len(chunks),
            "timings": timings,
            "chunk_summaries": chunk_summaries,
        }

        if args.summary:
            Path(args.summary).write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps(summary, ensure_ascii=False, indent=2), flush=True)
        return 0
    finally:
        if cleanup_work_dir:
            shutil.rmtree(work_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())

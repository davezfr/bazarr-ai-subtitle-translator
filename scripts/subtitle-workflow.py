#!/usr/bin/env python3
"""Generic subtitle translation workflow CLI.

This is the product-facing entrypoint for translating an existing SRT file.
Bazarr, Skills, shell scripts, or future HTTP adapters can call this workflow
without changing the core translation and display pipeline.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


def monotonic() -> float:
    return time.monotonic()


def project_dir() -> Path:
    return Path(__file__).resolve().parent.parent


def parse_suffixes(value: str) -> list[str]:
    suffixes: list[str] = []
    for part in value.split(","):
        suffix = part.strip().lower().lstrip(".").lstrip("_")
        if suffix:
            suffixes.append(suffix)
    return suffixes


def strip_source_suffix(input_path: Path, source_suffixes: list[str]) -> str:
    stem = input_path.stem
    lower_stem = stem.lower()
    for suffix in source_suffixes:
        for separator in (".", "_"):
            needle = f"{separator}{suffix}"
            if lower_stem.endswith(needle):
                return stem[: -len(needle)]
    return stem


def resolve_output_format(output_mode: str, output_format: str | None) -> str:
    if output_format:
        resolved = output_format.lower()
    elif output_mode == "bilingual":
        resolved = "ass"
    else:
        resolved = "srt"

    if output_mode == "bilingual" and resolved != "ass":
        raise ValueError("bilingual output requires ASS output format")
    return resolved


def ensure_can_write(paths: list[Path], force: bool) -> None:
    if force:
        return
    for path in paths:
        if path.exists():
            raise FileExistsError(f"output already exists: {path}")


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def run_command(command: list[str]) -> None:
    subprocess.run(command, check=True)


def run_translation(args: argparse.Namespace, target_srt: Path, summary_path: Path) -> dict[str, Any]:
    command = [
        sys.executable,
        str(project_dir() / "scripts" / "translate-srt-v2.py"),
        "--input",
        str(args.input),
        "--output",
        str(target_srt),
        "--summary",
        str(summary_path),
        "--backend",
        args.backend,
        "--model",
        args.model,
        "--source-language",
        args.source_language,
        "--target-language",
        args.target_language,
        "--max-retries",
        str(args.max_retries),
        "--temperature",
        str(args.temperature),
        "--alignment-check",
        args.alignment_check,
    ]

    if args.cli_command:
        command.extend(["--cli-command", args.cli_command])
    if args.openai_base_url:
        command.extend(["--openai-base-url", args.openai_base_url])
    if args.openai_api_key:
        command.extend(["--openai-api-key", args.openai_api_key])
    command.extend(["--openai-timeout", str(args.openai_timeout)])
    command.extend(["--openai-response-format", args.openai_response_format])
    if args.format_prompt_file:
        command.extend(["--format-prompt-file", str(args.format_prompt_file)])
    if args.endpoint_prompt_file:
        command.extend(["--endpoint-prompt-file", str(args.endpoint_prompt_file)])
    if args.prompt_file:
        command.extend(["--prompt-file", str(args.prompt_file)])
    if args.work_dir:
        command.extend(["--work-dir", str(args.work_dir)])
    if args.keep_work_dir:
        command.append("--keep-work-dir")

    run_command(command)
    return read_json(summary_path)


def run_ass_builder(args: argparse.Namespace, target_srt: Path, output_ass: Path) -> float:
    started = monotonic()
    command = [
        sys.executable,
        str(project_dir() / "scripts" / "build-ass-subtitle.py"),
        "--source",
        str(args.input),
        "--target",
        str(target_srt),
        "--output",
        str(output_ass),
        "--mode",
        args.output_mode,
        "--primary-script",
        args.primary_script,
        "--secondary-script",
        args.secondary_script,
    ]

    if args.ass_height is not None:
        command.extend(["--height", str(args.ass_height)])
    if args.primary_size is not None:
        command.extend(["--primary-size", str(args.primary_size)])
    if args.secondary_size is not None:
        command.extend(["--secondary-size", str(args.secondary_size)])
    if args.primary_font:
        command.extend(["--primary-font", args.primary_font])
    if args.secondary_font:
        command.extend(["--secondary-font", args.secondary_font])
    if args.marginv is not None:
        command.extend(["--marginv", str(args.marginv)])

    run_command(command)
    return monotonic() - started


def parse_args() -> argparse.Namespace:
    env = os.environ
    repo_root = project_dir()
    parser = argparse.ArgumentParser(description="Translate an existing SRT file and optionally compose ASS output.")
    parser.add_argument("--input", required=True, type=Path, help="Source SRT file.")
    parser.add_argument("--output-dir", type=Path, help="Directory for generated sidecars. Defaults to input directory.")
    parser.add_argument("--output-prefix", help="Output filename stem before language suffix. Defaults to input stem without source suffix.")
    parser.add_argument(
        "--source-suffixes",
        default=env.get("SUBTRANS_SOURCE_SUFFIXES", "en,eng,english"),
        help="Comma-separated source suffixes to strip from the output stem. This is naming only, not a safety gate.",
    )
    parser.add_argument("--source-language", default=env.get("SUBTRANS_SOURCE_LANGUAGE", "English"))
    parser.add_argument("--target-language", default=env.get("SUBTRANS_TARGET_LANGUAGE", "Simplified Chinese"))
    parser.add_argument("--target-suffix", default=env.get("SUBTRANS_TARGET_SUFFIX", "zh"), help="Primary-language output suffix, e.g. zh, fr, en.")
    parser.add_argument("--output-mode", choices=["target", "bilingual"], default=env.get("SUBTRANS_OUTPUT_MODE", "target").lower())
    parser.add_argument("--output-format", choices=["srt", "ass"], default=env.get("SUBTRANS_OUTPUT_FORMAT") or None)
    parser.add_argument("--summary", type=Path, help="Write workflow summary JSON.")
    parser.add_argument("--force", action="store_true", default=env.get("SUBTRANS_FORCE", "0") == "1")

    parser.add_argument(
        "--backend",
        choices=["fake", "fake-extra", "codex-cli", "openai-compatible"],
        default=env.get("SUBTRANS_BACKEND", "openai-compatible"),
    )
    parser.add_argument("--model", default=env.get("SUBTRANS_MODEL", "gpt-5.4-mini"))
    parser.add_argument("--max-retries", type=int, default=int(env.get("SUBTRANS_MAX_RETRIES", "3")))
    parser.add_argument("--temperature", type=float, default=float(env.get("SUBTRANS_TEMPERATURE", "0")))
    parser.add_argument(
        "--alignment-check",
        choices=["off", "model"],
        default=env.get("SUBTRANS_ALIGNMENT_CHECK", "off"),
        help="Optional model-based semantic alignment gate for each translated chunk.",
    )
    parser.set_defaults(cli_command=None)
    parser.add_argument("--openai-base-url", default=env.get("OPENAI_BASE_URL", env.get("SUBTRANS_BASE_URL", "http://127.0.0.1:11434/v1")))
    parser.add_argument("--openai-api-key", default=env.get("OPENAI_API_KEY", "ollama"))
    parser.add_argument("--openai-timeout", type=float, default=float(env.get("SUBTRANS_OPENAI_TIMEOUT", "300")))
    parser.add_argument(
        "--openai-response-format",
        choices=["none", "json_object", "json_schema"],
        default=env.get("SUBTRANS_OPENAI_RESPONSE_FORMAT", "json_schema"),
    )
    parser.add_argument("--format-prompt-file", type=Path, default=Path(env["SUBTRANS_FORMAT_PROMPT_FILE"]) if "SUBTRANS_FORMAT_PROMPT_FILE" in env else None)
    parser.add_argument(
        "--endpoint-prompt-file",
        type=Path,
        default=Path(env.get("SUBTRANS_ENDPOINT_PROMPT_FILE", repo_root / "prompts" / "endpoint-format-contract-system.md")),
    )
    parser.add_argument("--prompt-file", type=Path, default=Path(env["SUBTRANS_PROMPT_FILE"]) if "SUBTRANS_PROMPT_FILE" in env else None)
    parser.add_argument("--work-dir", type=Path, help="Directory for chunk prompts, outputs, logs, and schemas.")
    parser.add_argument("--keep-work-dir", action="store_true")

    parser.add_argument("--ass-height", type=int, default=int(env["SUBTRANS_ASS_HEIGHT"]) if "SUBTRANS_ASS_HEIGHT" in env else None)
    parser.add_argument("--primary-script", choices=["cjk", "latin"], default=env.get("SUBTRANS_ASS_PRIMARY_SCRIPT", "cjk"))
    parser.add_argument("--secondary-script", choices=["cjk", "latin"], default=env.get("SUBTRANS_ASS_SECONDARY_SCRIPT", "latin"))
    parser.add_argument("--primary-size", type=int, default=int(env["SUBTRANS_ASS_PRIMARY_SIZE"]) if "SUBTRANS_ASS_PRIMARY_SIZE" in env else None)
    parser.add_argument("--secondary-size", type=int, default=int(env["SUBTRANS_ASS_SECONDARY_SIZE"]) if "SUBTRANS_ASS_SECONDARY_SIZE" in env else None)
    parser.add_argument("--primary-font", default=env.get("SUBTRANS_ASS_PRIMARY_FONT"))
    parser.add_argument("--secondary-font", default=env.get("SUBTRANS_ASS_SECONDARY_FONT"))
    parser.add_argument("--marginv", type=int, default=int(env["SUBTRANS_ASS_MARGINV"]) if "SUBTRANS_ASS_MARGINV" in env else None)

    args = parser.parse_args()
    args.output_mode = args.output_mode.lower()
    if args.max_retries < 1:
        parser.error("--max-retries must be greater than 0")
    return args


def main() -> int:
    started = monotonic()
    args = parse_args()
    input_path = args.input
    if not input_path.exists():
        print(f"subtitle-workflow: input not found: {input_path}", file=sys.stderr)
        return 1
    if input_path.suffix.lower() != ".srt":
        print(f"subtitle-workflow: only SRT input is supported: {input_path}", file=sys.stderr)
        return 1

    try:
        output_format = resolve_output_format(args.output_mode, args.output_format)
    except ValueError as error:
        print(f"subtitle-workflow: {error}", file=sys.stderr)
        return 1

    output_dir = args.output_dir or input_path.parent
    output_dir.mkdir(parents=True, exist_ok=True)
    output_prefix = args.output_prefix or strip_source_suffix(input_path, parse_suffixes(args.source_suffixes))
    target_srt = output_dir / f"{output_prefix}.{args.target_suffix}.srt"
    output_ass = output_dir / f"{output_prefix}.{args.target_suffix}.ass" if output_format == "ass" else None
    output_paths = [target_srt, *( [output_ass] if output_ass is not None else [] )]

    try:
        ensure_can_write(output_paths, args.force)
    except FileExistsError as error:
        print(f"subtitle-workflow: {error}", file=sys.stderr)
        return 1

    summary_dir = args.summary.parent if args.summary else Path(tempfile.mkdtemp(prefix="subtitle-workflow."))
    summary_dir.mkdir(parents=True, exist_ok=True)
    translation_summary_path = summary_dir / f"{output_prefix}.{args.target_suffix}.translation-summary.json"

    try:
        translation_summary = run_translation(args, target_srt, translation_summary_path)
        ass_seconds = None
        if output_ass is not None:
            ass_seconds = run_ass_builder(args, target_srt, output_ass)

        workflow_summary = {
            "input": str(input_path),
            "source_language": args.source_language,
            "target_language": args.target_language,
            "target_suffix": args.target_suffix,
            "output_mode": args.output_mode,
            "output_format": output_format,
            "alignment_check": args.alignment_check,
            "target_srt": str(target_srt),
            "ass_output": str(output_ass) if output_ass else None,
            "translation_summary": translation_summary,
            "timings": {
                "ass_seconds": round(ass_seconds, 3) if ass_seconds is not None else None,
                "total_seconds": round(monotonic() - started, 3),
            },
        }
        if args.summary:
            args.summary.write_text(json.dumps(workflow_summary, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps(workflow_summary, ensure_ascii=False, indent=2), flush=True)
        return 0
    except subprocess.CalledProcessError as error:
        print(f"subtitle-workflow: command failed with exit {error.returncode}", file=sys.stderr)
        return error.returncode


if __name__ == "__main__":
    raise SystemExit(main())

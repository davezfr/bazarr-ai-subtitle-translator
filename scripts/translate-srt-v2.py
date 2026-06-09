#!/usr/bin/env python3
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from subtitle_text import strip_terminal_statement_punctuation_from_lines


TIME_RE = re.compile(r"(\d{2}:\d{2}:\d{2}[,.]\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2}[,.]\d{3})")
TIMESTAMP_ARTIFACT_RE = re.compile(r"\d{2}:\d{2}:\d{2}[,.]\d{3}\s*-->\s*\d{2}:\d{2}:\d{2}[,.]\d{3}")
INTERNAL_CHUNK_SIZE = 100
CONCURRENCY_POLICY_NAME = "auto_by_cue_count"
SOURCE_LEADING_SPEAKER_LABEL_RE = re.compile(r"^\s*(?:[-–—]\s*)?([^:\n]{1,40})\s*:\s*")
TARGET_LEADING_SPEAKER_LABEL_RE = re.compile(r"^\s*(?:[-–—]\s*)?.{1,32}[:：]\s*")
TARGET_LEADING_SPEAKER_LABEL_EXTRACT_RE = re.compile(r"^\s*(?:[-–—]\s*)?(.{1,32}?)\s*[:：]\s*")
GENERIC_SPEAKER_LABEL_BASES = {
    "anchor",
    "announcer",
    "boy",
    "clerk",
    "cop",
    "detective",
    "dispatcher",
    "doctor",
    "driver",
    "girl",
    "guard",
    "host",
    "interviewer",
    "man",
    "nurse",
    "officer",
    "operator",
    "police",
    "reporter",
    "soldier",
    "teacher",
    "voice",
    "waiter",
    "waitress",
    "woman",
}
HARD_ALIGNMENT_TYPES = {
    "wrong_cue",
    "cross_cue_shift",
    "missing_core_meaning",
    "merged_or_split",
}
HARD_ALIGNMENT_REASON_RE = re.compile(
    r"\b("
    r"wrong cue|"
    r"belongs to (?:cue|the previous|the next|a different)|"
    r"shift(?:ed|s)? (?:from|to|between|across|into|onto|out of|neighboring)|"
    r"swapp?ed? (?:between|with)|"
    r"cross[- ]cue|"
    r"previous cue|next cue|neighboring cue|"
    r"does not match (?:the )?source cue|"
    r"omits? (?:the )?(?:source cue'?s? )?(?:core|key|complete idea)|"
    r"missing (?:the )?(?:source cue'?s? )?(?:core|key|complete idea)|"
    r"drops? (?:the )?(?:core|key) meaning|"
    r"merged? (?:meaning )?(?:across|with)|"
    r"splits? (?:meaning )?(?:across|with)"
    r")\b",
    re.IGNORECASE,
)
NON_HARD_ALIGNMENT_REASON_RE = re.compile(
    r"\b("
    r"no issue|acceptable|still belongs|aligned in meaning|aligned with|"
    r"minor|slightly|less literal|phrasing|style|punctuation|line[- ]break|"
    r"word choice|terminology|more natural|less precise"
    r")\b",
    re.IGNORECASE,
)


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


def auto_concurrency_for_cue_count(cue_count: int) -> int:
    if cue_count <= 250:
        return 2
    if cue_count <= 500:
        return 3
    if cue_count <= 800:
        return 4
    return 6


def normalize_translation(value: str) -> str:
    text = value.replace("\r\n", "\n").replace("\r", "\n").strip()
    text = re.sub(r"^```(?:json|srt)?\s*", "", text)
    text = re.sub(r"\s*```$", "", text)
    return "\n".join(line.strip() for line in text.split("\n") if line.strip())


def extract_source_leading_speaker_label(lines: list[str]) -> str | None:
    for line in lines:
        if line.strip():
            match = SOURCE_LEADING_SPEAKER_LABEL_RE.match(line)
            if match and looks_like_source_speaker_label(match.group(1)):
                return match.group(1).strip()
            return None
    return None


def looks_like_source_speaker_label(label: str) -> bool:
    normalized = re.sub(r"\s+", " ", label.strip())
    if not normalized or len(normalized) > 32:
        return False

    tokens = normalized.replace(".", " ").replace("-", " ").split()
    if not tokens or len(tokens) > 4:
        return False

    for token in tokens:
        cleaned = token.strip("'’")
        if not cleaned:
            continue
        if cleaned.isdigit():
            continue
        if not any(char.isalpha() for char in cleaned):
            continue
        if cleaned.isupper():
            continue
        if not cleaned[0].isupper():
            return False

    return True


def extract_target_leading_speaker_label(text: str) -> str | None:
    for line in text.split("\n"):
        if line.strip():
            if not TARGET_LEADING_SPEAKER_LABEL_RE.match(line):
                return None
            match = TARGET_LEADING_SPEAKER_LABEL_EXTRACT_RE.match(line)
            return match.group(1).strip() if match else None
    return None


def is_generic_source_speaker_label(label: str) -> bool:
    words = re.findall(r"[A-Za-z]+", label.lower())
    return bool(words and words[0] in GENERIC_SPEAKER_LABEL_BASES)


def normalized_label_copy_key(label: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", label.lower())


def validate_chunk_response(args: argparse.Namespace, chunk: Chunk, response: dict[str, Any]) -> tuple[list[dict[str, str]], float]:
    started = monotonic()
    translations = response.get("translations")
    if not isinstance(translations, list):
        translations = response.get("items")
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
        raw_translation = item.get("translation")
        if raw_translation is None:
            raw_translation = item.get("text", "")
        translation = normalize_translation(str(raw_translation))
        if not translation:
            raise ValueError(f"chunk {chunk.index}: empty translation for cue {cue.number}")
        if TIMESTAMP_ARTIFACT_RE.search(translation):
            raise ValueError(f"chunk {chunk.index}: translation for cue {cue.number} contains a timestamp")
        source_label = extract_source_leading_speaker_label(cue.text_lines)
        target_label = extract_target_leading_speaker_label(translation) if source_label else None
        if source_label and not target_label:
            raise ValueError(
                f"chunk {chunk.index}: translation for cue {cue.number} dropped the leading speaker label"
            )
        if (
            source_label
            and target_label
            and is_generic_source_speaker_label(source_label)
            and normalized_label_copy_key(source_label) == normalized_label_copy_key(target_label)
            and args.source_language.strip().lower() != args.target_language.strip().lower()
        ):
            raise ValueError(
                f"chunk {chunk.index}: translation for cue {cue.number} copied generic speaker label {source_label!r}"
            )
        validated.append({"number": cue.number, "translation": translation})

    return validated, monotonic() - started


def validate_alignment_response(chunk: Chunk, response: dict[str, Any]) -> float:
    started = monotonic()
    issues = response.get("issues")
    if not isinstance(issues, list):
        raise ValueError(f"chunk {chunk.index}: missing semantic alignment issues array")

    valid_numbers = {cue.number for cue in chunk.cues}
    validated_issues: list[str] = []
    for offset, item in enumerate(issues, start=1):
        if not isinstance(item, dict):
            raise ValueError(f"chunk {chunk.index}: semantic alignment issue {offset} is not an object")
        number = str(item.get("number", "")).strip()
        if number not in valid_numbers:
            raise ValueError(
                f"chunk {chunk.index}: semantic alignment issue {offset} references unknown cue {number!r}"
            )
        severity = str(item.get("severity", "fail")).strip().lower()
        if severity not in {"fail", "warn"}:
            raise ValueError(
                f"chunk {chunk.index}: semantic alignment issue {offset} has invalid severity {severity!r}"
            )
        issue_type = str(
            item.get("error_type", item.get("issue_type", item.get("type", "")))
        ).strip().lower()
        issue_value = str(item.get("issue", "")).strip().lower()
        if not issue_type and issue_value in HARD_ALIGNMENT_TYPES:
            issue_type = issue_value
        reason_value = item.get("reason")
        if reason_value is None:
            reason_value = item.get("details", item.get("detail"))
        if reason_value is None:
            reason_value = item.get("issue")
        if reason_value is None and issue_type:
            reason_value = issue_type
        reason = normalize_translation(str(reason_value or ""))
        if not reason:
            raise ValueError(f"chunk {chunk.index}: semantic alignment issue {offset} has empty reason")
        is_hard_issue = bool(HARD_ALIGNMENT_REASON_RE.search(reason))
        if issue_type in {"wrong_cue", "missing_core_meaning"}:
            is_hard_issue = True
        elif issue_type in {"cross_cue_shift", "merged_or_split"}:
            is_hard_issue = is_hard_issue and reason != issue_type
        is_non_hard_issue = severity == "warn" or bool(NON_HARD_ALIGNMENT_REASON_RE.search(reason))
        if not is_hard_issue or is_non_hard_issue:
            continue
        validated_issues.append(f"cue {number}: {reason}")

    if validated_issues:
        preview = "; ".join(validated_issues[:5])
        if len(validated_issues) > 5:
            preview = f"{preview}; and {len(validated_issues) - 5} more"
        raise ValueError(f"chunk {chunk.index}: semantic alignment issues: {preview}")

    return monotonic() - started


def format_srt(cues: list[Cue], translations: list[dict[str, str]]) -> str:
    if len(cues) != len(translations):
        raise ValueError(f"final compose count mismatch source={len(cues)} target={len(translations)}")

    blocks: list[str] = []
    for cue, item in zip(cues, translations):
        if cue.number != item["number"]:
            raise ValueError(f"final compose cue mismatch: {cue.number} != {item['number']}")
        text_lines = strip_terminal_statement_punctuation_from_lines(
            [line for line in item["translation"].split("\n") if line.strip()]
        )
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


def build_prompt(args: argparse.Namespace, chunk: Chunk, retry_note: str | None = None) -> str:
    format_prompt = read_optional(Path(args.format_prompt_file)) if args.format_prompt_file else ""
    style_prompt = read_optional(Path(args.prompt_file)) if args.prompt_file else ""
    retry_section = ""
    if retry_note:
        retry_section = f"""
Previous attempt failed validation:
{retry_note}

Fix that specific validation issue in this retry while still following the full pipeline contract.
"""
    payload = {
        "source_language": args.source_language,
        "target_language": args.target_language,
        "chunk": {
            "index": chunk.index,
            "first_cue": chunk.first_cue,
            "last_cue": chunk.last_cue,
            "cue_count": len(chunk.cues),
        },
        "items": [{"number": cue.number, "text": cue.text} for cue in chunk.cues],
    }
    return f"""Translate subtitle cue text from {args.source_language} to {args.target_language}.

Pipeline contract:
- Return JSON matching the provided schema.
- Return exactly one translation object for every input item.
- Preserve every number value exactly.
- Do not create, merge, split, remove, or reorder cue objects.
- This chunk contains {len(chunk.cues)} input items; return exactly {len(chunk.cues)} translation objects.
- Translate text only.
- Do not include SRT cue numbers, timestamps, markdown, explanations, or metadata in translations.
- Keep output concise enough for subtitle display.
{retry_section}

Format prompt:
{format_prompt}

Style prompt:
{style_prompt}

Input JSON:
{json.dumps(payload, ensure_ascii=False, indent=2)}
"""


def build_openai_system_prompt(args: argparse.Namespace, operation: str) -> str:
    if operation == "translate" and args.endpoint_prompt_file:
        endpoint_prompt = read_optional(Path(args.endpoint_prompt_file)).strip()
        if endpoint_prompt:
            return endpoint_prompt

    return """You are an API worker inside a deterministic subtitle pipeline.

Return exactly one JSON object matching the requested schema and nothing else.
Do not add prefaces, explanations, apologies, markdown fences, comments, or natural-language status text.
The first non-whitespace character must be `{` and the last non-whitespace character must be `}`.
"""


def build_alignment_prompt(args: argparse.Namespace, chunk: Chunk, translations: list[dict[str, str]]) -> str:
    payload = {
        "source_language": args.source_language,
        "target_language": args.target_language,
        "chunk": {
            "index": chunk.index,
            "first_cue": chunk.first_cue,
            "last_cue": chunk.last_cue,
        },
        "items": [
            {
                "number": cue.number,
                "source_text": cue.text,
                "candidate_translation": item["translation"],
            }
            for cue, item in zip(chunk.cues, translations)
        ],
    }
    return f"""Semantic alignment V2 hard-error verification for subtitle translation.

You are checking whether each candidate translation still belongs to the source cue with the same number.

Verification contract:
- Return JSON matching the provided schema.
- Do not rewrite, polish, or improve translations.
- This is not a translation quality review. Only report hard alignment errors.
- Report an issue only when one of these hard errors is clear:
  - wrong_cue: the candidate translation belongs to a different cue.
  - cross_cue_shift: the candidate translation is shifted from/to a neighboring cue or swapped with another cue.
  - missing_core_meaning: the candidate translation omits the source cue's core meaning, not just nuance.
  - merged_or_split: the candidate translation merges or splits meaning across cue boundaries.
- Do not report minor phrasing, punctuation, line-break, wording strength, terminology, localization, or style differences.
- Do not report acceptable paraphrases. If you are unsure, return an empty issues array.
- Do not put "acceptable", "no issue", or "minor" findings in the issues array.
- Example: source "Record temperatures in the New York area" translated as "纽约地区创下纪录高温" is not an alignment issue.
- Do not report preserved personal names as issues.
- Do not report translated generic speaker labels as issues.
- Report an issue if a source cue begins with a speaker label but the candidate translation turns that label into ordinary dialogue or omits it.
- If every candidate translation is aligned with its same-number source cue, return an empty issues array.

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


def write_alignment_schema(path: Path) -> None:
    schema = {
        "type": "object",
        "additionalProperties": False,
        "required": ["issues"],
        "properties": {
            "issues": {
                "type": "array",
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "required": ["number", "error_type", "reason"],
                    "properties": {
                        "number": {"type": "string"},
                        "error_type": {
                            "type": "string",
                            "enum": sorted(HARD_ALIGNMENT_TYPES),
                        },
                        "reason": {"type": "string"},
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
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        start_positions = [pos for pos in (raw.find("{"), raw.find("[")) if pos >= 0]
        if not start_positions:
            raise
        start = min(start_positions)
        parsed, _ = json.JSONDecoder().raw_decode(raw[start:])
        if not isinstance(parsed, dict):
            raise
        return parsed


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


def run_codex_prompt(
    args: argparse.Namespace,
    chunk: Chunk,
    attempt: int,
    work_dir: Path,
    schema_path: Path,
    prompt: str,
    operation: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    prompt_path = work_dir / f"chunk-{chunk.index:03d}-{operation}-attempt-{attempt}.prompt.txt"
    output_path = work_dir / f"chunk-{chunk.index:03d}-{operation}-attempt-{attempt}.json"
    log_path = work_dir / f"chunk-{chunk.index:03d}-{operation}-attempt-{attempt}.jsonl"
    prompt_path.write_text(prompt, encoding="utf-8")

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


def run_codex_chunk(args: argparse.Namespace, chunk: Chunk, attempt: int, work_dir: Path, schema_path: Path, retry_note: str | None) -> tuple[dict[str, Any], dict[str, Any]]:
    return run_codex_prompt(args, chunk, attempt, work_dir, schema_path, build_prompt(args, chunk, retry_note), "translate")


def expand_cli_command(template: str, *, prompt_path: Path, output_path: Path, schema_path: Path, log_path: Path, model: str) -> str:
    values = {
        "prompt_file": prompt_path,
        "output_file": output_path,
        "schema_file": schema_path,
        "log_file": log_path,
        "model": model,
    }
    command = template
    for key, value in values.items():
        replacement = shlex.quote(str(value))
        command = command.replace("{" + key + "}", replacement)
    return command


def run_cli_command_prompt(
    args: argparse.Namespace,
    chunk: Chunk,
    attempt: int,
    work_dir: Path,
    schema_path: Path,
    prompt: str,
    operation: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    if not args.cli_command:
        raise RuntimeError("missing --cli-command for cli-command backend")

    prompt_path = work_dir / f"chunk-{chunk.index:03d}-{operation}-attempt-{attempt}.prompt.txt"
    output_path = work_dir / f"chunk-{chunk.index:03d}-{operation}-attempt-{attempt}.json"
    log_path = work_dir / f"chunk-{chunk.index:03d}-{operation}-attempt-{attempt}.log"
    prompt_path.write_text(prompt, encoding="utf-8")
    command = expand_cli_command(
        args.cli_command,
        prompt_path=prompt_path,
        output_path=output_path,
        schema_path=schema_path,
        log_path=log_path,
        model=args.model,
    )

    call_started = monotonic()
    proc = subprocess.run(
        command,
        input=prompt,
        text=True,
        shell=True,
        capture_output=True,
    )
    call_seconds = monotonic() - call_started
    log_path.write_text(
        "\n".join(
            [
                f"$ {command}",
                "",
                "stdout:",
                proc.stdout,
                "",
                "stderr:",
                proc.stderr,
            ]
        ),
        encoding="utf-8",
    )

    if proc.returncode != 0:
        raise RuntimeError(f"cli command failed with exit {proc.returncode}: {proc.stderr[-2000:] or proc.stdout[-2000:]}")

    if not output_path.exists():
        output_path.write_text(proc.stdout, encoding="utf-8")

    response = load_json(output_path)
    return response, {
        "prompt_path": str(prompt_path),
        "output_path": str(output_path),
        "log_path": str(log_path),
        "worker_seconds": round(call_seconds, 3),
        "cli_command": args.cli_command,
    }


def run_cli_command_chunk(args: argparse.Namespace, chunk: Chunk, attempt: int, work_dir: Path, schema_path: Path, retry_note: str | None) -> tuple[dict[str, Any], dict[str, Any]]:
    return run_cli_command_prompt(args, chunk, attempt, work_dir, schema_path, build_prompt(args, chunk, retry_note), "translate")


def openai_endpoint(base_url: str) -> str:
    normalized = base_url.rstrip("/")
    if normalized.endswith("/chat/completions"):
        return normalized
    return f"{normalized}/chat/completions"


def extract_chat_content(payload: dict[str, Any]) -> str:
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices:
        raise ValueError("OpenAI-compatible response missing choices")
    message = choices[0].get("message")
    if not isinstance(message, dict):
        raise ValueError("OpenAI-compatible response missing choices[0].message")
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for part in content:
            if isinstance(part, dict) and isinstance(part.get("text"), str):
                parts.append(part["text"])
        if parts:
            return "\n".join(parts)
    raise ValueError("OpenAI-compatible response missing text content")


def run_openai_compatible_prompt(
    args: argparse.Namespace,
    chunk: Chunk,
    attempt: int,
    work_dir: Path,
    schema_path: Path,
    prompt: str,
    operation: str,
    schema_name: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    prompt_path = work_dir / f"chunk-{chunk.index:03d}-{operation}-attempt-{attempt}.prompt.txt"
    output_path = work_dir / f"chunk-{chunk.index:03d}-{operation}-attempt-{attempt}.json"
    log_path = work_dir / f"chunk-{chunk.index:03d}-{operation}-attempt-{attempt}.response.json"
    prompt_path.write_text(prompt, encoding="utf-8")

    body: dict[str, Any] = {
        "model": args.model,
        "messages": [
            {
                "role": "system",
                "content": build_openai_system_prompt(args, operation),
            },
            {
                "role": "user",
                "content": prompt,
            }
        ],
        "temperature": args.temperature,
    }
    if args.openai_response_format == "json_object":
        body["response_format"] = {"type": "json_object"}
    elif args.openai_response_format == "json_schema":
        body["response_format"] = {
            "type": "json_schema",
            "json_schema": {
                "name": schema_name,
                "schema": json.loads(schema_path.read_text(encoding="utf-8")),
                "strict": True,
            },
        }

    request = urllib.request.Request(
        openai_endpoint(args.openai_base_url),
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {args.openai_api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    call_started = monotonic()
    try:
        with urllib.request.urlopen(request, timeout=args.openai_timeout) as response:
            response_text = response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        error_text = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"OpenAI-compatible endpoint failed with HTTP {error.code}: {error_text[-2000:]}") from error
    call_seconds = monotonic() - call_started

    log_path.write_text(response_text, encoding="utf-8")
    content = extract_chat_content(json.loads(response_text))
    output_path.write_text(content, encoding="utf-8")
    response_payload = load_json(output_path)
    return response_payload, {
        "prompt_path": str(prompt_path),
        "output_path": str(output_path),
        "log_path": str(log_path),
        "worker_seconds": round(call_seconds, 3),
        "endpoint": openai_endpoint(args.openai_base_url),
        "response_format": args.openai_response_format,
    }


def run_openai_compatible_chunk(args: argparse.Namespace, chunk: Chunk, attempt: int, work_dir: Path, schema_path: Path, retry_note: str | None) -> tuple[dict[str, Any], dict[str, Any]]:
    return run_openai_compatible_prompt(
        args,
        chunk,
        attempt,
        work_dir,
        schema_path,
        build_prompt(args, chunk, retry_note),
        "translate",
        "subtitle_chunk_translation",
    )


def run_alignment_check(
    args: argparse.Namespace,
    chunk: Chunk,
    translations: list[dict[str, str]],
    attempt: int,
    work_dir: Path,
    schema_path: Path,
) -> dict[str, Any]:
    if args.alignment_check == "off":
        return {}

    prompt = build_alignment_prompt(args, chunk, translations)
    check_started = monotonic()
    if args.backend in {"fake", "fake-extra"}:
        worker_meta: dict[str, Any] = {"worker_seconds": 0.0}
        response = {"issues": []}
    elif args.backend == "codex-cli":
        response, worker_meta = run_codex_prompt(args, chunk, attempt, work_dir, schema_path, prompt, "alignment")
    elif args.backend == "cli-command":
        response, worker_meta = run_cli_command_prompt(args, chunk, attempt, work_dir, schema_path, prompt, "alignment")
    elif args.backend == "openai-compatible":
        response, worker_meta = run_openai_compatible_prompt(
            args,
            chunk,
            attempt,
            work_dir,
            schema_path,
            prompt,
            "alignment",
            "subtitle_chunk_alignment",
        )
    else:
        raise ValueError(f"unsupported backend for semantic alignment: {args.backend}")

    validation_seconds = validate_alignment_response(chunk, response)
    meta = {
        "alignment_check": args.alignment_check,
        "alignment_worker_seconds": worker_meta.pop("worker_seconds", 0.0),
        "alignment_validation_seconds": round(validation_seconds, 3),
        "alignment_total_seconds": round(monotonic() - check_started, 3),
    }
    for key, value in worker_meta.items():
        meta[f"alignment_{key}"] = value
    return meta


def run_chunk(args: argparse.Namespace, chunk: Chunk, work_dir: Path, translation_schema_path: Path, alignment_schema_path: Path) -> tuple[int, list[dict[str, str]], dict[str, Any]]:
    attempts: list[dict[str, Any]] = []
    retry_note: str | None = None

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
                response, worker_meta = run_codex_chunk(args, chunk, attempt, work_dir, translation_schema_path, retry_note)
            elif args.backend == "cli-command":
                response, worker_meta = run_cli_command_chunk(args, chunk, attempt, work_dir, translation_schema_path, retry_note)
            elif args.backend == "openai-compatible":
                response, worker_meta = run_openai_compatible_chunk(args, chunk, attempt, work_dir, translation_schema_path, retry_note)
            else:
                raise ValueError(f"unsupported backend: {args.backend}")

            translations, validation_seconds = validate_chunk_response(args, chunk, response)
            alignment_meta = run_alignment_check(args, chunk, translations, attempt, work_dir, alignment_schema_path)
            attempts.append(
                {
                    "attempt": attempt,
                    "status": "ok",
                    **worker_meta,
                    "validation_seconds": round(validation_seconds, 3),
                    **alignment_meta,
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
            retry_note = str(error)

    raise RuntimeError(f"chunk {chunk.index} failed unexpectedly")


def run_translation_stage(
    args: argparse.Namespace,
    chunks: list[Chunk],
    work_dir: Path,
    translation_schema_path: Path,
    alignment_schema_path: Path,
) -> tuple[list[dict[str, str]], list[dict[str, Any]], float]:
    started = monotonic()
    by_chunk: dict[int, list[dict[str, str]]] = {}
    summaries: dict[int, dict[str, Any]] = {}

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as executor:
        futures = {
            executor.submit(
                run_chunk,
                args,
                chunk,
                work_dir / f"chunk-{chunk.index:03d}",
                translation_schema_path,
                alignment_schema_path,
            ): chunk
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
    parser.add_argument("--backend", choices=["fake", "fake-extra", "codex-cli", "cli-command", "openai-compatible"], default=os.environ.get("SUBTRANS_BACKEND", "openai-compatible"))
    parser.add_argument("--model", default=os.environ.get("SUBTRANS_MODEL", "gpt-5.4-mini"))
    parser.add_argument("--source-language", default=os.environ.get("SUBTRANS_SOURCE_LANGUAGE", "English"))
    parser.add_argument("--target-language", default=os.environ.get("SUBTRANS_TARGET_LANGUAGE", "Simplified Chinese"))
    parser.add_argument("--max-retries", type=int, default=int(os.environ.get("SUBTRANS_MAX_RETRIES", "3")))
    parser.add_argument("--temperature", type=float, default=float(os.environ.get("SUBTRANS_TEMPERATURE", "0")))
    parser.add_argument(
        "--alignment-check",
        choices=["off", "model"],
        default=os.environ.get("SUBTRANS_ALIGNMENT_CHECK", "off"),
        help="Optional model-based semantic alignment gate for each translated chunk.",
    )
    parser.add_argument("--cli-command", default=os.environ.get("SUBTRANS_CLI_COMMAND"))
    parser.add_argument("--openai-base-url", default=os.environ.get("OPENAI_BASE_URL", os.environ.get("SUBTRANS_BASE_URL", "http://127.0.0.1:11434/v1")))
    parser.add_argument("--openai-api-key", default=os.environ.get("OPENAI_API_KEY", "ollama"))
    parser.add_argument("--openai-timeout", type=float, default=float(os.environ.get("SUBTRANS_OPENAI_TIMEOUT", "300")))
    parser.add_argument(
        "--openai-response-format",
        choices=["none", "json_object", "json_schema"],
        default=os.environ.get("SUBTRANS_OPENAI_RESPONSE_FORMAT", "json_schema"),
        help="Optional response_format sent to OpenAI-compatible endpoints.",
    )
    parser.add_argument(
        "--format-prompt-file",
        default=os.environ.get("SUBTRANS_FORMAT_PROMPT_FILE", str(project_dir / "prompts" / "format-contract-system.md")),
    )
    parser.add_argument(
        "--endpoint-prompt-file",
        default=os.environ.get("SUBTRANS_ENDPOINT_PROMPT_FILE", str(project_dir / "prompts" / "endpoint-format-contract-system.md")),
    )
    parser.add_argument(
        "--prompt-file",
        default=os.environ.get("SUBTRANS_PROMPT_FILE", str(project_dir / "prompts" / "xiaohu-style-system.md")),
    )
    parser.add_argument("--work-dir", help="Directory for chunk prompts, outputs, logs, and schemas.")
    parser.add_argument("--keep-work-dir", action="store_true")
    args = parser.parse_args()
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
    args.chunk_size = INTERNAL_CHUNK_SIZE
    args.concurrency = auto_concurrency_for_cue_count(len(source_cues))
    chunks = chunk_cues(source_cues, args.chunk_size)
    timings["chunk_plan_seconds"] = round(monotonic() - plan_started, 3)

    if args.work_dir:
        work_dir = Path(args.work_dir)
        work_dir.mkdir(parents=True, exist_ok=True)
        cleanup_work_dir = False
    else:
        work_dir = Path(tempfile.mkdtemp(prefix="subtitle-v2-run."))
        cleanup_work_dir = not args.keep_work_dir

    translation_schema_path = work_dir / "translation.schema.json"
    alignment_schema_path = work_dir / "alignment.schema.json"
    write_schema(translation_schema_path)
    write_alignment_schema(alignment_schema_path)
    for chunk in chunks:
        (work_dir / f"chunk-{chunk.index:03d}").mkdir(parents=True, exist_ok=True)

    print(
        f"translate-srt-v2: cues={len(source_cues)} chunks={len(chunks)} "
        f"chunk_size={args.chunk_size} concurrency={args.concurrency} backend={args.backend} "
        f"concurrency_policy={CONCURRENCY_POLICY_NAME} alignment_check={args.alignment_check}",
        flush=True,
    )

    try:
        translations, chunk_summaries, translation_seconds = run_translation_stage(
            args,
            chunks,
            work_dir,
            translation_schema_path,
            alignment_schema_path,
        )
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
            "concurrency_policy": CONCURRENCY_POLICY_NAME,
            "alignment_check": args.alignment_check,
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

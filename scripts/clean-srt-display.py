#!/usr/bin/env python3
"""Apply display-layer subtitle text cleanup to an SRT file."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

from subtitle_text import strip_terminal_statement_punctuation_from_lines


def clean_srt_text(text: str) -> str:
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    blocks = [block for block in re.split(r"\n\s*\n", normalized.strip()) if block.strip()]
    cleaned_blocks: list[str] = []

    for block in blocks:
        lines = block.split("\n")
        if len(lines) >= 3 and "-->" in lines[1]:
            lines = [*lines[:2], *strip_terminal_statement_punctuation_from_lines(lines[2:])]
        cleaned_blocks.append("\n".join(lines))

    return "\n\n".join(cleaned_blocks) + "\n\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Clean display punctuation in SRT text lines.")
    parser.add_argument("input", help="Input SRT path.")
    parser.add_argument("output", help="Output SRT path.")
    args = parser.parse_args()

    input_path = Path(args.input)
    output_path = Path(args.output)
    output_path.write_text(clean_srt_text(input_path.read_text(encoding="utf-8-sig")), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

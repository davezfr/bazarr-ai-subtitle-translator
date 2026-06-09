#!/usr/bin/env python3
"""Build ASS subtitles from translated SRT, optionally with original text below."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from subtitle_text import strip_terminal_statement_punctuation, strip_terminal_statement_punctuation_from_lines


ASS_HEADER = """[Script Info]
ScriptType: v4.00+
WrapStyle: 2
ScaledBorderAndShadow: yes
PlayResX: {playres_x}
PlayResY: {playres_y}

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
{styles}

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""

SIZE_TABLES = {
    "cjk": {
        360: (19, 14),
        720: (38, 24),
        1080: (56, 36),
        2160: (112, 72),
    },
    "latin": {
        360: (16, 11),
        720: (32, 23),
        1080: (48, 34),
        2160: (96, 68),
    },
}

SOURCE_MARGIN_TABLE = {
    360: 18,
    720: 36,
    1080: 55,
    2160: 110,
}

PRIMARY_FONT_BY_SCRIPT = {
    "cjk": "PingFang SC",
    "latin": "Arial",
}

SECONDARY_FONT_BY_SCRIPT = {
    "cjk": "PingFang SC",
    "latin": "Arial",
}

PLAYRES_TABLE = {
    360: (640, 360),
    720: (1280, 720),
    1080: (1920, 1080),
    2160: (3840, 2160),
}


def parse_srt(path: Path) -> list[tuple[str, str, list[str]]]:
    text = path.read_text(encoding="utf-8-sig").replace("\r\n", "\n").replace("\r", "\n")
    blocks = re.split(r"\n\s*\n", text.strip())
    items: list[tuple[str, str, list[str]]] = []
    for block in blocks:
        lines = [line for line in block.split("\n") if line.strip()]
        if len(lines) < 3:
            continue
        match = re.search(
            r"(\d{2}:\d{2}:\d{2}[,.]\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2}[,.]\d{3})",
            lines[1],
        )
        if not match:
            continue
        items.append((match.group(1), match.group(2), lines[2:]))
    return items


def srt_time_to_ass(value: str) -> str:
    value = value.replace(".", ",")
    hms, millis = value.split(",")
    hours, minutes, seconds = hms.split(":")
    centiseconds = min(99, round(int(millis) / 10.0))
    return f"{int(hours)}:{minutes}:{seconds}.{centiseconds:02d}"


def ass_escape(text: str) -> str:
    text = text.replace("\\", "\\\\")
    text = text.replace("{", "\\{").replace("}", "\\}")
    return text


def join_lines(lines: list[str], *, clean_terminal: bool = False) -> str:
    text_lines = strip_terminal_statement_punctuation_from_lines(lines) if clean_terminal else lines
    return r"\N".join(ass_escape(line.strip()) for line in text_lines if line.strip())


def join_flat_lines(lines: list[str], *, clean_terminal: bool = False) -> str:
    text_lines = strip_terminal_statement_punctuation_from_lines(lines) if clean_terminal else lines
    stripped_lines = [line.strip() for line in text_lines if line.strip()]
    if not stripped_lines:
        return ""

    text = stripped_lines[0]
    for line in stripped_lines[1:]:
        separator = " " if needs_flat_separator(text, line) else ""
        text = f"{text}{separator}{line}"
    if clean_terminal:
        text = strip_terminal_statement_punctuation(text)
    return ass_escape(text)


def is_cjk_or_cjk_punctuation(char: str) -> bool:
    codepoint = ord(char)
    return (
        0x3400 <= codepoint <= 0x4DBF
        or 0x4E00 <= codepoint <= 0x9FFF
        or 0xF900 <= codepoint <= 0xFAFF
        or char in "，。！？、：；（）【】《》「」『』"
    )


def needs_flat_separator(previous_text: str, next_text: str) -> bool:
    if next_text.startswith(("-", "–", "—")):
        return True

    previous_char = previous_text[-1]
    next_char = next_text[0]
    if is_cjk_or_cjk_punctuation(previous_char) or is_cjk_or_cjk_punctuation(next_char):
        return False
    return True


def pick_sizes(
    height: int | None,
    target_override: int | None,
    source_override: int | None,
    primary_script: str,
) -> tuple[int, int]:
    if target_override is not None:
        target_size = target_override
        source_size = source_override if source_override is not None else max(8, round(target_size / 1.7))
        return target_size, source_size

    size_table = SIZE_TABLES[primary_script]
    nearest_height = min(size_table, key=lambda candidate: abs(candidate - (height or 720)))
    target_size, source_size = size_table[nearest_height]
    if source_override is not None:
        source_size = source_override
    return target_size, source_size


def pick_source_margin(height: int | None, margin_override: int | None) -> int:
    if margin_override is not None:
        return margin_override
    nearest_height = min(SOURCE_MARGIN_TABLE, key=lambda candidate: abs(candidate - (height or 720)))
    return SOURCE_MARGIN_TABLE[nearest_height]


def pick_playres(height: int | None) -> tuple[int, int]:
    nearest_height = min(PLAYRES_TABLE, key=lambda candidate: abs(candidate - (height or 720)))
    return PLAYRES_TABLE[nearest_height]


def build_styles(
    mode: str,
    target_font: str,
    source_font: str,
    target_size: int,
    source_size: int,
    source_marginv: int,
) -> str:
    if mode == "bilingual":
        line_gap = max(2, round(source_size * 0.05))
        target_marginv = source_marginv + source_size + line_gap
        return "\n".join(
            [
                f"Style: Primary,{target_font},{target_size},&H00FFFFFF,&H000000FF,&H00000000,&H90000000,-1,0,0,0,100,100,0,0,1,3.0,0.6,2,120,120,{target_marginv},1",
                f"Style: Secondary,{source_font},{source_size},&H00D6F4FF,&H000000FF,&H00000000,&H90000000,0,0,0,0,100,100,0,0,1,2.4,0.4,2,120,120,{source_marginv},1",
            ]
        )

    return f"Style: Default,{target_font},{target_size},&H00FFFFFF,&H000000FF,&H64000000,&H00000000,1,0,0,0,100,100,0,0,1,1.2,0,2,20,20,{source_marginv},1"


def build_ass(
    source_items: list[tuple[str, str, list[str]]],
    target_items: list[tuple[str, str, list[str]]],
    mode: str,
    target_font: str,
    source_font: str,
    target_size: int,
    source_size: int,
    source_marginv: int,
    playres_x: int,
    playres_y: int,
) -> str:
    if len(source_items) != len(target_items):
        raise ValueError(f"SRT entry count mismatch: source={len(source_items)} target={len(target_items)}")

    lines = [
        ASS_HEADER.format(
            styles=build_styles(mode, target_font, source_font, target_size, source_size, source_marginv),
            playres_x=playres_x,
            playres_y=playres_y,
        )
    ]
    for index, (source_item, target_item) in enumerate(zip(source_items, target_items), start=1):
        source_start, source_end, source_text = source_item
        target_start, target_end, target_text = target_item
        if source_start != target_start or source_end != target_end:
            raise ValueError(f"SRT timestamp mismatch at entry {index}: source={source_start}->{source_end} target={target_start}->{target_end}")

        if mode == "bilingual":
            lines.append(
                f"Dialogue: 1,{srt_time_to_ass(target_start)},{srt_time_to_ass(target_end)},Primary,,0,0,0,,{join_flat_lines(target_text, clean_terminal=True)}"
            )
            lines.append(
                f"Dialogue: 0,{srt_time_to_ass(target_start)},{srt_time_to_ass(target_end)},Secondary,,0,0,0,,{join_flat_lines(source_text, clean_terminal=True)}"
            )
        else:
            lines.append(
                f"Dialogue: 0,{srt_time_to_ass(target_start)},{srt_time_to_ass(target_end)},Default,,0,0,0,,{join_lines(target_text, clean_terminal=True)}"
            )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Build target-only or bilingual ASS subtitle sidecars.")
    parser.add_argument("--source", required=True, help="Source/original SRT path.")
    parser.add_argument("--target", required=True, help="Translated target-language SRT path.")
    parser.add_argument("--output", required=True, help="Output ASS path.")
    parser.add_argument("--mode", choices=["target", "bilingual"], default="target")
    parser.add_argument("--primary-size", "--target-size", dest="target_size", type=int, default=None)
    parser.add_argument("--secondary-size", "--source-size", dest="source_size", type=int, default=None)
    parser.add_argument("--height", type=int, default=None)
    parser.add_argument("--primary-font", "--font", dest="font", default=None, help="Primary-language ASS font name.")
    parser.add_argument("--secondary-font", "--source-font", dest="secondary_font", default=None, help="Secondary-language ASS font name.")
    parser.add_argument("--primary-script", choices=["cjk", "latin"], default="cjk")
    parser.add_argument("--secondary-script", choices=["cjk", "latin"], default="latin")
    parser.add_argument("--marginv", type=int, default=None, help="Bottom margin for target-only subtitles or bilingual secondary-language line.")
    args = parser.parse_args()

    source_path = Path(args.source)
    target_path = Path(args.target)
    source_items = parse_srt(source_path)
    target_items = parse_srt(target_path)
    if not source_items:
        print(f"build-ass-subtitle: no source SRT entries parsed: {source_path}", file=sys.stderr)
        return 1
    if not target_items:
        print(f"build-ass-subtitle: no target SRT entries parsed: {target_path}", file=sys.stderr)
        return 1

    target_size, source_size = pick_sizes(args.height, args.target_size, args.source_size, args.primary_script)
    source_marginv = pick_source_margin(args.height, args.marginv)
    playres_x, playres_y = pick_playres(args.height)
    primary_font = args.font or PRIMARY_FONT_BY_SCRIPT[args.primary_script]
    secondary_font = args.secondary_font or SECONDARY_FONT_BY_SCRIPT[args.secondary_script]
    try:
        ass = build_ass(
            source_items,
            target_items,
            args.mode,
            primary_font,
            secondary_font,
            target_size,
            source_size,
            source_marginv,
            playres_x,
            playres_y,
        )
    except ValueError as error:
        print(f"build-ass-subtitle: {error}", file=sys.stderr)
        return 1

    Path(args.output).write_text(ass, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Build ASS subtitles from translated SRT, optionally with original text below."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


ASS_HEADER = """[Script Info]
ScriptType: v4.00+
WrapStyle: 2
ScaledBorderAndShadow: yes
PlayResX: {playres_x}
PlayResY: {playres_y}

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,{font},{target_size},&H00FFFFFF,&H000000FF,&H64000000,&H00000000,1,0,0,0,100,100,0,0,1,1.2,0,2,20,20,{marginv},1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""

SIZE_TABLE = {
    360: (22, 13),
    720: (22, 13),
    1080: (20, 12),
    2160: (20, 12),
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


def join_lines(lines: list[str]) -> str:
    return r"\N".join(ass_escape(line.strip()) for line in lines if line.strip())


def pick_sizes(height: int | None, target_override: int | None, source_override: int | None) -> tuple[int, int]:
    if target_override is not None:
        target_size = target_override
        source_size = source_override if source_override is not None else max(8, round(target_size / 1.7))
        return target_size, source_size

    nearest_height = min(SIZE_TABLE, key=lambda candidate: abs(candidate - (height or 720)))
    target_size, source_size = SIZE_TABLE[nearest_height]
    if source_override is not None:
        source_size = source_override
    return target_size, source_size


def pick_playres(height: int | None) -> tuple[int, int]:
    nearest_height = min(PLAYRES_TABLE, key=lambda candidate: abs(candidate - (height or 720)))
    return PLAYRES_TABLE[nearest_height]


def build_ass(
    source_items: list[tuple[str, str, list[str]]],
    target_items: list[tuple[str, str, list[str]]],
    mode: str,
    font: str,
    target_size: int,
    source_size: int,
    marginv: int,
    playres_x: int,
    playres_y: int,
) -> str:
    if len(source_items) != len(target_items):
        raise ValueError(f"SRT entry count mismatch: source={len(source_items)} target={len(target_items)}")

    lines = [
        ASS_HEADER.format(
            font=font,
            target_size=target_size,
            marginv=marginv,
            playres_x=playres_x,
            playres_y=playres_y,
        )
    ]
    for index, (source_item, target_item) in enumerate(zip(source_items, target_items), start=1):
        source_start, source_end, source_text = source_item
        target_start, target_end, target_text = target_item
        if source_start != target_start or source_end != target_end:
            raise ValueError(f"SRT timestamp mismatch at entry {index}: source={source_start}->{source_end} target={target_start}->{target_end}")

        text = join_lines(target_text)
        if mode == "bilingual":
            text = f"{text}\\N{{\\fs{source_size}}}{join_lines(source_text)}"

        lines.append(
            f"Dialogue: 0,{srt_time_to_ass(target_start)},{srt_time_to_ass(target_end)},Default,,0,0,0,,{text}"
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Build target-only or bilingual ASS subtitle sidecars.")
    parser.add_argument("--source", required=True, help="Source/original SRT path.")
    parser.add_argument("--target", required=True, help="Translated target-language SRT path.")
    parser.add_argument("--output", required=True, help="Output ASS path.")
    parser.add_argument("--mode", choices=["target", "bilingual"], default="target")
    parser.add_argument("--target-size", type=int, default=None)
    parser.add_argument("--source-size", type=int, default=None)
    parser.add_argument("--height", type=int, default=None)
    parser.add_argument("--font", default="PingFang SC")
    parser.add_argument("--marginv", type=int, default=16)
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

    target_size, source_size = pick_sizes(args.height, args.target_size, args.source_size)
    playres_x, playres_y = pick_playres(args.height)
    try:
        ass = build_ass(
            source_items,
            target_items,
            args.mode,
            args.font,
            target_size,
            source_size,
            args.marginv,
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

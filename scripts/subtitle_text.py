from __future__ import annotations

import re


TERMINAL_STATEMENT_PUNCTUATION = {".", "。", ",", "，"}
LINE_END_STATEMENT_STOPS = {".", "。"}
PROTECTED_TERMINAL_ABBREVIATIONS = {
    "Mr.",
    "Mrs.",
    "Ms.",
    "Dr.",
    "Prof.",
    "Sr.",
    "Jr.",
    "St.",
    "Mt.",
    "Capt.",
    "Lt.",
    "Sgt.",
    "Col.",
    "Gen.",
    "Sen.",
    "Rep.",
    "Gov.",
}
DOTTED_INITIALISM_RE = re.compile(r"^(?:[A-Z]\.){2,}$")


def strip_terminal_statement_punctuation(text: str) -> str:
    """Remove display-heavy statement punctuation at the end of subtitle text."""
    stripped = text.rstrip()
    if not stripped:
        return text

    if stripped.endswith(("...", "…")):
        return stripped

    last_char = stripped[-1]
    if last_char not in TERMINAL_STATEMENT_PUNCTUATION:
        return stripped

    if last_char == "." and should_preserve_terminal_period(stripped):
        return stripped

    return stripped[:-1].rstrip()


def strip_line_end_statement_stop(text: str) -> str:
    stripped = text.rstrip()
    if not stripped:
        return text

    if stripped.endswith(("...", "…")):
        return stripped

    last_char = stripped[-1]
    if last_char not in LINE_END_STATEMENT_STOPS:
        return stripped

    if last_char == "." and should_preserve_terminal_period(stripped):
        return stripped

    return stripped[:-1].rstrip()


def strip_terminal_statement_punctuation_from_lines(lines: list[str]) -> list[str]:
    """Clean statement stops per subtitle line, then terminal commas/full stops."""
    cleaned = [strip_line_end_statement_stop(line) for line in lines]
    for index in range(len(cleaned) - 1, -1, -1):
        if cleaned[index].strip():
            cleaned[index] = strip_terminal_statement_punctuation(cleaned[index])
            break
    return cleaned


def should_preserve_terminal_period(text: str) -> bool:
    token = text.split()[-1].strip("\"'“”‘’()[]{}")
    return token in PROTECTED_TERMINAL_ABBREVIATIONS or bool(DOTTED_INITIALISM_RE.fullmatch(token))

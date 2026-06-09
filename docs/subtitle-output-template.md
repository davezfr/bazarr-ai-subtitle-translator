# Subtitle Output Template

Date: 2026-06-09

This document is the standard display contract for generated subtitle sidecars.
It describes the final output layer only. Translation prompts and model worker
logic should not contain these presentation rules.

## Roles

Bilingual ASS output is built from two logical roles:

```text
Primary language   Main comprehension language, rendered on top.
Secondary language Reference or learning language, rendered below.
```

Examples:

```text
Chinese-English: Primary = Simplified Chinese, Secondary = English
French-English:  Primary = French, Secondary = English
```

The model produces only the target-language translation. In the common
English-source workflow, the translated target language becomes `Primary`, and
the original English source subtitle becomes `Secondary`.

## ASS Structure

Bilingual subtitles must be ASS, not SRT. Each cue renders as two same-time
dialogue events:

```ass
Style: Primary,...
Style: Secondary,...

Dialogue: 1,...,Primary,,0,0,0,,<primary text>
Dialogue: 0,...,Secondary,,0,0,0,,<secondary text>
```

Do not put both languages into one ASS dialogue line with inline font overrides.
Separate styles keep font size, color, border, shadow, and positioning
deterministic.

## Presets

### CJK Primary

Use for Chinese-English bilingual subtitles.

```text
Primary script:   cjk
Secondary script: latin
1080p primary:    56, PingFang SC, white
1080p secondary:  36, Arial, near-white pale yellow #FFF4D6
Secondary margin: 55
Line gap:         tight, derived from secondary size
```

### Latin Primary

Use for French-English bilingual subtitles.

```text
Primary script:   latin
Secondary script: latin
1080p primary:    48, Arial, white
1080p secondary:  34, Arial, near-white pale yellow #FFF4D6
Secondary margin: 55
Line gap:         tight, derived from secondary size
```

Latin primary text is smaller than CJK primary text because French and other
Latin-script translations are usually wider on screen.

## Line Handling

Existing SRT line breaks are display hints from single-language subtitles. For
bilingual ASS, flatten each language to one display line per cue whenever
possible:

```text
primary line
secondary line
```

Do not split or retime cues in this output layer. Cue splitting requires a
separate timing-aware workflow.

## Display Punctuation

Display punctuation cleanup is deterministic post-processing:

```text
cjk:
  remove ordinary terminal 。 and ，
  preserve ？ ！ … and internal punctuation

latin:
  remove ordinary terminal . and ,
  preserve ? ! ... …
  preserve protected abbreviations such as Mr. and U.S.
```

These are display rules, not translation rules. Keep them out of the prompt.

## Environment Variables

Preferred V3 names:

```bash
SUBTRANS_ASS_PRIMARY_SCRIPT=cjk      # cjk or latin
SUBTRANS_ASS_SECONDARY_SCRIPT=latin  # cjk or latin
SUBTRANS_ASS_PRIMARY_SIZE=56
SUBTRANS_ASS_SECONDARY_SIZE=36
SUBTRANS_ASS_PRIMARY_FONT="PingFang SC"
SUBTRANS_ASS_SECONDARY_FONT="Arial"
```

Legacy V2 names are still accepted for compatibility:

```bash
SUBTRANS_ASS_TARGET_SIZE
SUBTRANS_ASS_SOURCE_SIZE
SUBTRANS_ASS_FONT
SUBTRANS_ASS_SOURCE_FONT
```

## Plex Language Naming

Plex identifies external subtitle language primarily from the sidecar filename,
not from ASS dialogue text or the visual bilingual layout. This project uses
two-letter lowercase ISO 639-1 codes for generated sidecars.

For bilingual subtitles, the filename language code must follow the `Primary`
language:

```text
Chinese-English, Chinese primary -> .zh.ass
French-English, French primary   -> .fr.ass
English-French, English primary  -> .en.ass
```

Default examples:

```text
Movie Name (2024).mkv
Movie Name (2024).zh.ass
Movie Name (2024).fr.ass
Movie Name (2024).en.ass

Show Name - s01e03.mkv
Show Name - s01e03.zh.ass
Show Name - s01e03.fr.ass
Show Name - s01e03.en.ass
```

Do not use pair or generic bilingual suffixes for Plex-facing output:

```text
Movie Name (2024).zh-en.ass
Movie Name (2024).bilingual.ass
Movie Name (2024).cn.ass
Movie Name (2024).ch.ass
```

If a special subtitle tag is needed, place it after the language code:

```text
Movie Name (2024).en.forced.ass
Movie Name (2024).en.sdh.ass
Movie Name (2024).en.cc.ass
```

After adding or renaming sidecar subtitles, Plex may need a library scan or
metadata refresh before the new language label appears.

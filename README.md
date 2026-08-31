# tonart4

Music for [facade](https://github.com/jagen31/facade) (Art 4), in
[Rhombus](https://rhombus-lang.org) — a port of tonart3's common-practice +
electronic libraries. For now: notes, tones, tuning, volume, `note->tone`,
and a tone-only rsound realizer.

(The collection is named `tonart4`, not `tonart`, so it coexists with the
Racket `tonart3` on the same install.)

## Forms

| form | meaning |
|---|---|
| `note pitch accidental octave` | a note, e.g. `note c 0 4` |
| `tone freq` | a tone at a frequency |
| `tuning kind` | tuning (`equal` / 12-TET for now) |
| `volume n` | volume for the tones it surrounds |
| `tones f …` | rewriter: lays out one `tone` per beat |
| `note_to_tone` | rewriter: turns the notes in scope into tones via the tuning |
| `music_rsound` | realizer: overlays the tones into an [rsound](https://docs.racket-lang.org/rsound/) |
| `play` | re-exported from rsound, to hear a result |

`import: tonart4 open` also brings all of facade (the engine and standard
coordinates: `realize`, `at`, `interval`, `index`, `define_*`, …).

## Usage

```
#lang rhombus/and_meta
import: tonart4 open

def arp = realize music_rsound:
            tuning equal
            at [interval 0 1]: note c 0 4
            at [interval 1 2]: note e 0 4
            at [interval 2 3]: note g 0 4
            note_to_tone
play(arp)
```

## MusicXML → tonart

`tonart4/musicxml.rhm` ports tonart3's musicxml reader. `load_musicxml`
reads a `.musicxml` file (relative paths resolve against the source file)
into parsed note/measure forms; `musicxml_to_tonart` rewrites those into
tonart `note`s laid out on the interval timeline, ready to realize:

```
#lang rhombus/and_meta
import:
  tonart4 open
  lib("tonart4/musicxml.rhm") open

def snd = realize music_rsound:
            tuning equal
            load_musicxml "sample.musicxml" [melody]
            musicxml_to_tonart
            note_to_tone
play(snd)
```

Handles chords (`<chord/>` → simultaneous notes) and ties (merged
per-pitch, so tied chords work), and directions: a note's `<lyric>` text
and any preceding `<direction>` words are treated as **tonart source**.
Following tonart3, `musicxml_to_tonart` detaches them as `direction`
objects; then `interpret_directions` parses each one and splices in the
resulting art (`lyric "do"`, or a `set`), and `do_set` turns a
`set (name theme)` at an instant into a `name theme` region running to
the next `reset` (or the end):

```
realize music_rsound:
  tuning equal
  load_musicxml "scores/dance2.musicxml" [flute1, flute2, flute3, flute4]
  musicxml_to_tonart
  interpret_directions
  do_set
  note_to_tone
```

Direction/`set` text may be written as tonart4 shrubbery or as tonart3
parenthesized s-expressions (`(set (name theme))`) — the outer parens are
stripped. The XML file parsing lives in `private/mxml-read.rkt` (Racket,
using Racket's `xml`); the art forms and the rewriter chain are in
`musicxml.rhm`.

## Engraving (LilyPond)

`tonart4/lilypond.rhm` adds a LilyPond realizer. `music_lilypond` turns the
notes in scope into LilyPond source; `lilypond_png` / `lilypond_svg` run the
`lilypond` CLI to engrave it to an image:

```
import:
  tonart4 open
  lib("tonart4/lilypond.rhm") open

def src = realize music_lilypond:
            load_musicxml "sample.musicxml" [melody]
            musicxml_to_tonart
def png = lilypond_png(src, "/tmp", "sample")   // needs lilypond installed
```

One staff per `voice`, with a register-appropriate clef (bass below
middle C); notes + rests; pitches and bar-aware, tie-split durations
(splitting at barlines of the `time_sig` in scope, default 4/4).  MusicXML
`divisions` are normalized to quarter-note beats, so a loaded score
engraves (and plays) with correct note values.

## Layout

- `tonart4-lib/` — the library (collection `tonart4`)
  - `main.rhm` — public entry (re-exports facade + the music lib)
  - `private/lib.rhm` — the music definitions
  - `musicxml.rhm` — MusicXML → tonart (forms + rewriter chain)
  - `private/mxml-read.rkt` — the MusicXML file parser (Racket)
  - `tests/` — `demo.rhm`, `musicxml-demo.rhm`, `sample.musicxml`
- `tonart4/` — the metapackage

## Local build

Needs `facade` and `rsound` installed.

```
raco pkg install tonart4/ tonart4-lib/
racket tonart4-lib/tests/demo.rhm
```

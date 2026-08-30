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

## Layout

- `tonart4-lib/` — the library (collection `tonart4`)
  - `main.rhm` — public entry (re-exports facade + the music lib)
  - `private/lib.rhm` — the definitions
  - `tests/demo.rhm` — a worked example
- `tonart4/` — the metapackage

## Local build

Needs `facade` and `rsound` installed.

```
raco pkg install tonart4/ tonart4-lib/
racket tonart4-lib/tests/demo.rhm
```

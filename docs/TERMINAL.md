# Terminal

## Screen model — DES-TERM-001

The native terminal renders 8×8 glyphs into the PCW bitmap and uses roller RAM
for the 90-column display. It maintains a 31-row application viewport plus the
status line. PCW paging and display ports follow `REF-PCW-HARDWARE` and
`REF-PCW-IO`.

## Font — DES-FONT-001

The builder extracts characters 00h–7Fh from `REF-MSDOS-FONT`, applies six
documented arrow substitutions, and produces the exact 1,024-byte runtime font.
Cells 09h, 0Bh, and 7Ch use upstream glyph 1Ah (right arrow); 0Ah uses 19h
(down arrow); 0Ch and 0Dh use 1Bh (left arrow). Every eight-row glyph is selected
unchanged from the pinned source. The disk stores a lossless row dictionary
and 6-bit indices; a transient startup routine reconstructs the table before
the screen is cleared.

## Controls — DES-TERM-002

The terminal supports character output, CR, LF, BS, TAB, home, absolute and
relative cursor movement, clear operations, scrolling, status-line switching,
viewport selection, ink controls, and the maintained F7 display value described
by `REF-PCW-XBIOS` and `REF-PCW-IO`.

## Directory presentation — DES-DIR-001

The resident `DIR` command formats each row as:

```text
A: FILENAME EXT : FILENAME EXT : FILENAME EXT : FILENAME EXT : FILENAME EXT
```

The current drive appears at the row start. Names and extensions retain their
space-padded 8.3 fields, and a row contains at most five entries. The executed
terminal coverage is described in [Compatibility evidence](COMPATIBILITY.md).

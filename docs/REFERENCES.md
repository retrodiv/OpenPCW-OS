# Public references

Stable identifiers in source comments and traceability records resolve here.
The repository stores bibliographic metadata and links; each cited publisher
or author remains the authoritative host for the referenced document.

## Processor and hardware

### REF-Z80-UM0080

Zilog, *Z80 CPU User Manual*, UM0080, revision 11, August 2016.
<https://www.zilog.com/docs/z80/um0080.pdf>

Used for instruction semantics, interrupt modes, alternate register sets,
`RETI`, and register preservation reasoning.

### REF-PCW-HARDWARE

Richard Fairhurst, *Amstrad PCW Hardware Reference*.
<https://www.systemed.net/pcw/hardware.html>

Used for the PCW memory-paging ports F0h–F4h, roller RAM, display controls,
300 Hz interrupt counter, uPD765 connection controls, motor control, keyboard
queue, and installed-memory model.

### REF-PCW-IO

Jacob Nevins, *Notes on PCW I/O ports*.
<https://www.chiark.greenend.org.uk/~jacobn/cpm/pcwports.html>

Used for PCW read/write bank selection, interrupt acknowledgement, screen,
keyboard, and disk-controller port contracts.

### REF-PCW-SOFTWARE-IO

Amstrad, *Joyce software interface specification*, HTML transcription hosted
by Jacob Nevins. <https://www.chiark.greenend.org.uk/~jacobn/cpm/pcwio.html>

Used for the public PCW memory-block model and expansion-block discovery.

### REF-PCW-BOOT

Jacob Nevins, *PCW boot sequence*.
<https://www.chiark.greenend.org.uk/~jacobn/cpm/pcwboot.html>

Used for the bootstrap transfer, first-sector load address, entry address, and
boot-sector checksum contract.

### REF-PCW-XBIOS

John Elliott, *Amstrad Extended BIOS calls*.
<https://www.seasip.info/Cpm/xbios.html>

Used for public DD, CD, KM, TE, and extended-BIOS calling conventions.

### REF-PCW-XBIOS-ARCH

John Elliott, *Amstrad Extended BIOS Internals*.
<https://www.seasip.info/Cpm/xbiosint.html>

Used as architectural context for the public XBIOS module families and jump
table organisation.

## Operating-system application interface

### REF-CPM3-PG

Digital Research, *CP/M Plus (CP/M Version 3) Programmer's Guide*, April 1983.
<https://bitsavers.org/pdf/digitalResearch/cpm_plus/CPM_Plus_Programmers_Guide_Apr83.pdf>

Used for Page Zero, FCBs, sequential and random records, BDOS function
contracts, error mode, banked memory, the SCB, BIOS parameter blocks, disk
parameter headers, and public return values.

### REF-CPM3-DISK

John Elliott, *CP/M 3.1 disc formats*.
<https://www.seasip.info/Cpm/format31.html>

Used for DPB fields, directory extents, labels, timestamps, XFCB password
records, and the password checksum and reversed-XOR byte representation.

## Disk-image container

### REF-EXTDSK

Kevin Thacker and John Elliott, *Extended DSK image definition*.
<https://cpctech.cpcwiki.de/docs/extdsk.html>

Used for the 256-byte disk header, per-track headers, sector descriptors, and
extended track-size table emitted by `tools/build.py`.

## Licensed font source

### REF-MSDOS-FONT

Microsoft, `v4.0/src/DEV/DISPLAY/EGA/437-8X8.ASM`, MS-DOS repository commit
`2d04cacc5322951f187bb17e017c12920ac8ebe2`.
<https://github.com/microsoft/MS-DOS/blob/2d04cacc5322951f187bb17e017c12920ac8ebe2/v4.0/src/DEV/DISPLAY/EGA/437-8X8.ASM>

MIT licence and repository licence-scope references at the same revision:
<https://github.com/microsoft/MS-DOS/blob/2d04cacc5322951f187bb17e017c12920ac8ebe2/LICENSE>
<https://github.com/microsoft/MS-DOS/blob/2d04cacc5322951f187bb17e017c12920ac8ebe2/README.md>

The local source and licence copies, their hashes, and the runtime glyph
selection are recorded in `THIRD_PARTY.md`.

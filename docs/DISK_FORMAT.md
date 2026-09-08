# Disk format

## Physical PCW layout — DES-DISK-001

The release disk is single-sided, 40-track media with nine 512-byte sectors per
track. Eight system tracks contain the boot chain and protected native modules.
The data area uses 1 KiB allocation blocks and a 2 KiB directory. The first ten
boot bytes publish the geometry consumed by PCW disk software.

## Extended DSK container — DES-DISK-002

`tools/build.py` serialises the physical sectors using `REF-EXTDSK`:

- one 256-byte disk-information header;
- forty 256-byte track-information headers;
- nine sector descriptors and sector payloads per track;
- a deterministic creator field and track-size table.

The final file is 194,816 bytes: 256 plus forty 4,864-byte extended tracks.

## System-track composition — DES-DISK-003

Track 0 contains the boot sector, common kernel sectors, and the first native
sector. Tracks 1–6 complete the native base image. Track 7 contains the two
service overlays and protected helper data. The builder verifies each component
against its assigned sector capacity before composing the image.

## Data area — DES-DISK-004

The generated helper starts with an empty CP/M-compatible directory. After boot,
the user can exchange A: for a program disk. The disk parser derives geometry
from the medium and performs directory and allocation operations using its DPB.
Applications may select a validated independent specification through `DD L
XDPB`; that geometry remains active across a CP/M disk-system reset and is
released at the next explicit media lifecycle boundary.

# BIOS and BDOS interfaces

OpenPCW-OS implements the application-visible contracts described below.
Interface semantics and FCB layouts use `REF-CPM3-PG`;
PCW-specific extensions use `REF-PCW-XBIOS`.

## Page Zero and warm boot — DES-BDOS-001

The boot path publishes warm boot at 0000h and BDOS at 0005h, command FCBs at
005Ch/006Ch, DMA/command tail at 0080h, and CP/M Plus source-drive and password
fields. Warm boot reconstructs this page and resumes the resident shell.

## Console and character services — DES-BDOS-002

Functions 1–11 provide console, reader, punch, list, direct console, string,
line input, status, and version behaviour. Console Mode controls flow keys,
echo, and raw input. The terminal and keyboard sections have dedicated designs
`DES-TERM-001` and `DES-KEY-001`.

## FCB filesystem — DES-BDOS-003

The A: and M: backends share public FCB behaviour for Open, Close, Search,
Delete, Read, Write, Make, Rename, random records, file size, attributes,
timestamps, directory labels, and password metadata. A: uses the mounted PCW
disk geometry; M: uses a project-authored volatile representation and publishes
standard directory records through search calls.

Function 59 loads an already opened absolute A: or M: overlay at the address in
FCB random-record bytes R0/R1. Physical A: walks all matching extents in logical
order and ignores public attribute bits for filename identity. The GENCOM
loader-boundary validation retains such an activated FCB across interrupts
before checking the loaded physical payload.

## Banked services — DES-BDOS-004

MOVE, XMOVE, DMA-bank selection, SCB access, BIOS parameter blocks, and direct
BIOS calls preserve the common/transient boundary and the PCW read/write paging
model. The build pins shared entry addresses used by separately assembled pages.

## Extended BIOS — DES-XBIOS-001

The public jump table covers the DD disk family, TE terminal family, KM keyboard
family, CD device family, and low-level sector operations used by supported PCW
programs. Each routine follows the register contract catalogued by
`REF-PCW-XBIOS`; physical operations are implemented through the native uPD765
engine.

`DD L XDPB` validates the independent ten-byte disk specification and selects
the resulting 27-byte XDPB as the active physical-disk geometry. A subsequent
BDOS Function 13 rebuilds directory and allocation state while retaining that
selection. Explicit shell media replacement and `DD INIT` start a fresh
geometry-selection lifecycle. `VAL-XBIOS-ACTIVE-SPEC` proves the distinction
with two catalogs at different reserved-track offsets.

`DD READ ID` returns the complete uPD765 result packet and preserves rotational
enumeration across consecutive calls on one cylinder. The native helper issues
the documented SEEK command on every request. A zero-distance SEEK retains the
controller's current rotational observation, while head movement or
recalibration begins a new one.

Component contracts and validation IDs are maintained in
[Symbol traceability](TRACEABILITY.yml). The executable coverage of the tests
included in this project is described in [Compatibility evidence](COMPATIBILITY.md).

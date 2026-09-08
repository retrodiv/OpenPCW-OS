# Public ABI

This document identifies fixed interfaces shared across separately assembled
OpenPCW components and emulator integrations. `tools/build.py` verifies every
listed address from Pasmo symbol output.

## Resident kernel

| Symbol | Address | Contract |
|---|---:|---|
| `PUBLIC_BDOS_ENTRY` | F606 | CP/M Plus-compatible public BDOS jump and TPA ceiling |
| `PRIVATE_BDOS_ENTRY` | F609 | resident dispatcher |
| `PLAIN_TRANSIENT_STACK` | F600 | initial plain-transient return area |
| `NATIVE_PHYSICAL_ERROR_ABORT` | F735 | native physical-error continuation |
| `SCREEN_INTERRUPT_ENTRY` | FDBB | protected Screen/BIOS-bank IM 1 veneer |
| `INTERRUPT_QUERY` | FDCC | replaceable ticker query jump |
| `INTERRUPT_DEFAULT_POINTER` | FEA7 | pointer to default tick routine |
| `INTERRUPT_RESTORE_PAGE` | FE31 | paging restoration byte |
| `LOW_BIOS_CONSOLE_STATUS` | F209 | Screen/BIOS-bank CONST veneer |
| `LOW_BIOS_CONSOLE_INPUT` | F216 | Screen/BIOS-bank CONIN veneer |

The ordinary TPA Page Zero points its 00EFh/00F2h jumpblock entries at the
standard BIOS table. Physical block 0 specialises those same two entries to
the low-bank veneers above. Each veneer preserves the native caller's general
register context and reselects physical screen blocks 0/1/2 before returning.
The interrupt dispatcher publishes its replaceable query at FDCCh and defers
the selected foreground-page restore until a replacement FDCBh dispatcher has
finished any low-page RST trampoline of its own.

## Native private bridge

The native and resident assemblies share pinned symbols for keyboard queue
state, screen-transfer services, status switching, paging state, SCB storage,
disk parameters, login/read-only vectors, and clock state. Their authoritative
names and values are `NATIVE_PRIVATE_ABI` and `NATIVE_COMMON_ABI` in
`tools/build.py`.

## EMS container — DES-EMS-001

`OPENPCW.EMS` begins with the project-authored `OPCWEMS1` header:

| Field | Encoding |
|---|---|
| magic | eight ASCII bytes |
| load address | little-endian 16-bit, F200h |
| entry address | little-endian 16-bit, F200h |
| payload length | little-endian 16-bit |
| format version | little-endian 16-bit, 1 |
| payload CRC-32 | little-endian 32-bit |

The remaining bytes are the exact resident-kernel payload.

## Plain COM entry — DES-ENTRY-001

The shell enters a plain `.COM` at 0100h with SP=F600h and a zero return word
at F600h, so a top-level RET transfers to warm boot. AF, BC, DE, HL, IX, IY and
the alternate AF/BC/DE/HL register set start at zero. IM 1 is selected and
maskable interrupts are enabled. These are OpenPCW-defined initial values.
GENCOM applications use the separate loader stack and resident-module contract.

BDOS Open and Close return their filesystem result in A/HL and clear BC/DE.
The entry and return sequences are checked by `tests/test_entry_state.py`;
the MAME integration additionally executes the entry-state guest fixture.

## Emulator integration metadata

`OpenPCW-OS-integration.json` is generated from the same Pasmo symbol file
as the resident kernel. Schema 1 publishes `resident_shell_entry` as
`shell_ready_pc` and binds the value to the release DSK with `disk_sha256`. An
emulator which temporarily boots this DSK may use that program-counter value
to wait until the native shell has printed its prompt before changing media or
injecting input.

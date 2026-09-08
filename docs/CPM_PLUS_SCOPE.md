# CP/M Plus compatibility scope

OpenPCW-OS is a PCW operating environment for launching CP/M-compatible
applications. It implements the application contracts described below and
provides a small resident command shell. Interface numbers and terminology follow
`REF-CPM3-PG`; the executable evidence is indexed in `TRACEABILITY.yml` and
`COMPATIBILITY.md`.

## Implemented application surface

| Area | Current implementation |
|---|---|
| Process lifecycle | cold boot, WBOOT, Page Zero reconstruction, plain `.COM` loading, parent-to-child chaining, GENCOM relocation, attached RSX chaining and pruning |
| Character I/O | BDOS 1–11, console modes, line editing, flow-control keys, configurable string delimiter, console status, terminal and keyboard XBIOS families |
| Physical A: | media login and replacement, geometry discovery, directory search, sequential/random/multirecord reads and writes, create/close/delete/rename, attributes, timestamps, labels, passwords, allocation and free-space reporting |
| Volatile M: | standard public FCB/DPH/DPB view over a project-authored RAM filesystem, including sparse records, mutations, overlays, passwords and capacity derived from installed memory |
| Banked memory | DMA-bank selection, MOVE, XMOVE, SELMEM, caller-page access, common-memory preservation and the PCW screen callback environment |
| System state | current/user drive, login and read-only vectors, SCB byte/word access, date/time ticker, error modes, serial field and output delimiter |
| BIOS | 30-entry public jump table with WBOOT, console, disk, sector translation, MULTIO, FLUSH, MOVE, TIME, SELMEM, SETBNK, XMOVE and USERF implementations |
| Extended BIOS | the DD disk, TE terminal, KM keyboard and supported CD/device and low-level sector calls documented in `BIOS_AND_BDOS.md` |
| Resident shell | `A:`, `M:`, five-column `DIR`, comment-line handling and direct `.COM` command execution |

The BDOS dispatcher implements the ordinary 0–40 filesystem and process family,
multirecord and error modes (44–45), free-space reporting (46), program chaining
(47), SCB access (49), direct BIOS calls (50), overlay loading (59), the locally
applicable CP/M Plus 98–112 state/metadata family, and filename parsing (152).
Calls whose documented role is a device capability return the corresponding
no-device result when that device is absent.

## Current boundary relative to a complete CP/M Plus installation

| CP/M Plus facility | Current boundary |
|---|---|
| CCP command language | The resident shell provides drive selection, `DIR`, comments and program execution. A complete CCP command grammar and the standard transient utility suite are future scope. |
| Peripheral redirection | Console input/output is implemented. Printer, reader, punch and auxiliary devices publish stable no-device behaviour until a concrete PCW device backend is added. |
| CP/NET and MP/M services | Network redirection, queues, process management and record locking are outside the current single-user application model. Compatibility calls retain documented neutral or unsupported results. |
| Full RSX ecosystem | Loading, chaining, interception, WBOOT lifecycle and pruning are implemented. A general-purpose installer equivalent to every CP/M Plus system utility remains future scope. |
| Storage breadth | A: supports the validated PCW/CPCEMU geometries and M: is volatile RAM storage. Additional physical drives, hard disks and arbitrary device drivers are future extensions. |
| System generation | The release is generated for its fixed PCW memory and disk plan. A configurable `GENCPM`-style system-generation environment is not part of version 0.1.0. |
| Bundled applications | The release contains the operating environment and an empty directory. Editors, languages, office applications and CP/M transient commands remain separately supplied software. |
| Unspecified register state | Plain COM entry and Open/Close scratch results follow OpenPCW's explicit register contract in `PUBLIC_ABI.md`. Applications requiring other initial or scratch values are outside this contract. |

This boundary is functional, not architectural: all current services execute as
guest Z80 code through documented PCW hardware interfaces, so later facilities
can be added to the standalone system without emulator-specific replacements.

## Evidence rule

The tables describe the implemented interfaces and their intended boundaries.
Executed test coverage is listed separately in `COMPATIBILITY.md`. All guest
fixtures are assembled by `make check`; only the probes selected by the MAME
and JOYCE scripts are executed by `make check-external`. Assembling a fixture
does not establish that its runtime contract passes. Neither a published jump
vector nor a neutral stub establishes complete behaviour or compatibility
with every CP/M application. Physical PCW hardware remains untested.

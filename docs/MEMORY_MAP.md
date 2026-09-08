# Memory map

All addresses are hexadecimal Z80 logical addresses. Physical-page assignments
follow `REF-PCW-IO` and `REF-PCW-SOFTWARE-IO`.

| Region | Owner | Purpose | Build gate |
|---|---|---|---|
| 0000–00FF | Public Page Zero | warm boot, BDOS vector, FCBs, command tail | ABI byte checks |
| 0100–F1FF | Plain transient TPA | conventional `.COM` load and data | public BDOS memory ceiling and resident entry audit |
| F500–F605 | High-loader margin | plain and GENCOM transient stacks plus PCW common-memory staging | zero returns at F600/F5FE; public BDOS begins at F606 |
| B000–B18F | Boot stage 2 capacity | transient reserved-track loader | assembled size ≤ 400 bytes |
| C000–EFFF | Attached GENCOM module | resident-system extension while that program is active | every live OS continuation is outside the range |
| F200–F2FF | Cold-start source | initial kernel material retained independently above the module ceiling | lifecycle and symbol audit |
| F300–F31A | GENCOM loader prefix | conventional 27-byte resident-loader interface | exact address audit |
| F31B–F400 | Cold/lifecycle workspace | copied resident shell, interrupt stack, shell stack, and Page Zero source | stack and overlap assertions |
| F401–F5BD | High-loader margin | common-memory staging and reserved compatibility workspace | fixed-symbol and zero-fill audit |
| F5BE–F5DD | GENCOM loader FCB workspace | application-owned activated FCB immediately below the entry stack | loader-boundary validation |
| F5DE–F5FD | GENCOM entry stack | sixteen return words for an attached-module transient | stack and public-entry assertions |
| F606–FFFF | Persistent common kernel | BDOS/BIOS APIs, interrupt dispatcher, terminal bridges, and state | fixed-symbol and GENCOM-range audit |

## Common stack lifetimes

| Region | Runtime owner | Lifetime and invariant |
|---|---|---|
| F37E–F3BD | private interrupt stack | 64 bytes; reuses consumed cold-start source and remains disjoint from shell and loader workspaces |
| F3C9–F3E8 | resident shell stack | used only before launching a transient or after WBOOT has abandoned it |
| F5BE–F5DD | GENCOM loader FCB workspace | application-owned while a GENCOM transient runs |
| F5DE–F5FD | GENCOM entry stack | sixteen return words below the F606h loader anchor |

The builder checks the interrupt and shell stack lengths and requires the
interrupt top to remain at or below F3BEh. `VAL-GENCOM-LOADER-BOUNDARY` adds an
executable interrupt/Open/BDOS-59 observation at the independent F5BEh loader
boundary.

## Native physical-page regions

| Address or page | Purpose | Invariant |
|---|---|---|
| 0100–3FFF | page-one native executable services | `native_executable_end` ≤ 4000 |
| 3F00–3FFF | published allocation-vector and protected helpers | fixed public vector addresses |
| 4000–5BFF in private block 8 | live native terminal/filesystem helpers and compact status text | `native_runtime_end` ≤ 5C00 |
| `native_runtime_end` onward in private block 8 | packed font and boot-only unpacker | consumed before the shell starts |
| 5C00–B5FF in screen blocks 1–2 | public PCW screen environment | exact `SCR RUN` bitmap origin and 256×90-byte extent |
| 8000 overlay | Open/read-random services | five-sector capacity |
| 899E overlay | password and metadata services | combined track-7 capacity |
| physical block 3 | filesystem service overlays and sparse metadata | signature, capacity, and fixed entry checks |
| physical pages 9–15/31 | volatile M: filesystem | capacity derived from installed RAM |

The exact constants and build assertions live in `tools/build.py`. This table
provides the human-readable contract for `DES-MEM-001`.

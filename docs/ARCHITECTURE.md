# Architecture

OpenPCW-OS divides the machine into three authored layers. This separation
keeps the transient program area large while placing hardware-sensitive code
in protected physical pages.

## Boot chain — DES-BOOT-001

`src/boot.asm` is the 512-byte sector loaded at F000h by the PCW bootstrap.
It establishes the initial mapping and copies `src/boot_stage2.asm` to B000h.
The second stage reads the common kernel, native page-one module, service
overlays, and the native image containing the terminal font and status data
from the reserved system tracks. Basis: `REF-PCW-BOOT`, `REF-PCW-IO`.

## Common resident kernel — DES-KERNEL-001

`src/kernel.asm` assembles at F200h. It owns the public Page Zero templates,
resident shell, public and private BDOS entry points, warm boot, the complete
common interrupt dispatcher, terminal bridges, and protected stacks. Its live
post-GENCOM entry points begin at F300h; the earlier assembled bytes supply
cold-start material that a resident module may subsequently own.
It is packaged both in the boot disk and in the `OPCWEMS1` EMS container.
Basis: `REF-CPM3-PG`, `REF-Z80-UM0080`.

## Native hardware module — DES-NATIVE-001

`src/native_kernel.asm` assembles from 0100h and contains the standalone PCW
implementation: uPD765 transfers, keyboard queue, display renderer, XBIOS,
native BDOS helpers, A: filesystem, M: work drive, and service overlays. The
builder checks the executable boundary, live-code boundary, overlay capacities,
and fixed inter-module addresses. Basis: `REF-PCW-HARDWARE`, `REF-PCW-XBIOS`,
`REF-CPM3-PG`.

## Interrupt architecture — DES-IRQ-001

Page Zero publishes an IM 1 veneer for the ordinary TPA mapping and a protected
FDBBh veneer for the Screen/BIOS mapping. Both paths preserve the interrupted
foreground stack in common state, switch to the private interrupt stack, run
the replaceable ticker query, and restore the mapping selected by their entry
environment only after the complete replacement dispatcher returns. The
Screen/BIOS Page Zero also routes CONST and CONIN through bank-preserving
veneers, so keyboard polling leaves physical blocks 0/1/2 selected. The
protected entry remains above every attached GENCOM module.
Basis: `REF-Z80-UM0080`, `REF-PCW-IO`, `REF-PCW-SOFTWARE-IO`.

## Build-time composition — DES-BUILD-001

`tools/build.py` assembles each independently placed module, checks their symbol
files, constructs the EMS header and CRC, constructs the extended DSK container,
and publishes release hashes. The build script is the executable specification
for all fixed binary boundaries; the narrative map is in `MEMORY_MAP.md`.

## Emulator responsibility boundary

The generated DSK is the complete guest-side system: boot, filesystem,
BIOS/BDOS services, program loading, paging, interrupts, terminal, keyboard,
and drive M: all execute as Z80 code against the documented PCW hardware.

An emulator integration treats that DSK as boot media. Its integration role is
limited to embedding or inserting the generated image, waiting at the published
shell-ready program counter, exchanging it for the requested application disk,
and injecting the same command characters a user could type. The application
then runs entirely through the system's public guest interfaces. This boundary
keeps compatibility improvements portable across ZEsarPCW, MAME, JOYCE, and
physical PCW machines.

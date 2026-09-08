# Boot process

## 1. Bootstrap sector — DES-BOOT-001

The PCW bootstrap loads disk sector 1 at F000h and enters F010h. The first ten
bytes also describe the PCW disk geometry. `boot.asm` sets the physical page
mapping, places the second stage at B000h, and transfers control there.

## 2. Reserved-track loader — DES-BOOT-002

`boot_stage2.asm` polls the uPD765 main-status register at port 00h and
transfers command, data, and result bytes through port 01h. PCW control port
F8h controls the motor and interrupt routing and reports the interrupt status
used during seeks. The loader loads:

1. the common resident kernel at F200h in physical block 7;
2. native physical-page code into the protected page layout;
3. the filesystem and password overlays into their fixed service page;
4. the native font dictionary and status payload in their build-checked
   private-page positions.

The loader then creates the public mapping and enters the resident kernel.

## 3. Kernel initialisation — DES-BOOT-003

The resident kernel validates the native service signature, creates Page Zero,
initialises public state, installs the interrupt path, and starts the complete
native service implementation. The same guest path supplies operating-system
services on ordinary emulators and physical machines.

## 4. Shell and medium exchange — DES-SHELL-001

The shell displays the startup banner and `A>` prompt. Before each A: command it
refreshes disk geometry and directory state, allowing a physical medium swap.
Drive M: selects the volatile expansion-RAM filesystem. `DIR` and drive changes
are resident commands; other tokens are parsed as `.COM` program names.

Boot layout and warm-boot lifecycle validation: `VAL-BUILD-LAYOUT` and
`VAL-NATIVE-WBOOT` in `TRACEABILITY.yml`.

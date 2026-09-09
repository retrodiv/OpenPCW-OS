# OpenPCW-OS

OpenPCW-OS is a small MIT-licensed operating environment for launching
CP/M-compatible Amstrad PCW software. Its authored Z80 boot chain, resident
kernel, terminal, disk services, keyboard services, interrupt ticker, shell,
and application API run on the PCW hardware model implemented by emulators such
as MAME and JOYCE and are designed for the corresponding physical machines.

Version 0.2.0 provides:

- a 180 KiB bootable PCW disk image;
- a resident command shell with physical A: disk replacement;
- a volatile M: work drive sized from installed expansion RAM;
- CP/M-compatible Page Zero, BIOS, BDOS, FCB, banked-memory, and error contracts;
- the documented Amstrad PCW extended-BIOS application interface;
- a 90-column terminal with PCW display controls and an MIT-licensed font;
- a resident `DIR` with drive prefix, five columns, space-separated extensions,
  and ` : ` column separators;
- deterministic artifacts and machine-checked layout boundaries.

## Build

Requirements:

- Python 3.10 or newer;
- GNU Make;
- [Pasmo](https://pasmo.speccy.org/) available as `pasmo`.

Build and verify:

```sh
make dist
make check
```

`make check` verifies the recorded source and release files without rewriting
them. `make check-external` additionally requires the native MAME and JOYCE
integration probes to pass; see [Testing](docs/TESTING.md) for dependencies.

The release artifacts are written to `dist/`:

- `OpenPCW-OS.dsk` — complete bootable disk;
- `OPENPCW.EMS` — resident-kernel payload with the `OPCWEMS1` container;
- `OpenPCW-OS-font.bin` — exact 128-glyph runtime font;
- `OpenPCW-OS-integration.json` — generated shell-ready integration point;
- `LICENSES.txt` — complete project and Microsoft copyright and permission notices;
- `OpenPCW-OS.zip` — the four runtime artifacts together with `LICENSES.txt`;
- `SHA256SUMS` — hashes of the ZIP and its five unpacked files.

Use `OpenPCW-OS.zip` for binary releases. Keep the applicable notices with
files redistributed separately or embedded in another project.

`make clean` removes these generated artifacts. A subsequent `make dist`
reconstructs them entirely from the versioned source and third-party font.

## Use

Boot `OpenPCW-OS.dsk` as drive A:. At the `A>` prompt, replace the disk
with a PCW program disk and enter the program's `.COM` name. The shell logs the
new medium and executes the program at the conventional transient address.

Commands available after a disk exchange include drive selection (`A:` and
`M:`), `DIR`, and direct `.COM` execution. Pressing the configured quit key in
an individual program remains a property of that program.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Boot process](docs/BOOT_PROCESS.md)
- [Memory map](docs/MEMORY_MAP.md)
- [BIOS and BDOS interfaces](docs/BIOS_AND_BDOS.md)
- [CP/M Plus compatibility scope](docs/CPM_PLUS_SCOPE.md)
- [Disk format](docs/DISK_FORMAT.md)
- [Terminal](docs/TERMINAL.md)
- [Public ABI](docs/PUBLIC_ABI.md)
- [Implementation notes](docs/IMPLEMENTATION_NOTES.md)
- [Design provenance](docs/DESIGN_PROVENANCE.md)
- [References](docs/REFERENCES.md)
- [Third-party material](docs/THIRD_PARTY.md)
- [Compatibility evidence](docs/COMPATIBILITY.md)
- [Build and release](docs/BUILD_AND_RELEASE.md)
- [Testing](docs/TESTING.md)
- [Symbol traceability](docs/TRACEABILITY.yml)
- [Routine contract index](docs/ROUTINE_INDEX.md)

The source uses short identifiers such as `REF-PCW-IO`, `DES-MEM-001`, and
`VAL-BUILD-LAYOUT`. `docs/TRACEABILITY.yml` resolves those identifiers to design
records, public references, and validation commands. `make check` verifies that
every material assembly routine is covered by a traceability rule.

The 24 MIT-licensed guest-side compatibility programs under `tests/fixtures/`
exercise public
BDOS, BIOS, XBIOS, terminal, disk, filesystem, banked-memory, and warm-boot
contracts. `make check` assembles all of them; emulator integrations execute
the relevant binaries through the native guest implementation.

## Integration

OpenPCW-OS is the canonical source of the guest operating environment.
Emulator projects can pin a release and embed the generated DSK together with
the published shell-ready metadata. The guest performs its own terminal, disk,
filesystem, memory, and application services; an integration only needs to
boot the helper disk, wait for the native prompt, exchange the content disk,
and inject the selected command when automatic launch is desired. The EMS and
font remain available separately for tools that consume those formats directly;
integrations must carry the applicable notices from `dist/LICENSES.txt`.

## Licence

Original OpenPCW-OS work is available under the MIT License in `LICENSE`.
The display-font source in `third_party/microsoft-msdos/` is distributed under
Microsoft's MIT License preserved beside it. Exact origin and transformation
records are in [Third-party material](docs/THIRD_PARTY.md).

OpenPCW-OS is an independent project, unaffiliated with the makers or owners
of Amstrad PCW, CP/M, or MS-DOS. Those names identify hardware compatibility,
software interfaces, or material attribution; they do not imply endorsement.

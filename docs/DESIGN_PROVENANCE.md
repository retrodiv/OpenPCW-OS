# Design provenance

OpenPCW-OS is developed as an affirmative, auditable chain from public
interfaces and project design decisions to source symbols and validation.

## Provenance classes

### Public-interface implementation

Hardware ports, CPU semantics, boot entry, BIOS/BDOS calls, FCB layouts, and
extended-BIOS register contracts cite stable `REF-*` identifiers from
`REFERENCES.md`.

### Project-authored design

Memory placement, overlay composition, the `OPCWEMS1` container, shell
architecture, A: caching policy, M: private representation, font packing,
terminal implementation, error routing, and build assertions use stable
`DES-*` identifiers documented in this repository.

### Licensed third-party material

The font source and its exact MIT licence are preserved under
`third_party/microsoft-msdos/`. `THIRD_PARTY.md` records the upstream revision,
path, hashes, selected glyph range, substitutions, and lossless packaging.

## Source and licence records

retrodiv (<retrodiv@proton.me>) developed the boot chain, resident and native kernels,
build tools, guest probes, tests, and project documentation. This project work
is distributed under the MIT permission notice in `LICENSE`.

The BOOT, RESIDENT, NATIVE_TERMINAL, NATIVE_DISK, NATIVE_FILESYSTEM, and
NATIVE_GENERAL components cover the four assembly files under `src/`. Those
files carry MIT SPDX headers. Their design records and public-interface
references are listed per component in `TRACEABILITY.yml`. The font has the
separate source and licence record in `THIRD_PARTY.md` and its preserved
Microsoft MIT notice.

Each component links this record through `provenance_record` and explicitly
sets `provenance_status` to `documented`. Publication requires an established
origin and permission to distribute under the applicable licence. The checker
requires that declaration and a record in the source-release documentation
inventory. Contributors remain responsible for the accuracy of the records;
the automated checks validate their presence, links, and consistency.

## Supplemental documentation

The separate component `status` is explicitly `documented`, or
`pending documentation` for an optional addition such as a worked example or
a fuller design explanation. Such an addition requires a concrete
`documentation_note` and an already documented provenance record. Checks report
each supplemental note and its count. Missing or invalid states, missing
records, and empty pending notes fail validation. Completed documentation has
no pending note.

## Interface and design references

Reference documents describe interfaces and observable data formats. The
project design records describe the implementation in this source tree.

| Area | Interface or design basis | Project record |
|---|---|---|
| Boot and paging | Nevins's `REF-PCW-BOOT` and `REF-PCW-IO`; Fairhurst's `REF-PCW-HARDWARE` | `BOOT_PROCESS.md`, `MEMORY_MAP.md` |
| Resident application interface | Digital Research's `REF-CPM3-PG` and Elliott's `REF-PCW-XBIOS` | `BIOS_AND_BDOS.md`, `PUBLIC_ABI.md` |
| A: filesystem and password records | Elliott's `REF-CPM3-DISK`, including its checksum and reversed-XOR format | `DISK_FORMAT.md`, `a_xfcb_password_matches_overlay` in `src/native_kernel.asm` |
| Terminal, keyboard, and disk services | `REF-PCW-HARDWARE`, `REF-PCW-IO`, and `REF-PCW-XBIOS` | `TERMINAL.md`, `IMPLEMENTATION_NOTES.md` |
| Protected memory and sparse M: storage | Component source, layout assertions, and CP/M application contracts | `ARCHITECTURE.md`, `MEMORY_MAP.md`, `DES-FS-M-001` |
| Display font | Microsoft source and MIT licence pinned by revision, path, and hash | `THIRD_PARTY.md` |
| Extended DSK packaging | Thacker and Elliott's `REF-EXTDSK` | `tools/build.py`, `DISK_FORMAT.md` |

## Reproducible release evidence

`RELEASE_EVIDENCE.json` records the local artifact checks with the SHA-256 of
each input and of the checker itself. It records the 128 runtime glyph matches,
the six source-glyph substitutions, preservation of both complete MIT notices,
exact ZIP membership and member contents, EMS header and CRC, DSK geometry and
boot checksum, integration metadata, and release checksums.

`python3 tests/test_artifact_contracts.py` recomputes those observations and
requires an identical report. `make release-evidence` refreshes the report only
after the artifact checks pass. `SOURCE_MANIFEST.sha256` binds the report to the
complete publication inventory.

The additional commands below establish the source-to-release chain:

| Command | Evidence checked |
|---|---|
| `python3 tools/build.py --check` | All seven artifacts match the assembled project source and local font and licence inputs byte for byte |
| `python3 tools/source_manifest.py --check` | Every named publication file matches its recorded SHA-256 |
| `python3 tests/check_project.py` | Source licence headers, pinned third-party hashes, and design/reference links |
| `python3 tests/test_fixture_assembly.py` | All 24 project guest probes assemble, including the 256-byte MAME bootstrap |
| `python3 tests/test_reproducible.py` | Two fresh builds match each other and the distributed artifacts |

These checks verify local content identity, transformations, and notice
preservation. The source and licence records above identify authorship and
the distribution terms for each component.

## Trace chain

The chain has four links:

```text
REF-* or DES-*  ->  source symbol/rule  ->  VAL-*  ->  build/test evidence
```

`tools/check_traceability.py` parses material call and jump targets from every
authored assembly file, resolves each symbol through `TRACEABILITY.yml`, and
reports missing coverage. `docs/ROUTINE_INDEX.md` records the resulting
symbol-level contracts. Routine-local comments refine those contracts;
the linked design documents provide the extensive rationale.

The routine index is generated from component rules. Its coverage records
which design, interface references, and validation commands apply to a symbol.
Execution results come from running the named commands; bibliographic records
identify the source documents independently of those results.

# Compatibility evidence

Compatibility claims are tied to named validations rather than inferred from a
successful build.

The commands below define coverage. A validation result applies to the exact
artifact hashes used in that run.

## Static and deterministic validation

- `VAL-BUILD-LAYOUT`: assembler symbols, fixed addresses, stacks, overlays,
  disk geometry, boot checksum, EMS header, and CRC.
- `VAL-REPRODUCIBLE`: two independent temporary builds produce identical files.
- `VAL-COMMENT-INVARIANCE`: source-comment additions preserve every binary byte.
- `VAL-TRACEABILITY`: every material assembly routine resolves to design,
  reference, and validation records.
- `VAL-PROJECT`: repository layout, SPDX metadata, licences, source identity,
  and project language.
- `VAL-ENTRY-STATE`: execution of the assembled plain-COM entry sequence from
  arbitrary register states, plus Open/Close success and error return contracts.
- `VAL-PUBLICATION`: explicit-file boundaries, symlink rejection, and
  documentation-status diagnostics.

All 24 MIT-licensed guest-side assembly fixtures under `tests/fixtures/` are
assembled by `tests/test_fixture_assembly.py`. They define executable
observations for the application interfaces listed below.

## Native emulator validation

- `VAL-MAME-NATIVE`: MAME boots the generated disk through the Z80, PCW paging,
  and uPD765 model and executes the plain-COM entry-state fixture, WBOOT,
  a deep transient-stack file-read probe,
  a BDOS 59 sparse-M overlay whose record lookup nests a paging helper, and an
  active-XDPB catalog-selection probe. It also runs a GENCOM boundary probe
  which retains an activated physical-file FCB at F5BEh across hardware ticks
  and then loads its attribute-marked absolute overlay through BDOS 59. A
  second attached-RSX probe occupies E100h–EFFFh, chains BDOS, enters `SCR RUN`,
  survives hardware interrupts, and reads the expected screen word at B600h.
- `VAL-NATIVE-WBOOT`: the WBOOT fixture runs twice under MAME and JOYCE,
  checking the warm-boot lifecycle and reconstructed Page Zero.
- `VAL-TRANSIENT-STACK`: MAME executes the transient-stack fixture and checks
  its file-read result after the nested native service calls.
- `VAL-XBIOS-ACTIVE-SPEC`: an application supplies `DD L XDPB`, invokes BDOS
  Function 13, then opens and reads a file whose catalog is reachable only at
  the selected reserved-track offset.
- `VAL-GENCOM-LOADER-BOUNDARY`: a GENCOM application places its physical-file
  loader FCB at F5BEh, observes sixteen 300 Hz interrupts, and proves both the
  intact FCB identity and the resulting BDOS 59 payload at 3600h.
- `VAL-SCR-RUN-RSX`: a full-size attached module retains its BDOS entry while
  the public screen environment maps physical blocks 0, 1, 2, and 7 and the
  resident interrupt path remains reachable at FDBBh.
- `VAL-JOYCE-NATIVE`: JOYCE boots the generated disk and executes the WBOOT
  probe through the emulated keyboard and native display.

# Changelog

All notable project changes are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Deterministic binary release ZIP with complete MIT notices and checksums.
- Source manifests that preserve file identity across Windows and Linux
  checkouts, with verification that leaves published files unchanged.
- Compatibility validation with Python 3.10/3.14, MAME, and JOYCE.
- Zeroed general-purpose registers at plain COM entry and zero BC/DE scratch
  results for Open/Close.
- Screen/BIOS paging preservation across console input and interrupt callbacks.

## [0.1.0]

### Added

- Native PCW boot chain, resident shell, BDOS-compatible application services,
  XBIOS-compatible hardware services, terminal, keyboard, interrupt ticker,
  physical A: disk access, and volatile M: work drive.
- Deterministic `OPENPCW.EMS`, `OpenPCW-OS.dsk`, runtime font, emulator
  integration metadata, and checksum generation.
- Resident `DIR` with the five-column PCW CP/M presentation.
- Native MAME and JOYCE integration probes.

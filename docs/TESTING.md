# Testing

The validation commands below are the reproducible evidence for compatibility
claims. Validation creates working files under `dist/` or temporary directories;
`make release-evidence` explicitly refreshes the report described below. No
command depends on terminal history or on a previously generated object file.

## Standalone gate

Requirements are Python 3.10 or newer, GNU Make, and Pasmo on `PATH`.

```sh
make clean
make dist
make check
```

`make check` first verifies the recorded source manifest and then compares the
published artifacts with a fresh build in temporary storage. It does not repair
or rewrite the files under review. The gate succeeds only when the build
produces the expected boot checksum,
EMS header and CRC, fixed ABI addresses, memory boundaries, DSK geometry, font,
integration metadata, complete licences, the release archive, and hashes.
Every runtime glyph is checked against its documented source glyph. The gate
also assembles all 24 guest probes, checks repository metadata and symbol
traceability, compares two independent
builds byte for byte, and proves that changing assembly comments leaves all seven
release artifacts byte-identical.

`tests/test_artifact_contracts.py` also verifies `docs/RELEASE_EVIDENCE.json`.
The report binds its local observations to the exact input files and checker
by SHA-256, using stable formatting without timestamps or machine-specific
paths. A stale or missing report fails validation. After an intentional change,
run `make release-evidence` and then `make source-manifest`; report generation
runs the artifact checks and fails if a glyph, notice, archive member, checksum,
or public artifact field differs from its contract.

`tests/test_entry_state.py` executes the assembled entry and Open/Close return
sequences with a small interpreter for their straight-line Z80 instructions.
It checks arbitrary incoming registers, the warm-boot return word, and
success/error results. `tests/test_publication.py` verifies explicit selection,
symlink rejection, required provenance declarations and record links, explicit
documentation states, and supplemental-note reporting. The command fails when
a provenance declaration or record link is missing or invalid, including when
an optional documentation note exists. These checks cover the current
publication inventory. Git reference and history review is described in
[Build and release](BUILD_AND_RELEASE.md#release-checklist).

## External PCW implementations

The integrations use Linux: MAME requires Pasmo and its headless debugger;
JOYCE additionally requires Xvfb, xdotool, FFmpeg, and Python's Pillow package.
Install JOYCE with its normal UI resources. The test creates a temporary
configuration and assembles the project's own bootstrap, so it does not require
a pre-existing emulator configuration or a separate boot-ROM image.

MAME and JOYCE run the generated DSK as ordinary PCW media. Set executable paths
when the programs are not on `PATH` (the MAME script also checks `/usr/games/mame`):

```sh
MAME_BIN=/path/to/mame python3 tests/integration_mame.py
JOYCE_BIN=/path/to/xjoyce \
python3 tests/integration_joyce.py
```

`make check-external` runs both commands with `--required` and the current
environment. Missing dependencies fail this gate. MAME must
complete the plain-COM entry-state, WBOOT lifecycle, transient-stack, sparse-M,
active-XDPB, GENCOM loader-boundary, and attached-RSX/SCR-RUN probes.
JOYCE must boot the release
DSK, execute the WBOOT fixture through its emulated keyboard and native display,
resume the shell, and reconstruct Page Zero. A missing optional emulator is
reported as a skip only when its individual script is run without `--required`.
An explicitly configured executable that is invalid fails in either mode.

MAME injects input through its debugger into the guest keyboard queue; JOYCE
uses its emulated keyboard and visible display. These observations exercise
the emulator paths described above. Physical PCW hardware remains untested.

## Continuous integration

The GitHub Actions workflow checks Python 3.10 and 3.14, verifies the recorded
files before rebuilding, and repeats validation after a clean build. A separate
MAME job executes the native probes with `--required`. Successful jobs make the
binary release ZIP and checksums available as a workflow artifact. JOYCE is
checked locally with `make check-external` before a release.

## CIFS integrity gate

The publication integrity check reads only the explicit source and artifact
inventory and rejects non-empty files consisting entirely of NUL bytes:

```sh
python3 -c 'from pathlib import Path; import sys; sys.path.insert(0, "tools"); from release_files import publication_files; bad=[str(p) for p in publication_files(Path.cwd()) if (data:=p.read_bytes()) and data.count(0)==len(data)]; print("\n".join(bad)); sys.exit(bool(bad))'
```

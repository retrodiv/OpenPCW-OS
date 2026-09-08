# Build and release

## Deterministic inputs — DES-BUILD-001

The build reads only:

- the four authored assembly sources under `src/`;
- the pinned font and licence under `third_party/microsoft-msdos/`;
- the project `LICENSE`;
- constants and composition code in `tools/build.py` and `tools/release_files.py`.

Pasmo symbol output is used for validation and placement. Temporary binaries
are created in a private temporary directory and released when the process
finishes.

## Artifact construction

1. Select the runtime glyphs from the pinned source and pack their rows.
2. Assemble the resident kernel and generate its symbolic dispatch include.
3. Assemble the native page module and extract its base and overlays.
4. Validate native fixed addresses and memory ceilings.
5. Assemble the stage-two loader, then assemble and checksum the boot sector.
6. Validate the resident ABI, interrupt paths, and stack boundaries.
7. Construct the `OPCWEMS1` container and CRC-32.
8. Construct the physical 180 KiB sector stream and extended DSK container.
9. Publish the shell-ready address from assembler symbols in the integration
   metadata artifact.
10. Generate `LICENSES.txt` with both complete copyright and permission notices.
11. Package the four runtime artifacts and the notices in `OpenPCW-OS.zip`.
12. Write `SHA256SUMS` covering those five files and the ZIP.

The ZIP uses uncompressed members, fixed 1980-01-01 timestamps, stable member
order, and regular-file permissions. It is reproducible across output paths.

To verify a binary download, put `OpenPCW-OS.zip` and `SHA256SUMS` in the same
directory, extract the ZIP there, and run `sha256sum -c SHA256SUMS`. This checks
both the archive and all five unpacked files, including the notices.

## Commands

```sh
make dist   # generate dist artifacts
make check  # verify recorded files, compare with a fresh build, audit, and test
make clean  # remove generated dist artifacts
```

`make release-evidence` validates the current artifacts and writes the
deterministic `docs/RELEASE_EVIDENCE.json` report. `make check` verifies that
report against the current inputs; it never refreshes it automatically.

`python3 tools/build.py --output DIRECTORY` supports independent output trees
used by reproducibility tests and integrations.

`make check` verifies `SOURCE_MANIFEST.sha256` before running the builder in
comparison mode. It leaves the published artifacts unchanged, so a damaged or
stale release file cannot be silently replaced with a good build during review.
After `make clean`, run `make dist` before `make check`.

`.gitattributes` fixes text checkouts to LF on all platforms and preserves
binary files, so Windows line-ending conversion does not invalidate the hashes.

`tools/release_files.py` declares the source files and distribution artifacts
intended for publication. `make source-manifest` hashes that explicit inventory
into `SOURCE_MANIFEST.sha256`, without discovering unrelated local files.
Add each new source-release file to `SOURCE_NAMES` intentionally. Missing files
and symlinks are rejected. The inventory works without Git metadata and is
also used for documentation checks and temporary source copies.

Keep local review reports and development notes under `.local/`, which Git
ignores. The publication inventory rejects `.local/` and `docs/decisions/`
paths even if explicitly selected. Public documentation describes supported
behaviour, interfaces, build instructions, validation, and source licences.

The inventory selects current files for manifests and source copies. A Git
push publishes the selected references and their reachable history, including
historical file contents and commit and tag metadata. Neither this inventory
nor `.gitignore` removes already tracked content or historical versions from
Git. The standalone checks operate on the current publication files; they do
not inspect Git history.

Downstream consumers pin the SHA-256 of the manifest
and verify every listed file before building artifacts. The manifest therefore
provides one stable content identity for a local checkout or an extracted
release archive.

## Validation layers

- `make check` verifies layouts, public artifact structure, 24 MIT guest probe
  assemblies, deterministic rebuilding, comment invariance, source identity,
  complete distribution notices, local font-source identity, archive contents,
  publication-file selection, entry registers, English project metadata, and
  symbol traceability.
  Provenance declarations and their source-and-licence record links are required;
  optional documentation additions are reported separately.
- `make check-external` requires both upstream MAME and JOYCE to boot and
  exercise the release DSK; missing dependencies fail this release gate.
- downstream emulator integrations use the generated shell-ready metadata and
  exercise the system through native Z80 execution.

The complete commands, dependencies, outputs, and pass criteria for every
validation layer are recorded in [Testing](TESTING.md).

## Release checklist

1. Update `VERSION` and `CHANGELOG.md`.
2. Run `make release-evidence`, refresh the routine index when needed, and run
   `make source-manifest` after intentional source or artifact changes.
3. Run `make check` against the recorded publication files, then
   `make clean && make dist && make check` to verify a clean rebuild.
4. Run `make check-external` for the exact artifacts being released; retain
   the MAME and JOYCE results with the artifact hashes.
5. For Git publication, review the branches and tags selected for publication,
   including reachable historical files, commit and tag messages, and author
   and committer metadata.
6. Tag the source revision and attach `dist/OpenPCW-OS.zip` and
   `dist/SHA256SUMS`. The ZIP includes the four runtime files and `LICENSES.txt`.
   Supply the applicable notices with any additional loose binary downloads.
7. Update downstream integration pins to the source archive and its SHA-256;
   integrations retain the notices when embedding the disk or font.

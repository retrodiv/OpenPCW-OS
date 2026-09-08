# Implementation notes

## Separate assemblies — DES-LINK-001

Pasmo assembles the stage-two loader, boot sector, resident kernel, and native
module as independently placed units. Fixed bridge addresses form an explicit
ABI checked at build time. This keeps each physical-page layout visible and
makes accidental overlap a build failure.

## Protected and transient code — DES-LINK-002

Services required after application paging changes reside in protected pages.
Large filesystem operations use a track-7 service overlay mapped only for the
duration of the call. Font unpacking and status installation are transient and
their memory becomes terminal storage after initialisation.

The two track-7 service regions are assembled at contiguous addresses and the
builder rejects either a gap or an overlap. BDOS 59 publishes its active page
to the shared restore trampoline while nested sparse-record helpers execute,
then restores the ordinary native page before returning its result.

The resident interrupt frame uses a 64-byte common stack ending at F3BEh. Its
backing bytes are the already-consumed Page Zero source and cold-only banner
prefix, so the runtime frame remains protected without taking space from an
application. The shell owns a separate lifecycle stack. GENCOM transients use
the independent F5BEh loader-FCB boundary and F5DEh-F5FDh entry stack below the
F606h anchor; `VAL-GENCOM-LOADER-BOUNDARY` exercises that exact boundary through
interrupts, Open, and BDOS 59.

An attached GENCOM module may own C000h–EFFFh. The builder consequently rejects
every post-activation resident-shell, WBOOT-head, or Screen/BIOS interrupt entry
in that interval. `VAL-SCR-RUN-RSX` installs a full-size attached module, enters
the documented screen mapping, waits through hardware interrupts, and verifies
both its BDOS chain and visible-screen access.

The cold native initialiser specialises the physical block-0 Page Zero after
the shared template is installed. Its CONST and CONIN vectors use resident
veneers which return to the Screen/BIOS mapping; the separately reconstructed
TPA Page Zero retains the ordinary BIOS vectors. Interrupt restoration occurs
after the entire replaceable FDCBh dispatcher returns, allowing a native ticker
to install, invoke, and restore a temporary RST 38h target atomically.

## A: geometry — DES-FS-A-001

The A: backend reads the disk specification, derives DPB values, scans standard
directory entries, follows extents and allocation blocks, and commits directory
updates synchronously. A command-boundary login refresh supports physical disk
replacement at the resident prompt.

`DD L XDPB` selects a validated independent disk specification for the active
application. The selection survives BDOS Function 13 while directory and
allocation caches are rebuilt, matching software which first establishes a
format and then resets the disk system. The resident shell's command boundary
and `DD INIT` deliberately begin a new media lifecycle and return discovery to
the inserted medium. See `DES-XBIOS-001` and `VAL-XBIOS-ACTIVE-SPEC`.

Successive `DD READ ID` calls for the same physical cylinder retain the
controller's rotational position. The shared seek helper issues the ordinary
SEEK lifecycle for every request. A controller model which completes a
zero-distance SEEK without resetting its rotational observation then exposes
every non-standard ID field in on-disk order; head movement or recalibration
starts a fresh observation.

## M: representation — DES-FS-M-001

The M: backend owns a compact volatile file model over expansion pages. It
publishes standard FCB search records and a standard DPH/DPB while using a
project-authored private record map. Installed memory selects the available
physical page range and therefore the public capacity.

## Error model — DES-ERROR-001

Public calls return CP/M-compatible result bytes and extended result codes.
Physical disk operations publish controller status and route the selected error
mode through the resident error continuation. Validation probes cover ordinary,
extended, read-only, password, invalid-drive, and media errors.

## Comment invariance — DES-BUILD-002

Assembly comments are source-only metadata. `tests/test_comment_invariance.py`
builds a temporary source copy with appended comments and verifies byte-identical
release binaries against the ordinary build.

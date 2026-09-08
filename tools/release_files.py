# SPDX-License-Identifier: MIT
# Copyright (c) 2026 retrodiv <retrodiv@proton.me>
"""Explicit publication inventory, shared by manifests and source-copy checks."""

from pathlib import Path, PurePosixPath


ARTIFACT_NAMES = (
    "OPENPCW.EMS",
    "OpenPCW-OS.dsk",
    "OpenPCW-OS-font.bin",
    "OpenPCW-OS-integration.json",
    "LICENSES.txt",
    "OpenPCW-OS.zip",
    "SHA256SUMS",
)

# Add a file here only when it is intended to be part of a source release.
SOURCE_NAMES = (
    '.gitattributes',
    '.github/workflows/build.yml',
    '.gitignore',
    'CHANGELOG.md',
    'CONTRIBUTING.md',
    'LICENSE',
    'Makefile',
    'README.md',
    'VERSION',
    'docs/ARCHITECTURE.md',
    'docs/BIOS_AND_BDOS.md',
    'docs/BOOT_PROCESS.md',
    'docs/BUILD_AND_RELEASE.md',
    'docs/COMPATIBILITY.md',
    'docs/CPM_PLUS_SCOPE.md',
    'docs/DESIGN_PROVENANCE.md',
    'docs/DISK_FORMAT.md',
    'docs/IMPLEMENTATION_NOTES.md',
    'docs/MEMORY_MAP.md',
    'docs/PUBLIC_ABI.md',
    'docs/REFERENCES.md',
    'docs/RELEASE_EVIDENCE.json',
    'docs/ROUTINE_INDEX.md',
    'docs/TERMINAL.md',
    'docs/TESTING.md',
    'docs/THIRD_PARTY.md',
    'docs/TRACEABILITY.yml',
    'src/boot.asm',
    'src/boot_stage2.asm',
    'src/kernel.asm',
    'src/native_kernel.asm',
    'tests/check_project.py',
    'tests/fixtures/openpcw_cpm_plus_bios_disk_probe.asm',
    'tests/fixtures/openpcw_cpm_plus_console_probe.asm',
    'tests/fixtures/openpcw_cpm_plus_console_status_probe.asm',
    'tests/fixtures/openpcw_cpm_plus_direct_bios_probe.asm',
    'tests/fixtures/openpcw_cpm_plus_dma_boundary_probe.asm',
    'tests/fixtures/openpcw_cpm_plus_entry_state_probe.asm',
    'tests/fixtures/openpcw_cpm_plus_extent_probe.asm',
    'tests/fixtures/openpcw_cpm_plus_free_space_mutation_probe.asm',
    'tests/fixtures/openpcw_cpm_plus_gencom_loader_probe.asm',
    'tests/fixtures/openpcw_cpm_plus_m_password_probe.asm',
    'tests/fixtures/openpcw_cpm_plus_multisector_probe.asm',
    'tests/fixtures/openpcw_cpm_plus_overlay_probe.asm',
    'tests/fixtures/openpcw_cpm_plus_parse_probe.asm',
    'tests/fixtures/openpcw_cpm_plus_password_mutation_probe.asm',
    'tests/fixtures/openpcw_cpm_plus_password_probe.asm',
    'tests/fixtures/openpcw_cpm_plus_random_errors_probe.asm',
    'tests/fixtures/openpcw_cpm_plus_screen_rsx_module.asm',
    'tests/fixtures/openpcw_cpm_plus_screen_rsx_probe.asm',
    'tests/fixtures/openpcw_cpm_plus_search_probe.asm',
    'tests/fixtures/openpcw_cpm_plus_state_probe.asm',
    'tests/fixtures/openpcw_cpm_plus_transient_stack_probe.asm',
    'tests/fixtures/openpcw_cpm_plus_wboot_probe.asm',
    'tests/fixtures/openpcw_cpm_plus_xbios_active_spec_probe.asm',
    'tests/fixtures/openpcw_mame_bootstrap.asm',
    'tests/integration_joyce.py',
    'tests/integration_mame.py',
    'tests/test_artifact_contracts.py',
    'tests/test_comment_invariance.py',
    'tests/test_entry_state.py',
    'tests/test_fixture_assembly.py',
    'tests/test_publication.py',
    'tests/test_reproducible.py',
    'third_party/microsoft-msdos/437-8X8.ASM',
    'third_party/microsoft-msdos/LICENSE',
    'tools/build.py',
    'tools/check_traceability.py',
    'tools/release_files.py',
    'tools/source_manifest.py',
)


def publication_files(root: Path, names: tuple[str, ...] | None = None) -> list[Path]:
    """Select named regular files without walking unrelated directories.

    Reject symlinks at every path component before examining their targets.
    This inventory also works in source archives without Git metadata.
    """
    if names is None:
        names = SOURCE_NAMES + tuple("dist/" + name for name in ARTIFACT_NAMES)
    if len(names) != len(set(names)):
        raise ValueError("duplicate publication path")
    selected = []
    for name in sorted(names):
        relative = PurePosixPath(name)
        if (not name or relative.is_absolute() or ".." in relative.parts
                or relative.as_posix() != name or "\\" in name
                or any(part.casefold() in {".git", "__pycache__", ".build", ".local"}
                       for part in relative.parts)
                or tuple(part.casefold() for part in relative.parts[:2]) == ("docs", "decisions")
                or relative.suffix.lower() in {".pyc", ".pyo", ".pyd", ".sym", ".lst", ".tmp"}):
            raise ValueError(f"invalid publication path: {name}")
        path = root
        for part in relative.parts:
            path = path / part
            if path.is_symlink():
                raise ValueError(f"publication path is a symlink: {name}")
        if not path.is_file():
            raise ValueError(f"missing publication file: {name}")
        selected.append(path)
    return selected


def source_files(root: Path) -> list[Path]:
    """Return just the declared source, documentation, and licence inputs."""
    return publication_files(root, SOURCE_NAMES)

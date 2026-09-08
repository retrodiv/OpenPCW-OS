#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 retrodiv <retrodiv@proton.me>
"""Audit repository structure, licences, metadata, language, and traceability."""

from __future__ import annotations

import hashlib
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from release_files import source_files
REQUIRED = (
    "README.md",
    "LICENSE",
    "VERSION",
    "CHANGELOG.md",
    "Makefile",
    "SOURCE_MANIFEST.sha256",
    ".github/workflows/build.yml",
    "docs/ARCHITECTURE.md",
    "docs/BOOT_PROCESS.md",
    "docs/MEMORY_MAP.md",
    "docs/BIOS_AND_BDOS.md",
    "docs/CPM_PLUS_SCOPE.md",
    "docs/DISK_FORMAT.md",
    "docs/TERMINAL.md",
    "docs/PUBLIC_ABI.md",
    "docs/IMPLEMENTATION_NOTES.md",
    "docs/DESIGN_PROVENANCE.md",
    "docs/REFERENCES.md",
    "docs/THIRD_PARTY.md",
    "docs/COMPATIBILITY.md",
    "docs/BUILD_AND_RELEASE.md",
    "docs/TESTING.md",
    "docs/TRACEABILITY.yml",
    "docs/ROUTINE_INDEX.md",
    "third_party/microsoft-msdos/437-8X8.ASM",
    "third_party/microsoft-msdos/LICENSE",
)
OWN_SOURCE_GLOBS = ("src/*.asm", "tools/*.py", "tests/*.py")
EXPECTED_ASSEMBLY = {
    "boot.asm",
    "boot_stage2.asm",
    "kernel.asm",
    "native_kernel.asm",
}
EXPECTED_THIRD_PARTY_HASHES = {
    "third_party/microsoft-msdos/437-8X8.ASM":
        "9ba690ac66ea37c6afb257a7416fef29a5cf8184936150526de0ad081739f5d7",
    "third_party/microsoft-msdos/LICENSE":
        "b5179f780ec212a434efcc989a2295a140deb0bdb17182d2bf9c5f6f1f1a01c4",
}
SPANISH_MARKERS = re.compile(
    r"\b(?:licencia|fuente propia|arranque|disquete|teclado|pantalla|fecha)\b",
    re.IGNORECASE,
)


def digest(path: Path) -> str:
    """Return a SHA-256 digest for one repository file."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    """Run the lightweight checks that require no emulator."""
    errors: list[str] = []
    try:
        selected = source_files(ROOT)
    except ValueError as error:
        print(f"project check: {error}", file=sys.stderr)
        return 1
    for relative in REQUIRED:
        if not (ROOT / relative).is_file():
            errors.append(f"missing required file: {relative}")
    version = (ROOT / "VERSION").read_text(encoding="ascii").strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        errors.append(f"VERSION is not semantic: {version!r}")
    for glob in OWN_SOURCE_GLOBS:
        for path in selected:
            if not path.relative_to(ROOT).match(glob):
                continue
            first = path.read_text(encoding="utf-8").splitlines()[:4]
            if not any("SPDX-License-Identifier: MIT" in line for line in first):
                errors.append(f"missing MIT SPDX header: {path.relative_to(ROOT)}")
    assembly = {path.name for path in selected
                if path.parent == ROOT / "src" and path.suffix == ".asm"}
    if assembly != EXPECTED_ASSEMBLY:
        errors.append(
            "authored assembly set differs from the four builder inputs: "
            + ", ".join(sorted(assembly ^ EXPECTED_ASSEMBLY))
        )
    fixtures = [path for path in selected
                if path.parent == ROOT / "tests" / "fixtures" and path.suffix == ".asm"]
    if len(fixtures) != 24:
        errors.append(f"expected 24 MIT guest fixtures, found {len(fixtures)}")
    for path in fixtures:
        first = path.read_text(encoding="utf-8").splitlines()[:4]
        if not any("SPDX-License-Identifier: MIT" in line for line in first):
            errors.append(f"guest fixture is not explicitly MIT: {path.relative_to(ROOT)}")
    build_guide = (ROOT / "docs" / "BUILD_AND_RELEASE.md").read_text(
        encoding="utf-8"
    )
    for expected in ("four authored assembly sources", "24 MIT guest probe"):
        if expected not in build_guide:
            errors.append(f"build guide omits generated project fact: {expected}")
    for relative, expected in EXPECTED_THIRD_PARTY_HASHES.items():
        path = ROOT / relative
        if path.is_file() and digest(path) != expected:
            errors.append(f"third-party file hash changed: {relative}")
    for path in (path for path in selected if path.suffix == ".md"):
        text = path.read_text(encoding="utf-8")
        if SPANISH_MARKERS.search(text):
            errors.append(f"non-English project prose marker: {path.relative_to(ROOT)}")
    trace = subprocess.run(
        [sys.executable, str(ROOT / "tools" / "check_traceability.py")],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    if trace.returncode:
        errors.append(trace.stderr.strip() or trace.stdout.strip())
    elif trace.stdout:
        print(trace.stdout.strip())
    if errors:
        print("\n".join(f"project audit: {error}" for error in errors), file=sys.stderr)
        return 1
    print("project check: layout, licence hashes, language, metadata, and traceability pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

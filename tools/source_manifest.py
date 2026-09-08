#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 retrodiv <retrodiv@proton.me>
"""Create or verify the deterministic manifest used by downstream pins."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import sys

from release_files import publication_files


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "SOURCE_MANIFEST.sha256"


def sha256(path: Path) -> str:
    """Hash one regular project file."""
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def project_files() -> list[Path]:
    """Return the explicit publication inventory in stable POSIX-path order."""
    return publication_files(ROOT)


def render() -> str:
    """Render canonical GNU-style SHA-256 records."""
    return "".join(
        f"{sha256(path)}  {path.relative_to(ROOT).as_posix()}\n"
        for path in project_files()
    )


def main() -> int:
    """Write the manifest or compare it with the current project tree."""
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        expected = render()
    except ValueError as error:
        print(f"source manifest: {error}", file=sys.stderr)
        return 1
    if args.write:
        MANIFEST.write_text(expected, encoding="ascii", newline="\n")
    elif not MANIFEST.is_file() or MANIFEST.read_text(encoding="ascii") != expected:
        print(
            "source manifest is stale; run make source-manifest after intentional changes",
            file=sys.stderr,
        )
        return 1
    print(
        f"source manifest: {len(expected.splitlines())} files, "
        f"sha256={hashlib.sha256(expected.encode('ascii')).hexdigest()}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

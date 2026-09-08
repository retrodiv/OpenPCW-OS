#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 retrodiv <retrodiv@proton.me>
"""Assemble every public guest-side compatibility probe."""

from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from release_files import source_files
FIXTURES = ROOT / "tests" / "fixtures"


def assemble(source: Path, output: Path, include: Path | None = None) -> None:
    """Assemble one probe with Pasmo and require a non-empty result."""
    command = ["pasmo", "--bin"]
    if include is not None:
        command += ["-I", str(include)]
    command += [str(source), str(output)]
    subprocess.run(command, check=True, capture_output=True, text=True)
    if not output.is_file() or not output.read_bytes():
        raise RuntimeError(f"fixture produced an empty binary: {source.name}")


def main() -> int:
    """Build each MIT-licensed guest probe in an isolated output directory."""
    sources = [path for path in source_files(ROOT)
               if path.parent == FIXTURES and path.suffix == ".asm"]
    if not sources:
        print("fixture assembly: no sources found", file=sys.stderr)
        return 1
    try:
        with tempfile.TemporaryDirectory(prefix="openpcw-fixtures-") as directory:
            temp = Path(directory)
            for source in sources:
                assemble(source, temp / f"{source.stem}.bin")
            bootstrap = temp / "openpcw_mame_bootstrap.bin"
            if len(bootstrap.read_bytes()) != 256:
                raise RuntimeError("MAME bootstrap must assemble to exactly 256 bytes")
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"fixture assembly: {error}", file=sys.stderr)
        return 1
    print(f"fixture assembly: {len(sources)} guest probes pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

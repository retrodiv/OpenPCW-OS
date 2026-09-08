#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 retrodiv <retrodiv@proton.me>
"""Verify that independent clean builds produce identical release artifacts."""

from __future__ import annotations

import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from release_files import ARTIFACT_NAMES as ARTIFACTS


def build(output: Path) -> dict[str, bytes]:
    """Run the public builder into one clean directory and return its bytes."""
    subprocess.run(
        [sys.executable, str(ROOT / "tools" / "build.py"), "--output", str(output)],
        cwd=ROOT,
        check=True,
        stdout=subprocess.DEVNULL,
    )
    return {name: (output / name).read_bytes() for name in ARTIFACTS}


def main() -> int:
    """Compare two clean builds and the checked-in distribution artifacts."""
    with tempfile.TemporaryDirectory(prefix="openpcw-repro-a-") as first_dir, \
            tempfile.TemporaryDirectory(prefix="openpcw-repro-b-") as second_dir:
        first = build(Path(first_dir))
        second = build(Path(second_dir))
    published = {name: (ROOT / "dist" / name).read_bytes() for name in ARTIFACTS}
    if first != second or first != published:
        for name in ARTIFACTS:
            values = (first[name], second[name], published[name])
            hashes = [hashlib.sha256(value).hexdigest() for value in values]
            if len(set(hashes)) != 1:
                print(f"reproducibility: {name}: {', '.join(hashes)}", file=sys.stderr)
        return 1
    print(f"reproducibility: {len(ARTIFACTS)} artifacts are byte-identical")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

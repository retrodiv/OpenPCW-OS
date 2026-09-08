#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 retrodiv <retrodiv@proton.me>
"""Prove that assembly comments have no effect on release artifacts."""

from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from release_files import ARTIFACT_NAMES as ARTIFACTS, source_files


def main() -> int:
    """Build a commented temporary source copy and compare every artifact."""
    with tempfile.TemporaryDirectory(prefix="openpcw-comments-") as temporary:
        copy = Path(temporary) / "project"
        selected = source_files(ROOT)
        for source in selected:
            destination = copy / source.relative_to(ROOT)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
        assembly = [copy / path.relative_to(ROOT) for path in selected
                    if path.parent == ROOT / "src" and path.suffix == ".asm"]
        for source in assembly:
            with source.open("a", encoding="utf-8", newline="\n") as stream:
                stream.write("\n; Documentation-only invariance probe.\n")
        output = copy / "dist"
        subprocess.run(
            [sys.executable, str(copy / "tools" / "build.py"), "--output", str(output)],
            cwd=copy,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        changed = [
            name
            for name in ARTIFACTS
            if (output / name).read_bytes() != (ROOT / "dist" / name).read_bytes()
        ]
    if changed:
        print(f"comment invariance: changed artifacts: {', '.join(changed)}", file=sys.stderr)
        return 1
    print(f"comment invariance: {len(ARTIFACTS)} artifacts are byte-identical")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

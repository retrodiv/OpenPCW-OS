#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 retrodiv <retrodiv@proton.me>
"""Inspect the public EMS, font, checksum, and extended-DSK contracts."""

from __future__ import annotations

import argparse
import binascii
import hashlib
import json
import io
from pathlib import Path
import re
import struct
import sys
import zipfile


ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
EVIDENCE = ROOT / "docs" / "RELEASE_EVIDENCE.json"
EMS_HEADER = struct.Struct("<8sHHHHI")
TRACKS = 40
TRACK_SIZE = 0x1300


def main() -> int:
    """Validate artifact structure independently from the builder implementation."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--write-evidence", action="store_true",
        help="refresh docs/RELEASE_EVIDENCE.json after all artifact checks pass",
    )
    args = parser.parse_args()
    errors: list[str] = []
    ems = (DIST / "OPENPCW.EMS").read_bytes()
    if len(ems) < EMS_HEADER.size:
        errors.append("EMS is shorter than its public header")
    else:
        magic, load, entry, length, version, crc = EMS_HEADER.unpack_from(ems)
        payload = ems[EMS_HEADER.size:]
        if (magic, load, entry, length, version) != (
            b"OPCWEMS1", 0xF200, 0xF200, len(payload), 1
        ):
            errors.append("EMS public fields differ from PUBLIC_ABI.md")
        if binascii.crc32(payload) & 0xFFFFFFFF != crc:
            errors.append("EMS payload CRC differs from its header")
    font = (DIST / "OpenPCW-OS-font.bin").read_bytes()
    if len(font) != 128 * 8:
        errors.append(f"runtime font has {len(font)} bytes instead of 1024")
    font_source = ROOT / "third_party" / "microsoft-msdos" / "437-8X8.ASM"
    source_glyphs = {}
    for raw in font_source.read_text(encoding="ascii").splitlines():
        match = re.fullmatch(r"\s*Db\s+(.+?)\s*;\s*Hex\s+#([0-9A-Fa-f]+)\s*", raw, re.I)
        if match:
            source_glyphs[int(match[2], 16)] = bytes(
                int(row.strip()[:-1], 16) for row in match[1].split(",")
            )
    glyph_mapping = {9: 0x1A, 10: 0x19, 11: 0x1A, 12: 0x1B, 13: 0x1B, 124: 0x1A}
    for character in range(128):
        if font[8 * character:8 * character + 8] != source_glyphs.get(
                glyph_mapping.get(character, character)):
            errors.append(f"font glyph {character:02X} differs from its documented licensed source")
    dsk = (DIST / "OpenPCW-OS.dsk").read_bytes()
    if len(dsk) != 256 + TRACKS * TRACK_SIZE:
        errors.append(f"extended DSK has unexpected size {len(dsk)}")
    if not dsk.startswith(b"EXTENDED CPC DSK File\r\nDisk-Info\r\n"):
        errors.append("extended DSK signature is missing")
    if dsk[0x30:0x32] != bytes((40, 1)):
        errors.append("extended DSK does not publish 40 tracks and one side")
    boot = dsk[512:1024]
    if len(boot) != 512 or sum(boot) & 0xFF != 0xFF:
        errors.append("PCW boot sector checksum is invalid")
    integration = json.loads(
        (DIST / "OpenPCW-OS-integration.json").read_text(encoding="ascii")
    )
    if integration != {
        "disk_sha256": hashlib.sha256(dsk).hexdigest(),
        "schema": 1,
        "shell_ready_pc": 0xF31B,
        "shell_ready_symbol": "resident_shell_entry",
        "system": "OpenPCW-OS",
    }:
        errors.append("emulator integration metadata differs from its public contract")
    manifest: dict[str, str] = {}
    for raw in (DIST / "SHA256SUMS").read_text(encoding="ascii").splitlines():
        digest, name = raw.split("  ", 1)
        manifest[name] = digest
    expected_names = {
        "OPENPCW.EMS",
        "OpenPCW-OS.dsk",
        "OpenPCW-OS-font.bin",
        "OpenPCW-OS-integration.json",
        "LICENSES.txt",
        "OpenPCW-OS.zip",
    }
    if manifest.keys() != expected_names:
        errors.append("SHA256SUMS has an unexpected artifact set")
    for name in sorted(manifest.keys() & expected_names):
        expected = manifest[name]
        if hashlib.sha256((DIST / name).read_bytes()).hexdigest() != expected:
            errors.append(f"SHA256SUMS mismatch for {name}")
    notice = (DIST / "LICENSES.txt").read_text(encoding="utf-8")
    license_names = ("LICENSE", "third_party/microsoft-msdos/LICENSE")
    for relative in license_names:
        if (ROOT / relative).read_text(encoding="utf-8").strip() not in notice:
            errors.append(f"distribution notices omit the complete {relative}")
    package_names = expected_names - {"OpenPCW-OS.zip"}
    try:
        with zipfile.ZipFile(io.BytesIO((DIST / "OpenPCW-OS.zip").read_bytes())) as package:
            if set(package.namelist()) != package_names or len(package.infolist()) != len(package_names):
                errors.append("release archive has missing, duplicate, or unexpected members")
            for name in sorted(package_names & set(package.namelist())):
                if package.read(name) != (DIST / name).read_bytes():
                    errors.append(f"release archive differs from loose artifact {name}")
    except zipfile.BadZipFile as error:
        errors.append(f"invalid release archive: {error}")
    if errors:
        print("\n".join(f"artifact contract: {error}" for error in errors), file=sys.stderr)
        return 1
    # Bind the observations to both their exact local inputs and this checker.
    # The source manifest covers this report alongside the remaining source.
    input_names = (
        sorted("dist/" + name for name in expected_names | {"SHA256SUMS"})
        + list(license_names)
        + ["third_party/microsoft-msdos/437-8X8.ASM", "tests/test_artifact_contracts.py"]
    )
    evidence = {
        "schema": 1,
        "scope": "local artifact structure, font selection, and notice preservation",
        "verification_command": "python3 tests/test_artifact_contracts.py",
        "input_sha256": {
            name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
            for name in sorted(input_names)
        },
        "checks": {
            "ems_header_and_crc32": "pass",
            "dsk_geometry_and_boot_checksum": "pass",
            "integration_metadata": "pass",
            "release_checksums": "pass",
            "runtime_font_glyphs_matched": 128,
            "runtime_font_substitutions": {
                f"{cell:02X}": f"{glyph:02X}" for cell, glyph in sorted(glyph_mapping.items())
            },
            "complete_notice_files": list(license_names),
            "zip_members_identical_to_loose_files": sorted(package_names),
        },
    }
    rendered = json.dumps(evidence, indent=2, sort_keys=True) + "\n"
    if args.write_evidence:
        EVIDENCE.write_text(rendered, encoding="ascii", newline="\n")
    elif not EVIDENCE.is_file() or EVIDENCE.read_text(encoding="ascii") != rendered:
        print(
            "artifact contract: release evidence is stale; "
            "run make release-evidence after intentional changes",
            file=sys.stderr,
        )
        return 1
    print("artifact contract: binaries, font mapping, complete licences, archive, hashes, and evidence pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

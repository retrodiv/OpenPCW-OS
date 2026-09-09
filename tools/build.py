#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 retrodiv <retrodiv@proton.me>
"""Build deterministic OpenPCW-OS release artifacts.

The builder assembles the authored Z80 sources, derives the runtime font from
the pinned Microsoft MIT source, validates every fixed memory boundary, and
constructs the 180 KiB PCW disk image sector by sector.  See
``docs/BUILD_AND_RELEASE.md`` for the design and validation map.
"""

from __future__ import annotations

import argparse
import binascii
import hashlib
import io
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import zipfile

from release_files import ARTIFACT_NAMES


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = PROJECT_ROOT / "src"
FONT_SOURCE = PROJECT_ROOT / "third_party" / "microsoft-msdos" / "437-8X8.ASM"
DEFAULT_OUTPUT_DIR = PROJECT_ROOT / "dist"

MAGIC = b"OPCWEMS1"
LOAD_ADDRESS = 0xF200
ENTRY_ADDRESS = 0xF200
EMS_VERSION = 1
EMS_HEADER = struct.Struct("<8sHHHHI")
TRACKS = 40
SIDES = 1
SECTORS = 9
SECTOR_SIZE = 512
TRACK_SIZE = 0x1300
INTERRUPT_QUERY = 0xFDCC
INTERRUPT_DEFAULT_POINTER = 0xFEA7
INTERRUPT_DEFAULT_ROUTINE = 0xFE90
INTERRUPT_RESTORE_PAGE = 0xFE31
SCREEN_INTERRUPT_ENTRY = 0xFDBB
PUBLIC_BDOS_ENTRY = 0xF606
PRIVATE_BDOS_ENTRY = 0xF609
PLAIN_TRANSIENT_STACK_TOP = 0xF600
GENCOM_TRANSIENT_STACK_TOP = 0xF5FE
BDOS_FRONT_END_LIMIT = 0xF800
NATIVE_PRIVATE_ABI = {
    # The resident kernel calls into fixed addresses in the separately
    # assembled hidden native module.
    "key_pending_valid": 0x3B24,
    "native_userf_restore_af": 0x57BD,
    "native_screen_transfer_private": 0x3DE5,
    "native_status_disable_private": 0x3DF5,
    "native_shell_command": 0x5937,
    "native_warm_reset": 0x5AD2,
    "native_bdos_select": 0x5B3A,
}
NATIVE_COMMON_ABI = {
    # The hidden page-one module cannot resolve symbols from the separately
    # assembled resident kernel.  Pin every common-memory address it imports
    # so an innocent layout change fails the build instead of corrupting RAM.
    "page_zero_template": 0xF309,
    "page_zero_template_end": 0xF401,
    "low_bios_console_status": 0xF209,
    "low_bios_console_input": 0xF216,
    "resident_boot_banner_prefix": 0xF389,
    "native_multisector": 0xF7F8,
    "native_current_disk": 0xF808,
    "native_error_mode": 0xF809,
    "native_bdos_saved_af": 0xF80A,
    "native_argument_a": 0xF816,
    "native_gencom_mode": 0xF818,
    "native_gencom_chain": 0xF819,
    "native_scb": 0xF81B,
    "terminal_f7_value": 0xF8BA,
    "interrupt_restore_page": 0xFE31,
    "interrupt_resume_page": 0xFF65,
    "interrupt_tpa_entry": 0xFF66,
    "interrupt_saved_sp": 0xFF7E,
    "native_disk_parameters": 0xFF80,
    "native_motor_off_ticks": 0xFF8E,
    "native_motor_ready": 0xFF90,
    "native_disk_parameter_staging": 0xFF91,
    "native_login_vector": 0xFFD3,
    "native_ro_vector": 0xFFD5,
    "native_clock_subticks": 0xFFFC,
}
KERNEL_DISPATCH_ABI = {
    "KERNEL_LOW_BIOS_CONSOLE_STATUS": "low_bios_console_status",
    "KERNEL_LOW_BIOS_CONSOLE_INPUT": "low_bios_console_input",
    "KERNEL_WARM_BOOT_PREPARE": "warm_boot_prepare",
    "KERNEL_BDOS_WAIT_CHARACTER": "bdos_wait_character",
    "KERNEL_CONSOLE_OUTPUT": ".console_output",
    "KERNEL_AUXILIARY_INPUT": ".auxiliary_input",
    "KERNEL_NO_DEVICE_STATUS": ".no_device_status",
    "KERNEL_DIRECT_CONSOLE": ".direct_console",
    "KERNEL_PRINT_STRING": ".print_string",
    "KERNEL_BDOS_READ_LINE": "bdos_read_line",
    "KERNEL_CONSOLE_STATUS": ".console_status",
    "KERNEL_VERSION": ".version",
    "KERNEL_RESET_DISK": ".reset_disk",
    "KERNEL_SELECT_DISK": ".select_disk",
    "KERNEL_OPEN_FILE": ".open_file",
    "KERNEL_CLOSE_FILE": ".close_file",
    "KERNEL_NATIVE_M_BDOS_CALL": "native_m_bdos_call",
    "KERNEL_CURRENT_DISK": ".current_disk",
    "KERNEL_SET_DMA": ".set_dma",
    "KERNEL_USER_CODE": ".user_code",
    "KERNEL_RESET_DRIVES": ".reset_drives",
    "KERNEL_ZERO_RESULT": ".zero_result",
    "KERNEL_UNSUPPORTED": ".unsupported",
    "KERNEL_SET_MULTISECTOR": ".set_multisector",
    "KERNEL_SET_ERROR_MODE": ".set_error_mode",
    "KERNEL_CHAIN_PROGRAM": ".chain_program",
    "KERNEL_SCB": ".scb",
    "KERNEL_NATIVE_DIRECT_BIOS_CALL": "native_direct_bios_call",
    "KERNEL_EXTENDED_TABLE": ".extended_table",
    "KERNEL_NATIVE_SCB_SYNC": "native_scb_sync",
    "KERNEL_NATIVE_SCB_APPLY": "native_scb_apply",
    "KERNEL_NATIVE_PHYSICAL_ERROR_ABORT": "native_physical_error_abort",
}
COMPAT_WORKSPACE_START = 0xFB00
COMPAT_WORKSPACE_END = 0xFC5C
NATIVE_LOAD_ADDRESS = 0x0100
NATIVE_EXECUTABLE_END = 0x4000
NATIVE_SCREEN_START = 0x5C00
NATIVE_BASE_TRACKS = 6
# Physical sector 9 on track zero follows the seven common-kernel sectors and
# is part of the native image; tracks 1..6 provide the remaining 54 sectors.
NATIVE_BASE_SECTORS = 1 + NATIVE_BASE_TRACKS * SECTORS
NATIVE_OVERLAY_ADDRESS = 0x8000
NATIVE_OVERLAY_TRACK = 7
NATIVE_OVERLAY_SECTORS = SECTORS
NATIVE_OPEN_OVERLAY_SECTORS = 5
NATIVE_PASSWORD_OVERLAY_ADDRESS = 0x899E
SYSTEM_TRACKS = NATIVE_OVERLAY_TRACK + 1


def assemble(
    source: Path, output: Path, symbols: Path, include: Path | None = None
) -> bytes:
    command = ["pasmo", "--bin"]
    if include is not None:
        command += ["-I", str(include)]
    command += [str(source), str(output), str(symbols)]
    subprocess.run(command, check=True)
    return output.read_bytes()


def symbol_value(symbols: Path, name: str) -> int:
    """Read one hexadecimal address from pasmo's deterministic symbol file."""
    for raw in symbols.read_text().splitlines():
        fields = raw.split()
        if len(fields) == 3 and fields[0] == name and fields[1] == "EQU":
            value = fields[2]
            if value.endswith("H"):
                return int(value[:-1], 16)
    raise SystemExit(f"assembler did not publish required symbol {name}")


def write_kernel_dispatch_include(symbols: Path, destination: Path) -> None:
    """Publish the separately assembled resident handler table symbolically."""
    lines = [
        "; Generated deterministically from kernel.asm; do not edit."
    ]
    for exported, resident_symbol in KERNEL_DISPATCH_ABI.items():
        address = symbol_value(symbols, resident_symbol)
        lines.append(f"{exported} equ 0{address:04x}h")
    destination.write_text("\n".join(lines) + "\n", encoding="ascii")


def make_ems(payload: bytes) -> bytes:
    if not payload or len(payload) > 0x2000:
        raise SystemExit(f"kernel payload must be 1..8192 bytes, got {len(payload)}")
    crc = binascii.crc32(payload) & 0xFFFFFFFF
    header = EMS_HEADER.pack(
        MAGIC, LOAD_ADDRESS, ENTRY_ADDRESS, len(payload), EMS_VERSION, crc
    )
    return header + payload


def verify_kernel_abi(payload: bytes) -> None:
    """Keep the independently implemented native-PCW public ABI stable."""

    def at(address: int, length: int) -> bytes:
        offset = address - LOAD_ADDRESS
        if offset < 0 or offset + length > len(payload):
            raise SystemExit(f"kernel does not reach fixed ABI address {address:04X}h")
        return payload[offset : offset + length]

    public_bdos = at(PUBLIC_BDOS_ENTRY, 3)
    expected_bdos = b"\xC3" + struct.pack("<H", PRIVATE_BDOS_ENTRY)
    if public_bdos != expected_bdos:
        raise SystemExit(
            f"public BDOS entry at {PUBLIC_BDOS_ENTRY:04X}h is "
            f"{public_bdos.hex()}, expected {expected_bdos.hex()}"
        )
    workspace = at(
        COMPAT_WORKSPACE_START,
        COMPAT_WORKSPACE_END - COMPAT_WORKSPACE_START + 1,
    )
    if workspace != b"\0" * len(workspace):
        occupied = COMPAT_WORKSPACE_START + next(
            index for index, value in enumerate(workspace) if value
        )
        raise SystemExit(
            "GENCOM compatibility workspace contains build-time data at "
            f"{occupied:04X}h"
        )

    query = at(INTERRUPT_QUERY, 3)
    expected_query = b"\x2A" + struct.pack("<H", INTERRUPT_DEFAULT_POINTER)
    if query != expected_query:
        raise SystemExit(
            f"interrupt query at {INTERRUPT_QUERY:04X}h is {query.hex()}, "
            f"expected {expected_query.hex()}"
        )
    target = struct.unpack("<H", at(INTERRUPT_DEFAULT_POINTER, 2))[0]
    if target != INTERRUPT_DEFAULT_ROUTINE:
        raise SystemExit(
            f"interrupt default pointer is {target:04X}h, "
            f"expected {INTERRUPT_DEFAULT_ROUTINE:04X}h"
        )
    if at(INTERRUPT_RESTORE_PAGE, 1) != b"\x84":
        raise SystemExit(
            f"interrupt restore-page byte moved from "
            f"{INTERRUPT_RESTORE_PAGE:04X}h"
        )


def make_native_font(source: Path) -> bytes:
    """Extract the low 128 glyphs from Microsoft's MIT CP437 8x8 source.

    The PCW screen environment assigns a few control cells semantics that are
    useful to native applications.  Keep those cells while using the MS-DOS
    face for the printable alphabet.
    """
    glyphs: dict[int, bytes] = {}
    pattern = re.compile(
        r"\s*Db\s+(.+?)\s*;\s*Hex\s+#([0-9A-Fa-f]+)\s*$", re.IGNORECASE
    )
    for number, raw in enumerate(source.read_text().splitlines(), 1):
        match = pattern.fullmatch(raw)
        if not match:
            continue
        character = int(match.group(2), 16)
        fields = [field.strip() for field in match.group(1).split(",")]
        try:
            rows = bytes(int(field[:-1], 16) for field in fields if field.lower().endswith("h"))
        except ValueError as error:
            raise SystemExit(f"{source.name}:{number}: malformed bitmap row") from error
        if len(fields) != 8 or len(rows) != 8 or character in glyphs:
            raise SystemExit(f"{source.name}:{number}: malformed or duplicate glyph")
        glyphs[character] = rows
    if set(glyphs) != set(range(256)):
        raise SystemExit(f"{source.name}: expected all 256 CP437 glyphs")

    result = bytearray().join(glyphs[character] for character in range(128))
    # Every cell comes from the pinned Microsoft source. LF uses its down
    # arrow and CR its left arrow; see DES-FONT-001 for the complete mapping.
    overrides = {
        0x09: glyphs[0x1A],
        0x0A: glyphs[0x19],
        0x0B: glyphs[0x1A],
        0x0C: glyphs[0x1B],
        0x0D: glyphs[0x1B],
        0x7C: glyphs[0x1A],
    }
    for character, rows in overrides.items():
        result[character * 8 : character * 8 + 8] = rows
    return bytes(result)


def pack_native_font(font: bytes) -> bytes:
    """Encode 1024 rows as a 64-byte dictionary plus four 6-bit indices.

    This fixed-size representation preserves every pixel and remains cheap
    for the Z80 guest to expand within the reserved boot-track capacity.
    """
    if len(font) != 128 * 8:
        raise SystemExit("native font is not 128 8x8 glyphs")
    dictionary = sorted(set(font))
    if len(dictionary) > 64:
        raise SystemExit(f"native font needs {len(dictionary)} row values, maximum is 64")
    dictionary.extend([0] * (64 - len(dictionary)))
    indices = [dictionary.index(row) for row in font]
    packed = bytearray(dictionary)
    for offset in range(0, len(indices), 4):
        a, b, c, d = indices[offset : offset + 4]
        packed.extend((
            a | ((b & 0x03) << 6),
            (b >> 2) | ((c & 0x0F) << 4),
            (c >> 4) | (d << 2),
        ))
    if len(packed) != 64 + 128 * 6:
        raise SystemExit("native font packing produced an invalid size")
    return bytes(packed)


def patch_boot_checksum(boot: bytes) -> bytes:
    if len(boot) != SECTOR_SIZE:
        raise SystemExit(f"boot sector is {len(boot)} bytes, expected 512")
    data = bytearray(boot)
    data[-1] = 0
    data[-1] = (0xFF - sum(data)) & 0xFF
    if sum(data) & 0xFF != 0xFF:
        raise AssertionError("PCW boot-sector checksum construction failed")
    if data[0x10:0x12] != b"\xF3\x31":
        raise SystemExit("boot entry is not present at F010h")
    if b"\x3e\x5a\xd3\xef" in data:
        raise SystemExit("boot sector still contains the retired emulator boot trap")
    return bytes(data)


def verify_disk_boot_layout(
    dsk: bytes, payload: bytes, native: bytes, overlay: bytes
) -> None:
    """Verify the guest payload placement consumed by the PCW boot loader."""
    # Extended DSK header, track-0 header, sector 1, then sector 2.
    payload_offset = 256 + 256 + SECTOR_SIZE
    padded = payload.ljust(7 * SECTOR_SIZE, b"\x00")
    actual = dsk[payload_offset : payload_offset + len(padded)]
    if actual != padded:
        raise SystemExit("physical sectors 2..8 do not contain the raw kernel payload")
    native_padded = native.ljust(NATIVE_BASE_SECTORS * SECTOR_SIZE, b"\x00")
    actual_native = (
        dsk[256 + 256 + 8 * SECTOR_SIZE :
            256 + 256 + 9 * SECTOR_SIZE]
        + b"".join(
        dsk[256 + track * TRACK_SIZE + 256 :
            256 + track * TRACK_SIZE + 256 + SECTORS * SECTOR_SIZE]
        for track in range(1, NATIVE_BASE_TRACKS + 1)
        )
    )
    if actual_native != native_padded:
        raise SystemExit(
            f"track 0 sector 9 and tracks 1..{NATIVE_BASE_TRACKS} do not contain "
            "the native hardware kernel"
        )
    overlay_padded = overlay.ljust(NATIVE_OVERLAY_SECTORS * SECTOR_SIZE, b"\x00")
    overlay_offset = 256 + NATIVE_OVERLAY_TRACK * TRACK_SIZE + 256
    actual_overlay = dsk[overlay_offset : overlay_offset + len(overlay_padded)]
    if actual_overlay != overlay_padded:
        raise SystemExit(
            f"track {NATIVE_OVERLAY_TRACK} does not contain the native Open overlay"
        )


def make_track(track: int, sectors: list[bytes]) -> bytes:
    if len(sectors) != SECTORS or any(len(s) != SECTOR_SIZE for s in sectors):
        raise ValueError("track must contain nine 512-byte sectors")
    info = bytearray(256)
    info[:12] = b"Track-Info\r\n"
    info[0x10] = track
    info[0x11] = 0
    info[0x14] = 2
    info[0x15] = SECTORS
    info[0x16] = 0x4E
    info[0x17] = 0xE5
    for index in range(SECTORS):
        off = 0x18 + index * 8
        info[off : off + 8] = bytes((track, 0, index + 1, 2, 0, 0, 0, 2))
    return bytes(info) + b"".join(sectors)


def make_dsk(boot: bytes, payload: bytes, native: bytes, overlay: bytes) -> bytes:
    system_sectors = SYSTEM_TRACKS * SECTORS - 1
    stage1_sectors = 7
    if len(payload) > stage1_sectors * SECTOR_SIZE:
        raise SystemExit(
            "kernel no longer fits the seven sectors read by boot_stage2.asm"
        )
    if not native or len(native) > NATIVE_BASE_SECTORS * SECTOR_SIZE:
        raise SystemExit(
            "native kernel must fit track 0 sector 9 and tracks "
            f"1..{NATIVE_BASE_TRACKS} "
            f"({NATIVE_BASE_SECTORS * SECTOR_SIZE} bytes)"
        )
    if not overlay or len(overlay) > NATIVE_OVERLAY_SECTORS * SECTOR_SIZE:
        raise SystemExit(
            f"native Open overlay must fit track {NATIVE_OVERLAY_TRACK} "
            f"({NATIVE_OVERLAY_SECTORS * SECTOR_SIZE} bytes)"
        )
    header = bytearray(256)
    header[:34] = b"EXTENDED CPC DSK File\r\nDisk-Info\r\n"
    creator = b"OpenPCWOS".ljust(14, b" ")
    if len(creator) != 14:
        raise AssertionError("DSK creator field must be exactly 14 bytes")
    header[0x22:0x30] = creator
    header[0x30] = TRACKS
    header[0x31] = SIDES
    header[0x34 : 0x34 + TRACKS] = bytes((TRACK_SIZE // 256,)) * TRACKS

    # The EMS wrapper is a distribution/container format for the core. A real
    # PCW needs the raw kernel bytes in physical sectors 2..8, exactly where
    # the independently written uPD765 loader reads them.
    reserved = (
        payload.ljust(stage1_sectors * SECTOR_SIZE, b"\x00")
        + native.ljust(NATIVE_BASE_SECTORS * SECTOR_SIZE, b"\x00")
        + overlay.ljust(NATIVE_OVERLAY_SECTORS * SECTOR_SIZE, b"\x00")
    )
    if len(reserved) != system_sectors * SECTOR_SIZE:
        raise AssertionError("system-track layout size mismatch")
    reserved_offset = 0
    tracks = []
    for track in range(TRACKS):
        sectors = [bytes((0xE5,)) * SECTOR_SIZE for _ in range(SECTORS)]
        for index in range(SECTORS):
            if track == 0 and index == 0:
                sectors[index] = boot
            elif track < SYSTEM_TRACKS:
                sectors[index] = reserved[
                    reserved_offset : reserved_offset + SECTOR_SIZE
                ]
                reserved_offset += SECTOR_SIZE
        tracks.append(make_track(track, sectors))
    result = bytes(header) + b"".join(tracks)
    expected = 256 + TRACKS * TRACK_SIZE
    if len(result) != expected:
        raise AssertionError(f"DSK length {len(result)} != {expected}")
    return result


def distribution_licenses() -> bytes:
    """Carry both full permission notices with every binary release package."""
    notice = (
        "OpenPCW-OS distribution notices\n"
        "==============================\n\n"
        "OpenPCW-OS code is distributed under the project MIT License below.\n"
        "The disk image and font binary include modified display-font material\n"
        "from Microsoft's MS-DOS repository, under the separate MIT notice below.\n"
        "Font source: v4.0/src/DEV/DISPLAY/EGA/437-8X8.ASM\n"
        "Recorded upstream revision: 2d04cacc5322951f187bb17e017c12920ac8ebe2\n"
        "Source repository: https://github.com/microsoft/MS-DOS\n\n"
        "Keep the applicable copyright and permission notices when redistributing\n"
        "these files, including when embedding the disk or font in another project.\n\n"
    )
    for title, relative in (
        ("OpenPCW-OS", "LICENSE"),
        ("Microsoft display font", "third_party/microsoft-msdos/LICENSE"),
    ):
        notice += title + "\n" + "-" * len(title) + "\n\n"
        notice += (PROJECT_ROOT / relative).read_text(encoding="utf-8").rstrip() + "\n\n"
    return notice.encode("utf-8")


def distribution_archive(artifacts: dict[Path, bytes]) -> bytes:
    """Package binaries and notices without host timestamps or compression drift."""
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_STORED) as archive:
        for path, data in sorted(artifacts.items(), key=lambda item: item[0].name):
            member = zipfile.ZipInfo(path.name, date_time=(1980, 1, 1, 0, 0, 0))
            member.create_system = 3
            member.external_attr = 0o100644 << 16
            archive.writestr(member, data)
    return stream.getvalue()


def outputs(output_dir: Path, temp: Path) -> dict[Path, bytes]:
    """Return every release artifact after performing the complete build audit."""
    native_font = make_native_font(FONT_SOURCE)
    packed_native_font = pack_native_font(native_font)
    (temp / "native_font.bin").write_bytes(packed_native_font)
    kernel_symbols = temp / "kernel.sym"
    payload = assemble(
        SOURCE_DIR / "kernel.asm", temp / "kernel.bin", kernel_symbols
    )
    write_kernel_dispatch_include(
        kernel_symbols, temp / "kernel_dispatch.inc"
    )
    native_symbols = temp / "native_kernel.sym"
    native_full = assemble(
        SOURCE_DIR / "native_kernel.asm",
        temp / "native_kernel.bin",
        native_symbols,
        temp,
    )
    native_loaded_end = symbol_value(native_symbols, "native_kernel_end")
    native = native_full[: native_loaded_end - NATIVE_LOAD_ADDRESS]
    overlay_start = symbol_value(native_symbols, "native_open_overlay_start")
    overlay_end = symbol_value(native_symbols, "native_open_overlay_end")
    if overlay_start != NATIVE_OVERLAY_ADDRESS or overlay_end <= overlay_start:
        raise SystemExit(
            "native Open overlay has invalid bounds: "
            f"{overlay_start:04X}h..{overlay_end:04X}h"
        )
    open_overlay = native_full[
        overlay_start - NATIVE_LOAD_ADDRESS : overlay_end - NATIVE_LOAD_ADDRESS
    ]
    if len(open_overlay) > NATIVE_OPEN_OVERLAY_SECTORS * SECTOR_SIZE:
        raise SystemExit(
            "native Open overlay collides with sparse metadata: "
            f"{len(open_overlay)} bytes, limit is "
            f"{NATIVE_OPEN_OVERLAY_SECTORS * SECTOR_SIZE}"
        )
    password_start = symbol_value(native_symbols, "native_password_overlay_start")
    password_end = symbol_value(native_symbols, "native_password_overlay_end")
    if (password_start != NATIVE_PASSWORD_OVERLAY_ADDRESS or
            password_end <= password_start):
        raise SystemExit(
            "native password overlay has invalid bounds: "
            f"{password_start:04X}h..{password_end:04X}h"
        )
    if overlay_end != password_start:
        raise SystemExit(
            "native service overlays must be contiguous and non-overlapping: "
            f"Open ends at {overlay_end:04X}h, password starts at "
            f"{password_start:04X}h"
        )
    password_overlay = native_full[
        password_start - NATIVE_LOAD_ADDRESS :
        password_end - NATIVE_LOAD_ADDRESS
    ]
    overlay_capacity = NATIVE_OVERLAY_SECTORS * SECTOR_SIZE
    if len(open_overlay) + len(password_overlay) > overlay_capacity:
        raise SystemExit(
            "native password overlay exceeds its protected block-three tail: "
            f"{len(open_overlay) + len(password_overlay)} bytes total, limit is "
            f"{overlay_capacity}"
        )
    # Both service regions are contiguous on track 7. Packing the second one
    # directly after the established Open/cursor code uses the whole track
    # while sparse metadata remains protected at the following block offset.
    overlay = open_overlay + password_overlay
    if native[:1] != b"\xC3":
        raise SystemExit("native kernel has no jump table at 0100h")
    executable_end = symbol_value(native_symbols, "native_executable_end")
    runtime_end = symbol_value(native_symbols, "native_runtime_end")
    font_address = symbol_value(native_symbols, "font_bitmap")
    font_unpacker = symbol_value(native_symbols, "native_unpack_font")
    status_address = symbol_value(native_symbols, "status_text")
    for symbol, expected in NATIVE_PRIVATE_ABI.items():
        actual = symbol_value(native_symbols, symbol)
        if actual != expected:
            raise SystemExit(
                "native/resident private ABI moved: "
                f"{symbol} is {actual:04X}h, expected {expected:04X}h"
            )
    if executable_end > NATIVE_EXECUTABLE_END:
        raise SystemExit(
            "native kernel crosses the physical page-0 executable boundary "
            f"at {NATIVE_EXECUTABLE_END:04X}h: executable end is "
            f"{executable_end:04X}h"
        )
    if runtime_end > NATIVE_SCREEN_START:
        raise SystemExit(
            "live native code/data crosses the terminal bitmap at "
            f"{NATIVE_SCREEN_START:04X}h: runtime end is {runtime_end:04X}h"
        )
    expected_status = b"Drive is A:\0"
    status_offset = status_address - NATIVE_LOAD_ADDRESS
    if (font_address != runtime_end or
            font_unpacker - font_address != len(packed_native_font) or
            not (NATIVE_LOAD_ADDRESS <= status_address < runtime_end) or
            native_full[status_offset : status_offset + len(expected_status)] !=
            expected_status):
        raise SystemExit(
            "native font/status text have invalid live/transient layout: "
            f"runtime={runtime_end:04X}h font={font_address:04X}h "
            f"unpacker={font_unpacker:04X}h "
            f"status={status_address:04X}h "
            f"loaded-end={native_loaded_end:04X}h"
        )
    screen_vector_init = symbol_value(
        native_symbols, "native_init_screen_vectors"
    )
    native_init_finish = symbol_value(native_symbols, "native_init_finish")
    low_status = symbol_value(kernel_symbols, "low_bios_console_status")
    low_input = symbol_value(kernel_symbols, "low_bios_console_input")
    expected_screen_vector_init = (
        b"\x21" + struct.pack("<H", low_status) + b"\x22\xF0\x00" +
        b"\x21" + struct.pack("<H", low_input) + b"\x22\xF3\x00" +
        b"\xC3" + struct.pack("<H", native_init_finish)
    )
    screen_vector_offset = screen_vector_init - NATIVE_LOAD_ADDRESS
    if native_full[
            screen_vector_offset:
            screen_vector_offset + len(expected_screen_vector_init)
            ] != expected_screen_vector_init:
        raise SystemExit(
            "Screen/BIOS Page Zero does not publish its bank-preserving "
            "CONST/CONIN veneers"
        )
    stage2_symbols = temp / "boot_stage2.sym"
    stage2 = assemble(
        SOURCE_DIR / "boot_stage2.asm",
        temp / "boot_stage2.bin",
        stage2_symbols,
    )
    if not stage2 or len(stage2) > 400:
        raise SystemExit(f"second-stage loader must be 1..400 bytes, got {len(stage2)}")
    boot = patch_boot_checksum(
        assemble(
            SOURCE_DIR / "boot.asm",
            temp / "boot.bin",
            temp / "boot.sym",
            temp,
        )
    )
    status_end = symbol_value(kernel_symbols, "native_bdos_status_impl_end")
    if status_end > BDOS_FRONT_END_LIMIT:
        raise SystemExit(
            "native BDOS status bridge crosses its fixed resident island: "
            f"bridge ends at {status_end:04X}h, limit is "
            f"{BDOS_FRONT_END_LIMIT:04X}h"
        )
    transient_stack_top = symbol_value(kernel_symbols, "plain_transient_stack_top")
    if transient_stack_top != PLAIN_TRANSIENT_STACK_TOP or not (
            0xF500 <= transient_stack_top and
            transient_stack_top + 2 <= PUBLIC_BDOS_ENTRY):
        raise SystemExit(
            "plain-transient stack is outside the high-loader margin: "
            f"{transient_stack_top:04X}h"
        )
    gencom_stack_top = symbol_value(kernel_symbols, "gencom_transient_stack_top")
    if gencom_stack_top != GENCOM_TRANSIENT_STACK_TOP or not (
            0xF5E0 <= gencom_stack_top and
            gencom_stack_top + 2 <= PUBLIC_BDOS_ENTRY):
        raise SystemExit(
            "GENCOM entry stack is outside the high-loader margin: "
            f"{gencom_stack_top:04X}h"
        )
    for symbol, expected in NATIVE_COMMON_ABI.items():
        actual = symbol_value(kernel_symbols, symbol)
        if actual != expected:
            raise SystemExit(
                "resident/native common-memory ABI moved: "
                f"{symbol} is {actual:04X}h, expected {expected:04X}h"
            )
    interrupt_stack_bottom = symbol_value(kernel_symbols, "interrupt_stack_bottom")
    interrupt_stack_top = symbol_value(kernel_symbols, "interrupt_stack_top")
    shell_stack_bottom = symbol_value(kernel_symbols, "shell_stack_bottom")
    shell_stack_top = symbol_value(kernel_symbols, "shell_stack_top")
    command_buffer = symbol_value(kernel_symbols, "command_buffer")
    command_buffer_end = symbol_value(kernel_symbols, "command_buffer_end")
    command_scratch = symbol_value(native_symbols, "OPENPCW_COMMON_COMMAND_BUFFER")
    if not command_buffer + 2 <= command_scratch <= command_buffer_end - 36:
        raise SystemExit("native DIR scratch FCB is outside the disposable command buffer")
    screen_stack_bottom = symbol_value(kernel_symbols, "userf_screen_stack_bottom")
    screen_stack_top = symbol_value(kernel_symbols, "userf_screen_stack_top")
    if (interrupt_stack_top - interrupt_stack_bottom != 64 or
            interrupt_stack_bottom < PUBLIC_BDOS_ENTRY or
            interrupt_stack_top > screen_stack_bottom or
            screen_stack_top - screen_stack_bottom < 34 or
            command_buffer < 0xF401 or
            command_buffer_end > 0xF500 or
            shell_stack_top - shell_stack_bottom != 32):
        raise SystemExit(
            "resident stacks overlap application allocation, callback frames, "
            "or the independent shell/command workspaces"
        )
    screen_restore = symbol_value(kernel_symbols, "native_restore_screen_mapping")
    if 0xF500 <= screen_restore < 0xF600:
        raise SystemExit(
            "screen-mapping restore helper regressed into the conventional "
            f"F5xx loader/stack workspace at {screen_restore:04X}h"
        )
    interrupt_dispatch = symbol_value(kernel_symbols, "interrupt_dispatch")
    interrupt_restore = symbol_value(kernel_symbols, "interrupt_restore_mapping")
    deferred_restore = (
        b"\xCD" + struct.pack("<H", interrupt_dispatch) + b"\xF3\xCD" +
        struct.pack("<H", interrupt_restore) + b"\xD9"
    )
    if payload.count(deferred_restore) != 1:
        raise SystemExit(
            "interrupt mapping restore is not deferred until the complete "
            "replacement dispatcher returns"
        )
    screen_interrupt = symbol_value(
        kernel_symbols, "interrupt_system_wrapper"
    )
    interrupt_entry = symbol_value(kernel_symbols, "interrupt_entry")
    warm_bdos = symbol_value(kernel_symbols, "warm_bdos_head")
    resident_shell = symbol_value(kernel_symbols, "resident_shell_entry")
    page_zero = symbol_value(kernel_symbols, "page_zero_template")
    # Preserve the loader-visible allocation boundary while keeping the live
    # IRQ stack above it. Reducing the boundary breaks PCW application loaders.
    page_zero_bdos = page_zero - LOAD_ADDRESS + 5
    if (payload[page_zero_bdos:page_zero_bdos + 3] !=
            b"\xC3" + struct.pack("<H", PUBLIC_BDOS_ENTRY)):
        raise SystemExit("plain Page Zero BDOS vector changed its allocation boundary")
    warm_default = warm_bdos - LOAD_ADDRESS + 4
    if (payload[warm_default:warm_default + 4] !=
            b"\x21" + struct.pack("<H", PUBLIC_BDOS_ENTRY) + b"\xC8"):
        raise SystemExit("ordinary WBOOT changed the plain allocation boundary")
    page_zero_interrupt = page_zero - LOAD_ADDRESS + 0x38
    expected_screen_vector = b"\xC3" + struct.pack(
        "<H", SCREEN_INTERRUPT_ENTRY
    )
    if (screen_interrupt != SCREEN_INTERRUPT_ENTRY or
            interrupt_entry != SCREEN_INTERRUPT_ENTRY or
            payload[page_zero_interrupt:page_zero_interrupt + 3] !=
            expected_screen_vector):
        raise SystemExit(
            "Screen/BIOS IM 1 vector is not anchored at the protected "
            f"resident entry {SCREEN_INTERRUPT_ENTRY:04X}h"
        )
    for symbol, address in (
            ("interrupt_system_wrapper", screen_interrupt),
            ("warm_bdos_head", warm_bdos),
            ("resident_shell_entry", resident_shell)):
        if 0xC000 <= address < 0xF000:
            raise SystemExit(
                f"live resident symbol {symbol} overlaps the GENCOM "
                f"C000h-EFFFh module range at {address:04X}h"
            )
    reenable = symbol_value(kernel_symbols, "interrupt_reenable_return")
    reenable_offset = reenable - LOAD_ADDRESS
    reti_epilogue = symbol_value(kernel_symbols, "interrupt_reti_epilogue")
    reti_offset = reti_epilogue - LOAD_ADDRESS
    if payload[reenable_offset : reenable_offset + 1] != b"\xC9" or \
            payload[reti_offset : reti_offset + 3] != b"\xFB\xED\x4D":
        raise SystemExit(
            "interrupt epilogue must retain an adjacent EI/RETI pair"
        )
    verify_kernel_abi(payload)
    ems = make_ems(payload)
    dsk = make_dsk(boot, payload, native, overlay)
    verify_disk_boot_layout(dsk, payload, native, overlay)
    shell_ready_pc = symbol_value(kernel_symbols, "resident_shell_entry")
    integration = (json.dumps({
        "disk_sha256": hashlib.sha256(dsk).hexdigest(),
        "schema": 1,
        "shell_ready_pc": shell_ready_pc,
        "shell_ready_symbol": "resident_shell_entry",
        "system": "OpenPCW-OS",
    }, indent=2, sort_keys=True) + "\n").encode("ascii")
    artifacts = {
        output_dir / "OPENPCW.EMS": ems,
        output_dir / "OpenPCW-OS.dsk": dsk,
        output_dir / "OpenPCW-OS-font.bin": native_font,
        output_dir / "OpenPCW-OS-integration.json": integration,
        output_dir / "LICENSES.txt": distribution_licenses(),
    }
    artifacts[output_dir / "OpenPCW-OS.zip"] = distribution_archive(artifacts)
    checksums = "".join(
        f"{hashlib.sha256(data).hexdigest()}  {path.name}\n"
        for path, data in artifacts.items()
    ).encode("ascii")
    artifacts[output_dir / "SHA256SUMS"] = checksums
    return artifacts


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output", type=Path, default=DEFAULT_OUTPUT_DIR,
        help="artifact directory (default: project dist directory)",
    )
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--clean", action="store_true")
    args = parser.parse_args()
    output_dir = args.output.resolve()
    if args.clean:
        if args.check:
            parser.error("--clean and --check are mutually exclusive")
        for name in ARTIFACT_NAMES:
            (output_dir / name).unlink(missing_ok=True)
        return 0
    with tempfile.TemporaryDirectory(prefix="openpcw-os-") as td:
        generated = outputs(output_dir, Path(td))
    changed = []
    for path, data in generated.items():
        if path.is_file() and path.read_bytes() == data:
            continue
        changed.append(path)
        if not args.check:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    if args.check and changed:
        for path in changed:
            print(f"out of date: {path}")
        return 1
    for path, data in generated.items():
        digest = hashlib.sha256(data).hexdigest()
        try:
            display = path.relative_to(PROJECT_ROOT)
        except ValueError:
            display = path
        print(f"{digest}  {display}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

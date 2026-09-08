#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 retrodiv <retrodiv@proton.me>
"""Optional native OpenPCW-OS integration test in upstream MAME.

The test assembles the MIT project bootstrap fixture into MAME's
validation-supplied printer-controller region. MAME transfers that entry to
the Z80 at reset, after which the bootstrap and release DSK exercise the
emulated CPU, paging, and uPD765. The debugger injects keyboard bytes and
retrieves the documented probe results.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
HELPER = ROOT / "dist" / "OpenPCW-OS.dsk"
BOOTSTRAP_SOURCE = HERE / "fixtures" / "openpcw_mame_bootstrap.asm"
WBOOT_SOURCE = HERE / "fixtures" / "openpcw_cpm_plus_wboot_probe.asm"
ENTRY_SOURCE = HERE / "fixtures" / "openpcw_cpm_plus_entry_state_probe.asm"
STACK_SOURCE = HERE / "fixtures" / "openpcw_cpm_plus_transient_stack_probe.asm"
OVERLAY_SOURCE = HERE / "fixtures" / "openpcw_cpm_plus_overlay_probe.asm"
ACTIVE_SPEC_SOURCE = (
    HERE / "fixtures" / "openpcw_cpm_plus_xbios_active_spec_probe.asm"
)
GENCOM_LOADER_SOURCE = (
    HERE / "fixtures" / "openpcw_cpm_plus_gencom_loader_probe.asm"
)
SCREEN_RSX_SOURCE = (
    HERE / "fixtures" / "openpcw_cpm_plus_screen_rsx_probe.asm"
)
SCREEN_RSX_MODULE_SOURCE = (
    HERE / "fixtures" / "openpcw_cpm_plus_screen_rsx_module.asm"
)
TRACK_SIZE = 0x1300
TRACK_DATA_SIZE = 9 * 512


class SkipTest(RuntimeError):
    """An optional external integration dependency is unavailable."""


def executable() -> str:
    configured = os.environ.get("MAME_BIN")
    if configured:
        path = Path(shutil.which(configured) or configured).expanduser().resolve()
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
        raise RuntimeError(f"$MAME_BIN is not executable: {path}")
    found = shutil.which("mame") or shutil.which("mame64")
    if found:
        return found
    fallback = Path("/usr/games/mame")
    if fallback.is_file() and os.access(fallback, os.X_OK):
        return str(fallback)
    raise SkipTest("install MAME or set $MAME_BIN")


def assemble(source: Path, output: Path) -> bytes:
    subprocess.run(
        ["pasmo", "--bin", str(source), str(output)],
        check=True, capture_output=True, text=True,
    )
    return output.read_bytes()


def dsk_offset(linear: int) -> int:
    track, within = divmod(linear, TRACK_DATA_SIZE)
    return 256 + track * TRACK_SIZE + 256 + within


def write_linear(image: bytearray, linear: int, payload: bytes) -> None:
    while payload:
        _, within = divmod(linear, TRACK_DATA_SIZE)
        count = min(len(payload), TRACK_DATA_SIZE - within)
        offset = dsk_offset(linear)
        image[offset:offset + count] = payload[:count]
        payload = payload[count:]
        linear += count


def make_program_dsk(program: bytes, name: bytes) -> bytes:
    image = bytearray(HELPER.read_bytes())
    if (len(name) != 11 or not image.startswith(b"EXTENDED CPC DSK") or
            image[0x30:0x32] != bytes((40, 1))):
        raise RuntimeError("generated helper is not the expected 40-track DSK")
    boot = image[dsk_offset(0):dsk_offset(0) + 512]
    spec = boot[:10]
    if spec[:8] != bytes((0, 0, 40, 9, 2, 8, 3, 2)):
        raise RuntimeError(f"unexpected helper disk specification: {spec.hex()}")
    block_size = 128 << spec[6]
    block_count = (len(program) + block_size - 1) // block_size
    record_count = (len(program) + 127) // 128
    if (not program or block_count > 16 or record_count > 128):
        raise RuntimeError("MAME probe must fit one CP/M directory extent")
    directory = spec[5] * TRACK_DATA_SIZE
    entry = bytearray(32)
    entry[0] = 0
    entry[1:12] = name
    entry[15] = record_count
    entry[16:16 + block_count] = bytes(
        spec[7] + index for index in range(block_count)
    )
    write_linear(image, directory, entry)
    for index in range(block_count):
        chunk = program[index * block_size:(index + 1) * block_size]
        write_linear(
            image,
            directory + (spec[7] + index) * block_size,
            chunk,
        )
    return bytes(image)


def add_active_spec_catalog(image_bytes: bytes) -> bytes:
    """Add a catalog reachable only with the probe's nine-track XDPB."""
    image = bytearray(image_bytes)
    boot = image[dsk_offset(0):dsk_offset(0) + 512]
    spec = boot[:10]
    block_size = 128 << spec[6]
    directory = 9 * TRACK_DATA_SIZE
    directory_size = spec[7] * block_size
    if image[dsk_offset(directory):dsk_offset(directory) + 32] != bytes((0xE5,)) * 32:
        raise RuntimeError("active-XDPB catalog location is not empty")
    entry = bytearray(32)
    entry[0] = 0
    entry[1:12] = b"ACTIVE  DAT"
    entry[15] = 1
    entry[16] = spec[7]
    write_linear(image, directory, entry)
    write_linear(
        image,
        directory + directory_size,
        b"GEOM" + bytes((0x1A,)) * 124,
    )
    return bytes(image)


def add_physical_overlay(image_bytes: bytes) -> bytes:
    """Add an attribute-marked absolute overlay at directory entry fifteen."""
    image = bytearray(image_bytes)
    boot = image[dsk_offset(0):dsk_offset(0) + 512]
    spec = boot[:10]
    block_size = 128 << spec[6]
    directory = spec[5] * TRACK_DATA_SIZE
    directory_size = spec[7] * block_size
    entry_offset = directory + 15 * 32
    if image[dsk_offset(entry_offset):dsk_offset(entry_offset) + 32] != \
            bytes((0xE5,)) * 32:
        raise RuntimeError("physical-overlay directory slot is not empty")
    entry = bytearray(32)
    entry[0] = 0
    entry[1:12] = bytes(value | 0x80 for value in b"OVERLAY BIN")
    entry[15] = 1
    entry[16] = spec[7] + 1
    write_linear(image, entry_offset, entry)
    write_linear(
        image,
        directory + directory_size + block_size,
        b"OPOV" + bytes((0xA5,)) * 124,
    )
    return bytes(image)


def make_gencom(transient: bytes, module: bytes | None = None) -> bytes:
    """Wrap one transient and optional attached module in a GENCOM image."""
    if not transient or len(transient) > 0xFFFF:
        raise RuntimeError("invalid GENCOM integration fixture")
    header = bytearray(256)
    header[0] = 0xC9
    header[1:3] = len(transient).to_bytes(2, "little")
    if module is None:
        return bytes(header) + transient
    if len(module) < 27 or len(module) > 0xFFFF:
        raise RuntimeError("invalid attached GENCOM module")
    module_offset = len(header) + len(transient)
    header[0x10:0x12] = module_offset.to_bytes(2, "little")
    header[0x12:0x14] = len(module).to_bytes(2, "little")
    header[0x14] = 0                    # banked resident module
    bitmap = bytes((len(module) + 7) // 8)
    return bytes(header) + transient + module + bitmap


def command_input(command: str, *, initial: int, settle: int) -> list[str]:
    lines = [f"gtime #{initial}"]
    for value in (command + "\r").encode("ascii"):
        lines += [
            "do ib!f0=80",
            f"do b@3b23={value:02x}",
            "do b@3b24=1",
            "gtime #250",
        ]
    lines.append(f"gtime #{settle}")
    return lines


def run_mame(mame: str, temp: Path, disk: Path, script: Path) -> None:
    env = dict(
        os.environ,
        SDL_VIDEODRIVER="dummy",
        SDL_AUDIODRIVER="dummy",
        QT_QPA_PLATFORM="offscreen",
    )
    process = subprocess.run(
        [
            mame, "pcw8256",
            "-noreadconfig",
            "-rompath", str(temp / "roms"),
            "-flop1", str(disk),
            "-debug", "-debugscript", str(script),
            "-video", "none", "-sound", "none",
            "-nothrottle", "-skip_gameinfo",
        ],
        cwd=temp, env=env, capture_output=True, text=True, timeout=120,
    )
    if process.returncode:
        raise RuntimeError(
            f"MAME exited with status {process.returncode}:\n"
            + process.stdout + process.stderr
        )


def run() -> None:
    mame = executable()
    if not shutil.which("pasmo"):
        raise SkipTest("pasmo is required for the MAME integration probes")
    for source in (
        HELPER, BOOTSTRAP_SOURCE, WBOOT_SOURCE, ENTRY_SOURCE, STACK_SOURCE, OVERLAY_SOURCE,
        ACTIVE_SPEC_SOURCE, GENCOM_LOADER_SOURCE, SCREEN_RSX_SOURCE,
        SCREEN_RSX_MODULE_SOURCE,
    ):
        if not source.is_file():
            raise RuntimeError(f"missing generated/test source: {source}; run make dist")

    with tempfile.TemporaryDirectory(prefix="openpcw-mame-") as td:
        temp = Path(td)
        roms = temp / "roms" / "pcw8256"
        roms.mkdir(parents=True)
        bootstrap = assemble(BOOTSTRAP_SOURCE, temp / "bootstrap.bin")
        if len(bootstrap) != 256:
            raise RuntimeError(
                f"MAME bootstrap is {len(bootstrap)} bytes, expected 256"
            )
        printer_region = bytearray(1024)
        printer_region[0x300:0x400] = bootstrap
        (roms / "40026.ic701").write_bytes(printer_region)
        # The keyboard MCU is deliberately not executed for input: the test
        # injects the shell's authored keyboard queue through MAME's debugger.
        (roms / "40027.ic801").write_bytes(bytes(1024))

        entry = assemble(ENTRY_SOURCE, temp / "ENTRY.COM")
        entry_disk = temp / "openpcw-entry.dsk"
        entry_disk.write_bytes(make_program_dsk(entry, b"ENTRY   COM"))
        entry_result = temp / "entry-result.bin"
        entry_script = temp / "entry.cmd"
        entry_lines = ["focus maincpu"]
        entry_lines += command_input("entry", initial=15000, settle=3000)
        entry_lines += ["do ib!f0=84", f"save {entry_result.name},3800,#23", "quit"]
        entry_script.write_text("\n".join(entry_lines) + "\n")
        expected_entry = bytes(10) + b"\x00\xF6" + bytes(10) + b"\xAA"
        run_mame(mame, temp, entry_disk, entry_script)
        if not entry_result.is_file() or entry_result.read_bytes() != expected_entry:
            raise RuntimeError("MAME plain-COM entry register contract differs")

        wboot = assemble(WBOOT_SOURCE, temp / "WBOOT.COM")
        wboot_disk = temp / "openpcw-wboot.dsk"
        wboot_disk.write_bytes(make_program_dsk(wboot, b"WBOOT   COM"))
        wboot_result = temp / "wboot-result.bin"
        wboot_script = temp / "wboot.cmd"
        wboot_lines = ["focus maincpu"]
        wboot_lines += command_input("wboot", initial=15000, settle=3000)
        wboot_lines += command_input("wboot", initial=0, settle=3000)
        wboot_lines += [
            "do ib!f0=84",
            f"save {wboot_result.name},3600,7",
            "quit",
        ]
        wboot_script.write_text("\n".join(wboot_lines) + "\n")
        run_mame(mame, temp, wboot_disk, wboot_script)
        expected_wboot = b"OPWB" + bytes((2, 0x1F, 0xAA))
        if (not wboot_result.is_file() or
                wboot_result.read_bytes() != expected_wboot):
            actual = wboot_result.read_bytes().hex() \
                if wboot_result.is_file() else "<missing>"
            raise RuntimeError(
                f"MAME WBOOT result differs: {actual}; "
                f"expected {expected_wboot.hex()}"
            )

        stack = assemble(STACK_SOURCE, temp / "STACK.COM")
        stack_disk = temp / "openpcw-stack.dsk"
        stack_disk.write_bytes(make_program_dsk(stack, b"STACK   COM"))
        stack_result = temp / "stack-result.bin"
        stack_script = temp / "stack.cmd"
        stack_lines = ["focus maincpu"]
        stack_lines += command_input("stack", initial=15000, settle=4000)
        stack_lines += [
            "do ib!f0=84",
            f"save {stack_result.name},3600,5",
            "quit",
        ]
        stack_script.write_text("\n".join(stack_lines) + "\n")
        run_mame(mame, temp, stack_disk, stack_script)
        expected_stack = b"OPST\0"
        if (not stack_result.is_file() or
                stack_result.read_bytes() != expected_stack):
            actual = stack_result.read_bytes().hex() \
                if stack_result.is_file() else "<missing>"
            raise RuntimeError(
                f"MAME transient-stack result differs: {actual}; "
                f"expected {expected_stack.hex()}"
            )

        overlay = assemble(OVERLAY_SOURCE, temp / "OVERLAY.BIN")
        overlay_disk = temp / "openpcw-overlay.dsk"
        overlay_disk.write_bytes(make_program_dsk(
            make_gencom(overlay), b"OVERLAY COM"
        ))
        overlay_result = temp / "overlay-result.bin"
        overlay_payload = temp / "overlay-payload.bin"
        overlay_script = temp / "overlay.cmd"
        overlay_lines = ["focus maincpu"]
        overlay_lines += command_input("overlay", initial=15000, settle=8000)
        overlay_lines += [
            "do ib!f0=84",
            f"save {overlay_result.name},3800,#14",
            f"save {overlay_payload.name},3600,#128",
            "quit",
        ]
        overlay_script.write_text("\n".join(overlay_lines) + "\n")
        run_mame(mame, temp, overlay_disk, overlay_script)
        expected_overlay_tail = bytes(4)
        expected_overlay_payload = b"F59M" + bytes((0x5A,)) * 124
        actual_result = overlay_result.read_bytes() \
            if overlay_result.is_file() else b""
        actual_payload = overlay_payload.read_bytes() \
            if overlay_payload.is_file() else b""
        if (actual_result[10:] != expected_overlay_tail or
                actual_payload != expected_overlay_payload):
            raise RuntimeError(
                "MAME nested sparse-M overlay result differs: "
                f"result={actual_result.hex()} payload={actual_payload.hex()}"
            )

        active_spec = assemble(ACTIVE_SPEC_SOURCE, temp / "XDPBACT.COM")
        active_spec_disk = temp / "openpcw-active-xdpb.dsk"
        active_spec_disk.write_bytes(add_active_spec_catalog(
            make_program_dsk(active_spec, b"XDPBACT COM")
        ))
        active_spec_result = temp / "active-xdpb-result.bin"
        active_spec_script = temp / "active-xdpb.cmd"
        active_spec_lines = ["focus maincpu"]
        active_spec_lines += command_input(
            "xdpbact", initial=15000, settle=8000
        )
        active_spec_lines += [
            "do ib!f0=84",
            f"save {active_spec_result.name},3900,#20",
            "quit",
        ]
        active_spec_script.write_text("\n".join(active_spec_lines) + "\n")
        run_mame(mame, temp, active_spec_disk, active_spec_script)
        actual_active_spec = active_spec_result.read_bytes() \
            if active_spec_result.is_file() else b""
        active_contract = (
            len(actual_active_spec) == 20
            and actual_active_spec[:6] == b"OPA1\0\1"
            and actual_active_spec[7:9] == b"\0\0"
            and actual_active_spec[16:20] == b"GEOM"
        )
        if not active_contract:
            raise RuntimeError(
                "MAME DD L XDPB active-geometry result differs: "
                f"{actual_active_spec.hex()}"
            )

        gencom_loader = assemble(GENCOM_LOADER_SOURCE, temp / "GENLOAD.BIN")
        gencom_loader_disk = temp / "openpcw-gencom-loader.dsk"
        gencom_loader_disk.write_bytes(add_physical_overlay(
            make_program_dsk(make_gencom(gencom_loader), b"GENLOAD COM")
        ))
        gencom_loader_result = temp / "gencom-loader-result.bin"
        gencom_loader_script = temp / "gencom-loader.cmd"
        gencom_loader_lines = ["focus maincpu"]
        gencom_loader_lines += command_input(
            "genload", initial=15000, settle=10000
        )
        gencom_loader_lines += [
            "do ib!f0=84",
            f"save {gencom_loader_result.name},3700,8",
            "quit",
        ]
        gencom_loader_script.write_text("\n".join(gencom_loader_lines) + "\n")
        run_mame(mame, temp, gencom_loader_disk, gencom_loader_script)
        expected_gencom_loader = b"OPGO\0" + bytes((0xFF,)) * 3
        actual_gencom_loader = gencom_loader_result.read_bytes() \
            if gencom_loader_result.is_file() else b""
        if actual_gencom_loader != expected_gencom_loader:
            raise RuntimeError(
                "MAME GENCOM loader-boundary result differs: "
                f"{actual_gencom_loader.hex()}; expected "
                f"{expected_gencom_loader.hex()}"
            )

        screen_rsx = assemble(SCREEN_RSX_SOURCE, temp / "SCREENRSX.BIN")
        screen_rsx_module = assemble(
            SCREEN_RSX_MODULE_SOURCE, temp / "SCREENRSX.RSX"
        )
        if len(screen_rsx_module) != 0xF00:
            raise RuntimeError(
                "SCR RUN attached module must allocate E100h-EFFFh: "
                f"{len(screen_rsx_module)} bytes"
            )
        screen_rsx_disk = temp / "openpcw-screen-rsx.dsk"
        screen_rsx_disk.write_bytes(make_program_dsk(
            make_gencom(screen_rsx, screen_rsx_module), b"SCRNRSX COM"
        ))
        screen_rsx_result = temp / "screen-rsx-result.bin"
        screen_rsx_script = temp / "screen-rsx.cmd"
        screen_rsx_lines = ["focus maincpu"]
        screen_rsx_lines += command_input(
            "scrnrsx", initial=15000, settle=10000
        )
        screen_rsx_lines += [
            "do ib!f0=84",
            f"save {screen_rsx_result.name},3800,5",
            "quit",
        ]
        screen_rsx_script.write_text("\n".join(screen_rsx_lines) + "\n")
        run_mame(mame, temp, screen_rsx_disk, screen_rsx_script)
        expected_screen_rsx = b"OPSR\0"
        actual_screen_rsx = screen_rsx_result.read_bytes() \
            if screen_rsx_result.is_file() else b""
        if actual_screen_rsx != expected_screen_rsx:
            raise RuntimeError(
                "MAME attached-RSX SCR RUN/interrupt result differs: "
                f"{actual_screen_rsx.hex()}; expected "
                f"{expected_screen_rsx.hex()}"
            )

    print("PASS: MAME native boot + plain-COM entry state + WBOOT lifecycle + transient-stack isolation "
          "+ nested sparse-M overlay + DD L XDPB active geometry "
          "+ GENCOM loader-boundary physical overlay "
          "+ attached-RSX SCR RUN interrupt/mapping")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--required", action="store_true",
                        help="fail when an integration dependency is unavailable")
    args = parser.parse_args()
    try:
        run()
    except SkipTest as error:
        print(f"{'FAIL' if args.required else 'SKIP'}: {error}")
        return 1 if args.required else 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 retrodiv <retrodiv@proton.me>
"""Optional native WBOOT and Page Zero integration test in upstream JOYCE."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "dist" / "OpenPCW-OS.dsk"
PROBE = ROOT / "tests" / "fixtures" / "openpcw_cpm_plus_wboot_probe.asm"
BOOTSTRAP = ROOT / "tests" / "fixtures" / "openpcw_mame_bootstrap.asm"
FONT = ROOT / "dist" / "OpenPCW-OS-font.bin"
TRACK_SIZE = 0x1300
TRACK_DATA_SIZE = 9 * 512
VIDEO_WIDTH = 720
VIDEO_HEIGHT = 512
WINDOW_WIDTH = 800
WINDOW_HEIGHT = 600
EXPECTED = "OPENPCW WBOOT PASS"


class SkipTest(RuntimeError):
    """An optional external integration dependency is unavailable."""


def executable() -> str:
    """Resolve an installed JOYCE without depending on a user's configuration."""
    configured = os.environ.get("JOYCE_BIN")
    if configured:
        path = Path(shutil.which(configured) or configured).expanduser().resolve()
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
        raise RuntimeError(f"$JOYCE_BIN is not executable: {path}")
    found = shutil.which("xjoyce")
    if found:
        return found
    raise SkipTest("install JOYCE or set $JOYCE_BIN to the xjoyce executable")


def dsk_offset(linear: int) -> int:
    """Map a linear payload offset to the extended-DSK sector payload."""
    track, within = divmod(linear, TRACK_DATA_SIZE)
    return 256 + track * TRACK_SIZE + 256 + within


def write_linear(image: bytearray, linear: int, payload: bytes) -> None:
    """Write bytes across extended-DSK track headers."""
    while payload:
        _, within = divmod(linear, TRACK_DATA_SIZE)
        count = min(len(payload), TRACK_DATA_SIZE - within)
        offset = dsk_offset(linear)
        image[offset:offset + count] = payload[:count]
        payload = payload[count:]
        linear += count


def make_probe_dsk(program: bytes) -> bytes:
    """Add WBOOT.COM to a temporary copy of the release disk."""
    image = bytearray(HELPER.read_bytes())
    boot = image[dsk_offset(0):dsk_offset(0) + 512]
    spec = boot[:10]
    if (not image.startswith(b"EXTENDED CPC DSK") or
            image[0x30:0x32] != bytes((40, 1)) or
            spec[:8] != bytes((0, 0, 40, 9, 2, 8, 3, 2))):
        raise RuntimeError("release artifact has an unexpected disk geometry")
    block_size = 128 << spec[6]
    if not program or len(program) > block_size:
        raise RuntimeError("WBOOT probe must fit one allocation block")
    directory = spec[5] * TRACK_DATA_SIZE
    entry = bytearray(32)
    entry[1:12] = b"WBOOT   COM"
    entry[15] = (len(program) + 127) // 128
    entry[16] = spec[7]
    write_linear(image, directory, entry)
    write_linear(image, directory + spec[7] * block_size, program)
    return bytes(image)


def free_display() -> str:
    """Select an unused X display number for the isolated JOYCE window."""
    for number in range(120, 220):
        if not Path(f"/tmp/.X{number}-lock").exists():
            return f":{number}"
    raise RuntimeError("no free X display is available")


def stop(process: subprocess.Popen[bytes] | None) -> None:
    """Terminate one integration subprocess cleanly."""
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(5)


def wait_for_window(env: dict[str, str], process: subprocess.Popen[bytes]) -> str:
    """Wait for JOYCE's visible X window and return its identifier."""
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"JOYCE exited with status {process.returncode}")
        result = subprocess.run(
            ["xdotool", "search", "--onlyvisible", "--name", "JOYCE v"],
            env=env,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0 and result.stdout.split():
            return result.stdout.split()[-1]
        time.sleep(0.2)
    raise RuntimeError("JOYCE window did not appear")


def type_command(env: dict[str, str], window: str, command: str) -> None:
    """Type one command at a pace accepted by JOYCE's keyboard scan."""
    subprocess.run(
        ["xdotool", "windowfocus", "--sync", window],
        env=env,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    for key in (*command, "Return"):
        subprocess.run(
            ["xdotool", "keydown", "--window", window, key], env=env, check=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        time.sleep(0.15)
        subprocess.run(
            ["xdotool", "keyup", "--window", window, key], env=env, check=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        time.sleep(0.10)


def capture(joyce: str, config: Path, bootstrap: Path,
            disk: Path, screenshot: Path) -> None:
    """Boot the probe disk, invoke it twice, and capture the final display."""
    display = free_display()
    env = dict(os.environ, DISPLAY=display, SDL_VIDEODRIVER="x11", SDL_AUDIODRIVER="dummy")
    config.mkdir()
    # JOYCE's -h is relative to the user's home, even when given a leading /.
    # Resolve our private temporary directory through that interface.
    config_argument = os.path.relpath(config, Path.home())
    xvfb: subprocess.Popen[bytes] | None = None
    emulator: subprocess.Popen[bytes] | None = None
    try:
        xvfb = subprocess.Popen(
            ["Xvfb", display, "-screen", "0", f"{WINDOW_WIDTH}x{WINDOW_HEIGHT}x24", "-nolisten", "tcp"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        time.sleep(1)
        emulator = subprocess.Popen(
            [joyce, "-h", config_argument, "-e", str(bootstrap), "-a", str(disk)],
            env=env,
            cwd=config.parent,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        window = wait_for_window(env, emulator)
        subprocess.run(
            ["xdotool", "windowmove", window, "0", "0"], env=env, check=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        subprocess.run(
            ["xdotool", "windowsize", window, str(WINDOW_WIDTH), str(WINDOW_HEIGHT)],
            env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        time.sleep(5)
        for command in ("wboot", "wboot"):
            type_command(env, window, command)
            time.sleep(3)
        subprocess.run(
            ["ffmpeg", "-loglevel", "error", "-y", "-f", "x11grab",
             "-video_size", f"{WINDOW_WIDTH}x{WINDOW_HEIGHT}", "-i", f"{display}+0,0",
             "-frames:v", "1", str(screenshot)],
            env=env,
            check=True,
        )
    finally:
        stop(emulator)
        stop(xvfb)


def decode(path: Path) -> list[str]:
    """Decode the PCW display with the exact generated runtime font."""
    try:
        from PIL import Image
    except ImportError as error:
        raise SkipTest("install Pillow to decode the JOYCE framebuffer") from error
    raw_font = FONT.read_bytes()
    glyphs = {
        tuple(raw_font[index:index + 8]): chr(index // 8)
        for index in range(0, len(raw_font), 8)
    }
    glyphs[(0,) * 8] = " "
    image = Image.open(path).convert("RGB")
    x = (WINDOW_WIDTH - VIDEO_WIDTH) // 2
    y = (WINDOW_HEIGHT - VIDEO_HEIGHT) // 2
    lines = []
    for row in range(VIDEO_HEIGHT // 16):
        text = []
        for column in range(VIDEO_WIDTH // 8):
            bitmap = []
            for source_row in range(8):
                bits = 0
                py = y + row * 16 + source_row * 2
                for source_column in range(8):
                    if max(image.getpixel((x + column * 8 + source_column, py))) >= 160:
                        bits |= 1 << (7 - source_column)
                bitmap.append(bits)
            text.append(glyphs.get(tuple(bitmap), "?"))
        lines.append("".join(text).rstrip())
    return lines


def run() -> None:
    """Execute the complete optional JOYCE validation."""
    joyce = executable()
    for tool in ("pasmo", "Xvfb", "xdotool", "ffmpeg"):
        if not shutil.which(tool):
            raise SkipTest(f"missing external integration tool: {tool}")
    try:
        import PIL.Image
    except ImportError as error:
        raise SkipTest("install Pillow to decode the JOYCE framebuffer") from error
    for source in (HELPER, PROBE, BOOTSTRAP, FONT):
        if not source.is_file():
            raise RuntimeError(f"missing generated/test source: {source}; run make dist")
    with tempfile.TemporaryDirectory(prefix="openpcw-joyce-") as directory:
        temp = Path(directory)
        com = temp / "WBOOT.COM"
        disk = temp / "openpcw-wboot.dsk"
        screenshot = temp / "joyce-wboot.png"
        bootstrap = temp / "bootstrap.bin"
        subprocess.run(["pasmo", "--bin", str(BOOTSTRAP), str(bootstrap)], check=True)
        data = bootstrap.read_bytes()
        if len(data) != 256:
            raise RuntimeError("the project PCW bootstrap must assemble to 256 bytes")
        # The shared fixture is assembled for 0002h. JOYCE loads -e at 0000h.
        bootstrap.write_bytes(b"\0\0" + data)
        subprocess.run(["pasmo", "--bin", str(PROBE), str(com)], check=True)
        disk.write_bytes(make_probe_dsk(com.read_bytes()))
        capture(joyce, temp / "config", bootstrap, disk, screenshot)
        lines = decode(screenshot)
        if not any(EXPECTED in line for line in lines):
            visible = "\n".join(line for line in lines if line)
            raise RuntimeError(f"JOYCE display result differs:\n{visible}")
    print("PASS: JOYCE native WBOOT resumes the shell and reconstructs Page Zero")


def main() -> int:
    """Treat unavailable optional dependencies as a reported skip."""
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

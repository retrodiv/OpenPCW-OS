#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 retrodiv <retrodiv@proton.me>
"""Execute assembled entry/return sequences against OpenPCW's register contract.

The small interpreter below covers these straight-line Z80 sequences only.
Filesystem execution is a stub returning several success/error register states;
full machine execution of the entry fixture belongs to integration_mame.py.
"""

from pathlib import Path
import random
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REGISTERS = ("af", "bc", "de", "hl", "af_alt", "bc_alt", "de_alt", "hl_alt", "ix", "iy", "sp")


def execute(payload, start, registers, service=None):
    memory = bytearray(65536)
    memory[0xF200:0xF200 + len(payload)] = payload
    state = dict(registers)
    pc = start
    mode, enabled = None, False

    def word(address):
        return memory[address] | (memory[(address + 1) & 0xFFFF] << 8)

    for _ in range(64):
        opcode = memory[pc]
        pc += 1
        if opcode in (0x01, 0x11, 0x21, 0x31):
            state[{0x01: "bc", 0x11: "de", 0x21: "hl", 0x31: "sp"}[opcode]] = word(pc)
            pc += 2
        elif opcode == 0x22:
            address = word(pc)
            memory[address] = state["hl"] & 255
            memory[(address + 1) & 65535] = state["hl"] >> 8
            pc += 2
        elif opcode == 0xE5:
            state["sp"] = (state["sp"] - 2) & 65535
            memory[state["sp"]] = state["hl"] & 255
            memory[(state["sp"] + 1) & 65535] = state["hl"] >> 8
        elif opcode == 0xF1:
            state["af"] = word(state["sp"])
            state["sp"] = (state["sp"] + 2) & 65535
        elif opcode in (0x08, 0xD9):
            for register in (("af",) if opcode == 0x08 else ("bc", "de", "hl")):
                alternate = register + "_alt"
                state[register], state[alternate] = state[alternate], state[register]
        elif opcode in (0xDD, 0xFD):
            assert memory[pc] == 0x21, "unexpected index instruction"
            state["ix" if opcode == 0xDD else "iy"] = word(pc + 1)
            pc += 3
        elif opcode == 0xED:
            assert memory[pc] == 0x56, "unexpected extended instruction"
            mode = 1
            pc += 1
        elif opcode == 0xFB:
            enabled = True
        elif opcode == 0xCD:
            assert service and word(pc) == service[0], "unexpected service call"
            state.update(service[1])
            pc += 2
        elif opcode == 0xC3:
            pc = word(pc)
            assert pc == 0x0100, "entry must transfer to the transient program"
            return state, memory, mode, enabled
        elif opcode == 0xC9:
            assert service, "entry must jump to the transient program"
            return state, memory, mode, enabled
        else:
            raise AssertionError(f"unsupported entry opcode {opcode:02X} at {pc - 1:04X}")
    raise AssertionError("entry/return sequence did not terminate")


def main():
    with tempfile.TemporaryDirectory(prefix="openpcw-entry-") as directory:
        output = Path(directory) / "kernel.bin"
        symbols = Path(directory) / "kernel.symbols"
        subprocess.run(["pasmo", "--bin", str(ROOT / "src/kernel.asm"), str(output), str(symbols)], check=True)
        payload = output.read_bytes()
        published = (ROOT / "dist/OPENPCW.EMS").read_bytes()[20:]
        assert payload == published, "entry checks must exercise the distributed kernel"
        addresses = {}
        for raw in symbols.read_text().splitlines():
            fields = raw.split()
            if len(fields) == 3 and fields[1] == "EQU":
                addresses[fields[0]] = int(fields[2][:-1], 16)
        random_state = random.Random(0x504357)
        for _ in range(32):
            initial = {name: random_state.randrange(65536) for name in REGISTERS}
            actual, memory, mode, enabled = execute(payload, addresses["plain_transient_entry"], initial)
            assert actual == {name: (0xF600 if name == "sp" else 0) for name in REGISTERS}, actual
            assert memory[0xF600:0xF602] == b"\0\0", "missing warm-boot return word"
            assert mode == 1 and enabled, "transient must enter with IM 1 interrupts enabled"
        for function in (".open_file", ".close_file"):
            for result in ({"af": 0x0044, "hl": 0}, {"af": 0xFF81, "hl": 0x07FF}):
                initial = {name: 0xABCD for name in REGISTERS}
                returned = dict(result, bc=0xCAFE, de=0xBEEF)
                actual, _, _, _ = execute(payload, addresses[function], initial,
                                           (addresses["native_m_bdos_call"], returned))
                assert actual["af"] == result["af"] and actual["hl"] == result["hl"]
                assert actual["bc"] == actual["de"] == 0
    print("entry contract: 32 initial register states and Open/Close success/error returns pass")


if __name__ == "__main__":
    main()

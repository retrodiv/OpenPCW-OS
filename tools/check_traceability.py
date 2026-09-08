#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 retrodiv <retrodiv@proton.me>
"""Validate and render symbol-level design and verification traceability."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import re
import sys

from release_files import source_files


ROOT = Path(__file__).resolve().parents[1]
TRACE_PATH = ROOT / "docs" / "TRACEABILITY.yml"
INDEX_PATH = ROOT / "docs" / "ROUTINE_INDEX.md"
LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_.$?@]*):")
TRANSFER_RE = re.compile(
    r"\b(?:call|jp)\s+(?:(?:nz|z|nc|c|po|pe|p|m),\s*)?"
    r"([A-Za-z_][A-Za-z0-9_.$?@]*)",
    re.IGNORECASE,
)
CONTRACT_FIELDS = ("inputs", "outputs", "registers", "state", "memory")


@dataclass(frozen=True)
class Routine:
    """One global assembly entry reached by a call, jump, or public entry."""

    file: str
    line: int
    symbol: str


def load_trace() -> dict:
    """Load the JSON-compatible YAML trace record with the Python standard library."""
    try:
        value = json.loads(TRACE_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"cannot read {TRACE_PATH}: {error}") from error
    if not isinstance(value, dict):
        raise SystemExit("TRACEABILITY.yml must contain one mapping")
    return value


def material_routines(source: Path) -> list[Routine]:
    """Find global transfer targets plus explicit entry/start symbols.

    Local dot-labels are basic blocks.  Global CALL/JP targets are the stable
    routine unit used by this project.  Named entries are included because a
    boot loader or application can reach them without an in-file transfer.
    """
    relative = source.relative_to(ROOT).as_posix()
    labels: dict[str, int] = {}
    transfers: set[str] = set()
    lines = source.read_text(encoding="utf-8").splitlines()
    for number, raw in enumerate(lines, 1):
        code = raw.split(";", 1)[0].strip()
        label = LABEL_RE.match(code)
        if label and not label.group(1).startswith("."):
            labels[label.group(1)] = number
        transfers.update(
            match.group(1)
            for match in TRANSFER_RE.finditer(code)
            if not match.group(1).startswith(".")
        )
    explicit = {
        name
        for name in labels
        if name.endswith(("_entry", "_start"))
        or name in {
            "boot_entry",
            "stage2_entry",
            "kernel_entry",
            "bdos_public_entry",
            "interrupt_private_page_start",
        }
    }
    selected = (transfers | explicit) & labels.keys()
    return [
        Routine(relative, labels[name], name)
        for name in sorted(selected, key=lambda item: labels[item])
    ]


def resolve_component(routine: Routine, components: list[dict]) -> dict | None:
    """Resolve a routine using the first matching ordered component rule."""
    for component in components:
        if routine.file not in component.get("files", []):
            continue
        if any(
            re.fullmatch(pattern, routine.symbol)
            for pattern in component.get("symbol_patterns", [])
        ):
            return component
    return None


def purpose(symbol: str) -> str:
    """Turn the action-oriented assembly symbol into a concise index purpose."""
    words = symbol.strip("_").replace("_", " ")
    return f"Implements {words}."


def markdown(trace: dict, resolved: list[tuple[Routine, dict]]) -> str:
    """Render the deterministic human-readable routine contract index."""
    out = [
        "<!-- SPDX-License-Identifier: MIT -->",
        "<!-- Copyright (c) 2026 retrodiv <retrodiv@proton.me> -->",
        "# Routine contract index",
        "",
        "This generated index covers every global assembly entry reached through a",
        "direct `CALL`/`JP` and every explicit boot or public entry. Dot-prefixed",
        "labels are local basic blocks documented by their enclosing routine.",
        "",
        "Each routine inherits the inputs, outputs, register policy, state, and",
        "memory contract of its component below. Routine-local source comments refine",
        "that contract where an operation has narrower preservation or boundary rules.",
        "The source symbol supplies the concise action name; design and validation IDs",
        "link to the detailed rationale and executable evidence.",
        "",
        "## Component contracts",
        "",
    ]
    used = {component["id"] for _, component in resolved}
    for component in trace["components"]:
        if component["id"] not in used:
            continue
        contract = component["contract"]
        out.extend(
            [
                f"### {component['id']}",
                "",
                f"- Inputs: {contract['inputs']}.",
                f"- Outputs: {contract['outputs']}.",
                f"- Registers: {contract['registers']}.",
                f"- State: {contract['state']}.",
                f"- Memory: {contract['memory']}.",
                f"- Design basis: {', '.join(f'`{item}`' for item in component['designs'])}.",
                f"- Public basis: {', '.join(f'`{item}`' for item in component['references'])}.",
                f"- Validation: {', '.join(f'`{item}`' for item in component['validations'])}.",
                "",
            ]
        )
    by_file: dict[str, list[tuple[Routine, dict]]] = {}
    for item in resolved:
        by_file.setdefault(item[0].file, []).append(item)
    out.extend(["## Material routines", ""])
    for file, items in by_file.items():
        out.extend(
            [
                f"### `{file}`",
                "",
                "| Symbol | Purpose | Contract | Evidence |",
                "|---|---|---|---|",
            ]
        )
        for routine, component in items:
            evidence = ", ".join(
                f"`{item}`"
                for item in component["designs"] + component["validations"]
            )
            out.append(
                f"| `{routine.symbol}` (line {routine.line}) | "
                f"{purpose(routine.symbol)} | [{component['id']}](#{component['id'].lower()}) | "
                f"{evidence} |"
            )
        out.append("")
    return "\n".join(out).rstrip() + "\n"


def documentation_status(trace: dict) -> tuple[list[str], list[str]]:
    """Require provenance declarations and report supplemental documentation."""
    errors, pending = [], []
    for component in trace.get("components", []):
        identifier = component.get("id", "<missing>")
        provenance = component.get("provenance_status")
        if provenance != "documented":
            errors.append(
                f"component {identifier} requires provenance_status 'documented'; "
                f"got {provenance!r}"
            )
        status = component.get("status")
        if status not in ("documented", "pending documentation"):
            errors.append(f"component {identifier} has unknown documentation status {status!r}")
        elif status == "pending documentation":
            note = component.get("documentation_note")
            if not isinstance(note, str) or not note.strip():
                errors.append(f"component {identifier} needs a documentation_note")
            else:
                pending.append(f"{identifier}: {note.strip()}")
        elif "documentation_note" in component:
            errors.append(
                f"component {identifier} has a documentation_note with status 'documented'"
            )
    return errors, pending


def validate(trace: dict) -> tuple[list[str], list[tuple[Routine, dict]]]:
    """Return validation errors and the resolved material-routine set."""
    errors: list[str] = []
    components = trace.get("components")
    if not isinstance(components, list) or not components:
        return ["traceability record has no components"], []
    validations = trace.get("validations", {})
    selected = source_files(ROOT)
    documents = {
        path.relative_to(ROOT).as_posix(): path.read_text(encoding="utf-8")
        for path in selected
        if path.suffix == ".md" and path.is_relative_to(ROOT / "docs")
        and path != INDEX_PATH
    }
    doc_text = "\n".join(documents.values())
    status_errors, _ = documentation_status(trace)
    errors.extend(status_errors)
    for component in components:
        identifier = component.get("id", "<missing>")
        record = component.get("provenance_record")
        if not isinstance(record, str) or record not in documents or not documents[record].strip():
            errors.append(
                f"component {identifier} needs a provenance_record naming a non-empty "
                "document in the source-release inventory"
            )
        for field in ("files", "symbol_patterns", "designs", "references", "validations"):
            if not component.get(field):
                errors.append(f"component {identifier} has no {field}")
        contract = component.get("contract", {})
        for field in CONTRACT_FIELDS:
            if not contract.get(field):
                errors.append(f"component {identifier} has no contract.{field}")
        for design in component.get("designs", []):
            if design not in doc_text:
                errors.append(f"component {identifier} references undocumented {design}")
        for reference in component.get("references", []):
            if reference not in doc_text:
                errors.append(f"component {identifier} references undocumented {reference}")
        for validation in component.get("validations", []):
            if validation not in validations:
                errors.append(f"component {identifier} references undefined {validation}")
        for pattern in component.get("symbol_patterns", []):
            try:
                re.compile(pattern)
            except re.error as error:
                errors.append(f"component {identifier} has invalid pattern {pattern}: {error}")

    routines: list[Routine] = []
    for source in (path for path in selected
                   if path.parent == ROOT / "src" and path.suffix == ".asm"):
        routines.extend(material_routines(source))
    resolved: list[tuple[Routine, dict]] = []
    for routine in routines:
        component = resolve_component(routine, components)
        if component is None:
            errors.append(f"untraced material routine {routine.file}:{routine.line}:{routine.symbol}")
        else:
            resolved.append((routine, component))
    if not routines:
        errors.append("assembly scan found no material routines")
    return errors, resolved


def main() -> int:
    """Check trace data and either verify or refresh the generated index."""
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--write-index",
        action="store_true",
        help="write docs/ROUTINE_INDEX.md after validating traceability",
    )
    args = parser.parse_args()
    trace = load_trace()
    try:
        errors, resolved = validate(trace)
    except ValueError as error:
        print(f"traceability: {error}", file=sys.stderr)
        return 1
    if errors:
        print("\n".join(f"traceability: {error}" for error in errors), file=sys.stderr)
        return 1
    expected = markdown(trace, resolved)
    if args.write_index:
        INDEX_PATH.write_text(expected, encoding="utf-8", newline="\n")
    elif not INDEX_PATH.is_file() or INDEX_PATH.read_text(encoding="utf-8") != expected:
        print(
            "traceability: docs/ROUTINE_INDEX.md is stale; "
            "run python3 tools/check_traceability.py --write-index",
            file=sys.stderr,
        )
        return 1
    _, pending = documentation_status(trace)
    for note in pending:
        print(f"supplemental documentation: {note}")
    print(f"traceability: {len(resolved)} material routines covered; "
          f"{len(pending)} supplemental documentation notes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

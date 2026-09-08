#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 retrodiv <retrodiv@proton.me>
"""Exercise publication boundaries and documentation diagnostics."""

from contextlib import redirect_stderr, redirect_stdout
import io
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import check_traceability
from release_files import publication_files
import integration_joyce
import integration_mame


class PublicationTests(unittest.TestCase):
    def test_check_rejects_corrupt_artifacts_without_repairing_them(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for source in publication_files(ROOT) + [ROOT / "SOURCE_MANIFEST.sha256"]:
                destination = root / source.relative_to(ROOT)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)
            artifact = root / "dist" / "OpenPCW-OS.dsk"
            damaged = b"damaged release artifact\n"
            artifact.write_bytes(damaged)
            result = subprocess.run(
                ["make", "check", f"PYTHON={sys.executable}"], cwd=root,
                capture_output=True, text=True, timeout=20,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("source manifest is stale", result.stderr)
            self.assertEqual(artifact.read_bytes(), damaged)

    def test_required_integrations_fail_instead_of_skipping(self):
        for module in (integration_mame, integration_joyce):
            for required in (False, True):
                with self.subTest(module=module.__name__, required=required):
                    output = io.StringIO()
                    arguments = [module.__file__] + (["--required"] if required else [])
                    with patch.object(module, "run", side_effect=module.SkipTest("missing dependency")), \
                            patch.object(sys, "argv", arguments), redirect_stdout(output):
                        result = module.main()
                    self.assertEqual(result, 1 if required else 0)
                    self.assertIn("FAIL:" if required else "SKIP:", output.getvalue())

    def test_invalid_configured_emulator_fails_without_fallback(self):
        for module, variable in ((integration_mame, "MAME_BIN"),
                                 (integration_joyce, "JOYCE_BIN")):
            with self.subTest(module=module.__name__), tempfile.TemporaryDirectory() as directory:
                missing = str(Path(directory) / "missing-emulator")
                with patch.dict(module.os.environ, {variable: missing}), \
                        self.assertRaisesRegex(RuntimeError, "not executable"):
                    module.executable()

    def test_inventory_does_not_walk_unselected_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            allowed = root / "approved.txt"
            allowed.write_text("published\n")
            (root / "local-only.txt").write_text("local fixture\n")
            (root / ".build").mkdir()
            (root / ".build" / "intermediate.txt").write_text("build fixture\n")
            with patch.object(Path, "rglob", side_effect=AssertionError("unexpected traversal")):
                self.assertEqual(publication_files(root, ("approved.txt",)), [allowed])

    def test_inventory_rejects_unsafe_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("../outside", "/outside", "./file", "a//file", "a\\file",
                         ".git/config", ".build/file", "file.sym"):
                with self.subTest(name=name), self.assertRaises(ValueError):
                    publication_files(root, (name,))
            with self.assertRaises(ValueError):
                publication_files(root, ("duplicate", "duplicate"))
            with self.assertRaises(ValueError):
                publication_files(root, ("missing",))

    def test_inventory_rejects_file_and_parent_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "target").mkdir()
            (root / "target" / "file").write_text("fixture\n")
            (root / "linked-file").symlink_to(root / "target" / "file")
            (root / "linked-dir").symlink_to(root / "target", target_is_directory=True)
            for name in ("linked-file", "linked-dir/file"):
                with self.subTest(name=name), self.assertRaisesRegex(ValueError, "symlink"):
                    publication_files(root, (name,))

    def test_inventory_rejects_internal_notes_even_when_explicitly_selected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in (".local/review.md", "docs/decisions/0001-design.md",
                         "docs/.local/review.md", "Docs/Decisions/0001-design.md"):
                with self.subTest(name=name):
                    path = root / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("Internal development note.\n")
                    with self.assertRaisesRegex(ValueError, "invalid publication path"):
                        publication_files(root, (name,))

    def run_trace_command(self, trace):
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(check_traceability, "load_trace", return_value=trace), \
                patch.object(sys, "argv", ["check_traceability.py"]), \
                redirect_stdout(output), redirect_stderr(errors):
            result = check_traceability.main()
        return result, output.getvalue(), errors.getvalue()

    def test_supplemental_documentation_is_reported_by_command(self):
        trace = check_traceability.load_trace()
        component = trace["components"][0]
        component["status"] = "pending documentation"
        component["documentation_note"] = "Add a worked disk-layout example."
        self.assertEqual(check_traceability.documentation_status(trace),
                         ([], [f"{component['id']}: Add a worked disk-layout example."]))
        result, output, errors = self.run_trace_command(trace)
        self.assertEqual((result, errors), (0, ""))
        self.assertIn("supplemental documentation: " + component["id"], output)
        self.assertIn("1 supplemental documentation notes", output)

    def test_incomplete_provenance_blocks_command_despite_supplemental_note(self):
        for state in (None, "pending documentation", "unknown"):
            with self.subTest(provenance_status=state):
                trace = check_traceability.load_trace()
                component = trace["components"][0]
                if state is None:
                    component.pop("provenance_status")
                else:
                    component["provenance_status"] = state
                component["status"] = "pending documentation"
                component["documentation_note"] = "Add a worked disk-layout example."
                result, output, errors = self.run_trace_command(trace)
                self.assertEqual(result, 1)
                self.assertIn("requires provenance_status 'documented'", errors)
                self.assertNotIn("material routines covered", output)

    def test_provenance_record_must_be_selected_document(self):
        for record in (None, "", "../outside.md", "docs/unselected.md", "LICENSE", []):
            with self.subTest(provenance_record=record):
                trace = check_traceability.load_trace()
                trace["components"][0]["provenance_record"] = record
                result, _, errors = self.run_trace_command(trace)
                self.assertEqual(result, 1)
                self.assertIn("needs a provenance_record", errors)

    def test_missing_documentation_status_blocks_command(self):
        trace = check_traceability.load_trace()
        del trace["components"][0]["status"]
        result, _, errors = self.run_trace_command(trace)
        self.assertEqual(result, 1)
        self.assertIn("documentation status", errors)

    def test_invalid_documentation_status_is_rejected(self):
        for fields in ({"status": "pending documentation"},
                       {"status": "pending documentation", "documentation_note": "   "},
                       {"status": "unknown"},
                       {"status": "documented", "documentation_note": "Add an example."}):
            component = dict(fields, id="EXAMPLE", provenance_status="documented")
            with self.subTest(fields=fields):
                errors, _ = check_traceability.documentation_status({"components": [component]})
                self.assertTrue(errors)


if __name__ == "__main__":
    unittest.main()

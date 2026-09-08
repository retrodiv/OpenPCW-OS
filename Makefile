# SPDX-License-Identifier: MIT
# Copyright (c) 2026 retrodiv <retrodiv@proton.me>

PYTHON ?= python3

.PHONY: all dist check check-external clean source-manifest release-evidence

all: dist

dist:
	$(PYTHON) tools/build.py

check:
	$(PYTHON) tools/source_manifest.py --check
	$(PYTHON) tools/build.py --check
	$(PYTHON) tests/check_project.py
	$(PYTHON) tests/test_artifact_contracts.py
	$(PYTHON) tests/test_publication.py
	$(PYTHON) tests/test_entry_state.py
	$(PYTHON) tests/test_fixture_assembly.py
	$(PYTHON) tests/test_reproducible.py
	$(PYTHON) tests/test_comment_invariance.py

check-external:
	$(PYTHON) tests/integration_mame.py --required
	$(PYTHON) tests/integration_joyce.py --required

release-evidence: dist
	$(PYTHON) tests/test_artifact_contracts.py --write-evidence

source-manifest:
	$(PYTHON) tools/source_manifest.py --write

clean:
	$(PYTHON) tools/build.py --clean

# Contributing

Contributions are welcome when their design basis and validation are explicit.

## Source documentation

Each assembly file starts with its architectural role and traceability IDs.
Each material routine resolves to a component contract covering purpose,
inputs, outputs, affected state, memory constraints, design basis, and
validation in `docs/TRACEABILITY.yml` and the generated `docs/ROUTINE_INDEX.md`.
Local comments refine the contract where a routine has narrower requirements.
Small comments explain non-obvious hardware, paging, layout, or compatibility
decisions. Obvious instruction mechanics remain readable as assembly.

Extensive rationale belongs in `docs/` and is referenced through stable IDs.
New public behaviour receives:

1. a `DES-*` design record;
2. an affirmative `REF-*` basis or a clearly identified project design;
3. a `VAL-*` validation;
4. a matching traceability rule or symbol entry.

## Provenance

Describe how each contributed element was designed or obtained. Licensed
third-party material carries its exact licence, upstream revision, path, and
cryptographic hash. Project-authored algorithms reference their design record.
Record factual source references, design notes, authorship, and useful dates;
keep third-party notices intact. Submit work you can distribute under the
project's licence and identify any third-party contribution separately.

Publication requires an established origin and permission to distribute under
the applicable licence. Each component in `docs/TRACEABILITY.yml` explicitly
sets `provenance_status` to `documented` and links its origin and licence record
through `provenance_record`. The record must be a document in the source-release
inventory. Missing or invalid provenance declarations or record links block
`make check`. The checks validate these records as described in
[Design provenance](docs/DESIGN_PROVENANCE.md#source-and-licence-records).

Set the separate documentation `status` explicitly to `documented`. Optional
additions, such as a worked example or a fuller design explanation, may use
`pending documentation` with a concrete `documentation_note`; provenance must
already be documented. The checker reports these supplemental notes. When the
addition is complete, set `status` to `documented` and remove the note.

Add intended source-release files to `SOURCE_NAMES` in `tools/release_files.py`.
This explicit inventory controls the source manifest and temporary source copies.
Keep personal development notes and local review reports under `.local/`.
Published documentation should describe the project and its interfaces;
local notes are excluded from the publication inventory.

## Verification

Run `make check` before proposing a change. The checks cover deterministic
assembly, fixed addresses, disk geometry, traceability, release hashes, and the
binary invariance of source comments.

# Third-party material

## Microsoft MS-DOS 4.0 CP437 display font

| Property | Value |
|---|---|
| Reference | `REF-MSDOS-FONT` |
| Upstream repository | <https://github.com/microsoft/MS-DOS> |
| Commit | `2d04cacc5322951f187bb17e017c12920ac8ebe2` |
| Upstream path | `v4.0/src/DEV/DISPLAY/EGA/437-8X8.ASM` |
| Local path | `third_party/microsoft-msdos/437-8X8.ASM` |
| Source SHA-256 | `9ba690ac66ea37c6afb257a7416fef29a5cf8184936150526de0ad081739f5d7` |
| Licence | Microsoft MIT licence preserved as `third_party/microsoft-msdos/LICENSE` |
| Licence SHA-256 | `b5179f780ec212a434efcc989a2295a140deb0bdb17182d2bf9c5f6f1f1a01c4` |

The upstream references are fixed to the same revision:

- [Font source](https://github.com/microsoft/MS-DOS/blob/2d04cacc5322951f187bb17e017c12920ac8ebe2/v4.0/src/DEV/DISPLAY/EGA/437-8X8.ASM).
- [MIT licence](https://github.com/microsoft/MS-DOS/blob/2d04cacc5322951f187bb17e017c12920ac8ebe2/LICENSE).
- [Repository README and licence scope](https://github.com/microsoft/MS-DOS/blob/2d04cacc5322951f187bb17e017c12920ac8ebe2/README.md).

`tests/check_project.py` verifies the two preserved files against the hashes
above. `docs/RELEASE_EVIDENCE.json` records the local font transformation and
notice-preservation results together with the hashes of their exact inputs.

`tools/build.py` parses all 256 upstream glyphs and selects characters 00h–7Fh.
The PCW runtime table replaces cells 09h, 0Ah, 0Bh, 0Ch, 0Dh, and 7Ch:

- 09h, 0Bh, and 7Ch use Microsoft glyph 1Ah;
- 0Ah uses Microsoft glyph 19h;
- 0Ch and 0Dh use Microsoft glyph 1Bh.

Every runtime glyph is selected unchanged from that same licensed input.
The positional substitutions supply right, down, and left arrows for control
cells; `DES-FONT-001` documents the mapping.

The resulting 1,024 bytes have SHA-256
`f2327dfe38fcf76829086457298e6f8fc7bf569ec80db87412ed77c6526b272b`.
The native disk stores those bytes losslessly as a 64-byte row dictionary plus
four 6-bit indices per three bytes. The startup unpacker reconstructs the same
1,024-byte table.

## Release composition

`OPENPCW.EMS`, `OpenPCW-OS.dsk`, the runtime font, integration metadata, notices,
and the release ZIP are generated from the project sources and licence inputs.
`dist/LICENSES.txt` preserves the complete project and Microsoft MIT notices.
`dist/OpenPCW-OS.zip` packages the four runtime files with those notices.
Their hashes are versioned in `dist/SHA256SUMS` and verified by `make check`.

Binary redistributions, including emulator integrations which embed the disk
or font, must retain the applicable copyright and permission notices.

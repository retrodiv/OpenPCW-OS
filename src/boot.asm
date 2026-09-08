; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Project-authored PCW floppy bootstrap designed from REF-PCW-BOOT and
; REF-PCW-IO. The PCW bootstrap program loads this 512-byte sector at F000h
; and enters it at F010h. See DES-BOOT-001 and VAL-BUILD-LAYOUT.

        org     0f000h

; Public PCW 180K disk specification. OpenPCW-OS currently reserves eight
; tracks for its boot payload; the directory starts after those tracks.
        db      0,0,40,9,2,8,3,2,02ah,052h
        db      0,0,0,0,0,0

boot_entry:
        di
        ld      sp,0fff0h

; Establish the physical 0,1,2,3 mapping used by the PCW bootstrap and copy the
; second stage away from F000h. The second stage must be able to page block 7
; into C000h-FFFFh while it loads the resident kernel there, so it executes
; from block 2 at B000h.
        ld      a,080h
        out     (0f0h),a
        inc     a
        out     (0f1h),a
        inc     a
        out     (0f2h),a
        inc     a
        out     (0f3h),a
        ld      hl,stage2_blob
        ld      de,0b000h
        ld      bc,stage2_blob_end-stage2_blob
        ldir
        jp      0b000h

stage2_blob:
        incbin  "boot_stage2.bin"
stage2_blob_end:

        defs    512-($-0f000h),0

; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Position-stable GENCOM module for the SCR RUN integration probe. Its F00h
; size makes the public downward allocator place it at E100h. The standard
; 27-byte prefix passes every BDOS call to the older chain.  Its callback runs
; entirely in common memory, waits across two 300 Hz interrupts, and verifies
; that SCR RUN maps the PCW screen environment as physical blocks 0, 1, 2, 7:
; B600h must expose the native terminal's 2C98h roller-table first word.

        org     0e100h

        defs    6,0
entry:
        jr      pass
        nop
next_module:
        jp      0000h                   ; replaced by the GENCOM loader
        dw      5                       ; backward link, replaced by loader
        db      0                       ; retain module on warm boot
        db      0
        db      'OPSCRRSX'
        db      0
        dw      0

pass:
        jr      next_module

        defs    0e120h-$,0
screen_callback:
        ei
        halt
        halt
        ld      hl,(0b600h)
        ld      a,l
        cp      098h
        jr      nz,.failure
        ld      a,h
        cp      02ch
        jr      nz,.failure
        xor     a
        jr      .publish
.failure:
        ld      a,0ffh
.publish:
        ld      (0e1e0h),a
        ret

        ; Allocate fifteen pages below the conventional F000h module ceiling.
        defs    0f000h-$,0

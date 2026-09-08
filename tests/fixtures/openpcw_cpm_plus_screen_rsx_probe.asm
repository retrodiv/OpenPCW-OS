; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Attached-RSX/SCR RUN integration probe.  The companion module occupies the
; complete E100h-EFFFh GENCOM allocation and publishes a callback at E120h.
; This transient invokes that callback through the public USERF vector and
; records whether it returned after taking real hardware ticks.

        org     0100h

RESULT                  equ     03800h
RSX_SCREEN_CALLBACK     equ     0e120h
RSX_CALLBACK_RESULT     equ     0e1e0h

start:
        ld      hl,signature
        ld      de,RESULT
        ld      bc,5
        ldir
        ld      a,0ffh
        ld      (RSX_CALLBACK_RESULT),a

        ld      bc,RSX_SCREEN_CALLBACK
        call    0fc5ah                 ; public BIOS USERF vector
        dw      00e9h                  ; SCR RUN ROUTINE

        ld      a,(RSX_CALLBACK_RESULT)
        ld      (RESULT+4),a
.done:
        jr      .done

signature:
        db      'OPSR',0ffh

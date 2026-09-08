; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Record OpenPCW's plain-COM entry state before changing any tested register.
; DES-ENTRY-001. The host checks zero general-purpose registers and SP=F600h.
        org     0100h

RESULT  equ     03800h

entry_probe_start:
        ld      (RESULT+0),bc
        ld      (RESULT+2),de
        ld      (RESULT+4),hl
        ld      (RESULT+6),ix
        ld      (RESULT+8),iy
        ld      (RESULT+10),sp
        push    af
        pop     hl
        ld      (RESULT+12),hl
        exx
        ld      (RESULT+14),bc
        ld      (RESULT+16),de
        ld      (RESULT+18),hl
        ex      af,af'
        push    af
        pop     hl
        ld      (RESULT+20),hl
        ld      a,0aah
        ld      (RESULT+22),a
.done:
        jr      .done

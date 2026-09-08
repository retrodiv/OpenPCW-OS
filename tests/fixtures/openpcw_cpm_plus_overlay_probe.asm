; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; The test harness wraps this transient in a GENCOM header so LOADER remains
; resident, supplies two ordinary physical A: overlays, and verifies that an
; M: overlay survives the nested sparse-record cursor helper used by BDOS 59.
        org     0100h

RESULT          equ     03800h
LOAD_ADDRESS    equ     03000h
RAM_LOAD_ADDRESS equ    03600h

start:
        ld      hl,signature
        ld      de,RESULT
        ld      bc,4
        ldir

        ld      de,overlay_fcb
        ld      c,15                    ; OPEN FILE is required before BDOS 59
        call    0005h
        ld      (RESULT+4),a

        ld      hl,LOAD_ADDRESS
        ld      (overlay_fcb+33),hl     ; r0/r1 are the absolute load address
        ld      de,overlay_fcb
        ld      c,59
        call    0005h
        ld      (RESULT+5),a
        ld      a,h
        ld      (RESULT+6),a

        ld      de,reloc_fcb
        ld      c,15
        call    0005h
        ld      (RESULT+7),a
        ld      hl,03400h               ; PRL loads must be page-aligned
        ld      (reloc_fcb+33),hl
        ld      de,reloc_fcb
        ld      c,59
        call    0005h
        ld      (RESULT+8),a
        ld      a,h
        ld      (RESULT+9),a

        ld      de,ram_overlay_fcb
        ld      c,22                    ; create and activate M:RAMOVR.BIN
        call    0005h
        ld      (RESULT+10),a

        ld      de,ram_overlay_payload
        ld      c,26                    ; DMA for the sparse record write
        call    0005h
        ld      de,ram_overlay_fcb
        ld      c,34                    ; random record zero
        call    0005h
        ld      (RESULT+11),a

        ld      hl,RAM_LOAD_ADDRESS
        ld      (ram_overlay_fcb+33),hl
        ld      de,ram_overlay_fcb
        ld      c,59
        call    0005h
        ld      (RESULT+12),a
        ld      a,h
        ld      (RESULT+13),a
.done:
        jr      .done

signature:
        db      'FOVL'
overlay_fcb:
        db      1                       ; explicit physical A:
        db      'OVERLAY BIN'
        defs    24,0
reloc_fcb:
        db      1
        db      'RELOC   PRL'
        defs    24,0
ram_overlay_fcb:
        db      13                      ; explicit volatile M:
        db      'RAMOVR  BIN'
        defs    24,0
ram_overlay_payload:
        db      'F59M'
        defs    124,05ah

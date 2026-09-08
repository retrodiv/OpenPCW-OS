; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; GENCOM loader-boundary probe. A protected-file FCB is deliberately placed at
; F5BEh, immediately below the standard 32-byte entry-stack window.
; Several hardware ticks must leave it intact before BDOS 59 loads the opened
; absolute overlay at 3600h. This proves that the resident interrupt stack is
; disjoint from both the public GENCOM entry stack and its adjacent loader FCB.

        org     0100h

RESULT          equ     03700h
LOADER_FCB      equ     0f5beh
OVERLAY_TARGET  equ     03600h

start:
        ld      hl,result_initial
        ld      de,RESULT
        ld      bc,8
        ldir

        ld      hl,target_fcb
        ld      de,LOADER_FCB
        ld      bc,36
        ldir

        ld      de,LOADER_FCB
        ld      c,15                    ; OPEN FILE
        call    0005h
        inc     a
        jr      z,.failure

        ; Let the 300 Hz PCW ticker exercise its complete private register
        ; frame while the activated loader FCB remains at the boundary.
        ld      b,16
        ei
.wait_tick:
        halt
        djnz    .wait_tick

        ; OPEN may publish high attribute bits, but drive and low seven name
        ; bits must still identify the selected physical file.
        ld      a,(LOADER_FCB)
        or      a
        jr      nz,.failure
        ld      hl,LOADER_FCB+1
        ld      de,target_name
        ld      b,11
.name_byte:
        ld      a,(hl)
        and     07fh
        ld      c,a
        ld      a,(de)
        cp      c
        jr      nz,.failure
        inc     hl
        inc     de
        djnz    .name_byte

        ld      de,LOADER_FCB
        ld      c,59                    ; LOAD OVERLAY
        call    0005h
        or      a
        jr      nz,.failure

        ld      hl,OVERLAY_TARGET
        ld      de,overlay_marker
        ld      b,4
.overlay_byte:
        ld      a,(de)
        cp      (hl)
        jr      nz,.failure
        inc     hl
        inc     de
        djnz    .overlay_byte
        xor     a
        jr      .publish
.failure:
        ld      a,0ffh
.publish:
        ld      (RESULT+4),a
.done:
        jr      .done

result_initial:
        db      'OPGO'
        defs    4,0ffh

target_fcb:
        db      0
target_name:
        db      'OVERLAY BIN'
        defs    21,0
        db      0                       ; R0: absolute load address low
        db      036h                    ; R1: absolute load address high
        db      0                       ; R2

overlay_marker:
        db      'OPOV'

; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Black-box distinction between BDOS 11 and Direct Console status, including
; the CTRL-C-only policy selected by Console Mode bit zero.
        org     0100h

RESULT          equ     03800h

start:
        ld      hl,signature
        ld      de,RESULT
        ld      bc,4
        ldir
        ld      a,010h
        ld      (RESULT+13),a

        ; Discard the RETURN release used to launch this command.
.wait_release:
        ld      c,6
        ld      e,0feh
        call    0005h
        or      a
        jr      nz,.wait_release
        ld      a,011h
        ld      (RESULT+13),a

        ld      de,1
        ld      c,109                   ; CTRL-C-only Function 11 status
        call    0005h
        ld      a,012h
        ld      (RESULT+13),a

        ; A normal X remains pending, but Function 11 must report false.
.wait_x:
        ld      c,6
        ld      e,0feh
        call    0005h
        or      a
        jr      z,.wait_x
        ld      (RESULT+5),a            ; Direct status is FFh
        ld      a,013h
        ld      (RESULT+13),a
        ld      c,11
        call    0005h
        ld      (RESULT+4),a            ; filtered status is 00h
        ld      c,6
        ld      e,0ffh
        call    0005h
        ld      (RESULT+6),a
        ld      a,014h
        ld      (RESULT+13),a

        ; STOP is the PCW's CTRL-C key. Function 11 returns exactly 01h and
        ; does not consume it.
.wait_control_c:
        ld      c,11
        call    0005h
        or      a
        jr      z,.wait_control_c
        ld      (RESULT+7),a
        ld      c,6
        ld      e,0ffh
        call    0005h
        ld      (RESULT+8),a
        ld      a,015h
        ld      (RESULT+13),a

        ld      de,0
        ld      c,109                   ; restore normal console status
        call    0005h
.wait_z:
        ld      c,11
        call    0005h
        or      a
        jr      z,.wait_z
        ld      (RESULT+9),a
        ld      c,6
        ld      e,0ffh
        call    0005h
        ld      (RESULT+10),a

        ld      de,0ffffh
        ld      c,109
        call    0005h
        ld      (RESULT+11),hl
        ld      a,016h
        ld      (RESULT+13),a
.done:
        jr      .done

signature:
        db      'FCS1'

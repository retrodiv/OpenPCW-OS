; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Black-box CP/M Plus Function 46 physical-allocation probe. MAKE consumes no
; data block, writes to records 0 and 17 consume two independent 1 KiB blocks,
; and DELETE releases both.
        org     0100h

RESULT          equ     03800h
FREEBUF         equ     03600h
WRITEBUF        equ     03400h

start:
        ld      hl,signature
        ld      de,RESULT
        ld      bc,4
        ldir
        ld      ix,RESULT+4

        ld      e,0ffh
        ld      c,45
        call    0005h
        ld      e,0
        ld      c,14
        call    0005h
        ld      (ix+0),a

        ld      hl,RESULT+5
        call    get_free_a
        ld      de,file_fcb
        ld      c,22
        call    0005h
        ld      (ix+6),a
        ld      hl,RESULT+11
        call    get_free_a

        ld      hl,WRITEBUF
        ld      de,WRITEBUF+1
        ld      (hl),05ah
        ld      bc,127
        ldir
        ld      de,WRITEBUF
        ld      c,26
        call    0005h
        ld      de,file_fcb
        ld      c,21                    ; record 0: first allocation block
        call    0005h
        ld      (ix+12),a
        ld      hl,RESULT+17
        call    get_free_a

        ld      a,17
        ld      (file_fcb+33),a
        xor     a
        ld      (file_fcb+34),a
        ld      (file_fcb+35),a
        ld      de,file_fcb
        ld      c,34                    ; record 17: second allocation block
        call    0005h
        ld      (ix+18),a
        ld      hl,RESULT+23
        call    get_free_a

        ld      de,delete_fcb
        ld      c,19
        call    0005h
        ld      (ix+24),a
        ld      hl,RESULT+29
        call    get_free_a
.done:
        jr      .done

; HL points to five result bytes: A, H and little-endian 24-bit free records.
get_free_a:
        push    hl
        ld      de,FREEBUF
        ld      c,26
        call    0005h
        ld      e,0
        ld      c,46
        call    0005h
        pop     de
        ld      (de),a
        inc     de
        ld      a,h
        ld      (de),a
        inc     de
        ld      hl,FREEBUF
        ld      bc,3
        ldir
        ret

signature:      db      'FFS1'
file_fcb:       db      1,'FREESP  BIN'
                defs    24,0
delete_fcb:     db      1,'FREESP  BIN'
                defs    24,0

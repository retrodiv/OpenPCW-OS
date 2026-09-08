; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Black-box CP/M Plus Function 33 logical-error probe.  A missing record in an
; existing extent returns 1; a requested extent with no directory entry returns
; 4. Physical A: also contains a later sparse extent to prove successful seek.
        org     0100h

RESULT          equ     03800h
DMA             equ     03000h

start:
        ld      hl,signature
        ld      de,RESULT
        ld      bc,4
        ldir
        ld      ix,RESULT+4

        ld      e,0ffh
        ld      c,45                    ; return errors
        call    0005h
        ld      de,DMA
        ld      c,26
        call    0005h
        ld      e,1
        ld      c,44
        call    0005h
        ld      e,0
        ld      c,14                    ; physical A:
        call    0005h
        ld      de,fcb_a
        ld      c,15
        call    0005h
        ld      (ix+0),a

        ld      hl,fcb_a
        ld      de,1
        call    set_random_16
        ld      de,fcb_a
        ld      c,33
        call    0005h
        ld      (ix+1),a
        ld      a,h
        ld      (ix+2),a
        call    store_a_position_3

        ld      hl,fcb_a
        ld      de,128
        call    set_random_16
        ld      de,fcb_a
        ld      c,33
        call    0005h
        ld      (ix+6),a
        ld      a,h
        ld      (ix+7),a
        call    store_a_position_8

        call    clear_dma
        ld      hl,fcb_a
        ld      de,256
        call    set_random_16
        ld      de,fcb_a
        ld      c,33
        call    0005h
        ld      (ix+11),a
        ld      a,h
        ld      (ix+12),a
        call    store_a_position_13
        ld      a,(DMA)
        cp      0c2h
        call    check_c2
        ld      (ix+16),a

        ld      e,12
        ld      c,14                    ; volatile M:
        call    0005h
        ld      de,fcb_m
        ld      c,22
        call    0005h
        ld      (ix+17),a
        ld      hl,DMA
        ld      a,05dh
        call    fill_record
        ld      hl,fcb_m
        ld      de,0
        call    set_random_16
        ld      de,fcb_m
        ld      c,34
        call    0005h
        ld      (ix+18),a
        ld      a,h
        ld      (ix+19),a

        ld      hl,fcb_m
        ld      de,1
        call    set_random_16
        ld      de,fcb_m
        ld      c,33
        call    0005h
        ld      (ix+20),a
        ld      a,h
        ld      (ix+21),a
        ld      a,(fcb_m+12)
        ld      (ix+22),a
        ld      a,(fcb_m+32)
        ld      (ix+23),a

        ld      hl,fcb_m
        ld      de,256
        call    set_random_16
        ld      de,fcb_m
        ld      c,33
        call    0005h
        ld      (ix+24),a
        ld      a,h
        ld      (ix+25),a
        ld      a,(fcb_m+12)
        ld      (ix+26),a
        ld      a,(fcb_m+32)
        ld      (ix+27),a

        call    clear_dma
        ld      hl,fcb_m
        ld      de,0
        call    set_random_16
        ld      de,fcb_m
        ld      c,33
        call    0005h
        ld      (ix+28),a
        ld      a,h
        ld      (ix+29),a
        ld      a,(DMA)
        cp      05dh
        call    check_5d
        ld      (ix+30),a
.done:
        jr      .done

; HL=FCB, DE=16-bit random record; clear R2.
set_random_16:
        ld      bc,33
        add     hl,bc
        ld      (hl),e
        inc     hl
        ld      (hl),d
        inc     hl
        ld      (hl),0
        ret

store_a_position_3:
        ld      a,(fcb_a+12)
        ld      (ix+3),a
        ld      a,(fcb_a+14)
        ld      (ix+4),a
        ld      a,(fcb_a+32)
        ld      (ix+5),a
        ret
store_a_position_8:
        ld      a,(fcb_a+12)
        ld      (ix+8),a
        ld      a,(fcb_a+14)
        ld      (ix+9),a
        ld      a,(fcb_a+32)
        ld      (ix+10),a
        ret
store_a_position_13:
        ld      a,(fcb_a+12)
        ld      (ix+13),a
        ld      a,(fcb_a+14)
        ld      (ix+14),a
        ld      a,(fcb_a+32)
        ld      (ix+15),a
        ret

clear_dma:
        ld      hl,DMA
        xor     a
fill_record:
        ld      (hl),a
        push    hl
        pop     de
        inc     de
        ld      bc,127
        ldir
        ret

check_c2:
        jr      nz,set_bad
        xor     a
        ret
check_5d:
        jr      nz,set_bad
        xor     a
        ret
set_bad:
        ld      a,1
        ret

signature:      db      'FRE1'
fcb_a:          db      1,'SPARSE  BIN'
                defs    24,0
fcb_m:          db      13,'SPARSE  BIN'
                defs    24,0

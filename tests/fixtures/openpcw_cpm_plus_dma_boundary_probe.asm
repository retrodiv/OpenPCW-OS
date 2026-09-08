; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Black-box CP/M Plus Function 26 probe.  A two-record transfer beginning at
; 3F80h must place its second record at 4000h, across the PCW's 16 KiB paging
; boundary.  Exercise physical A: reads and volatile M: writes/reads through
; both sequential and random BDOS paths.
        org     0100h

RESULT          equ     03800h
DMA             equ     03f80h

start:
        ld      hl,signature
        ld      de,RESULT
        ld      bc,4
        ldir
        ld      ix,RESULT+4

        ld      e,0ffh
        ld      c,45                    ; return errors to the caller
        call    0005h
        ld      e,0
        ld      c,14                    ; physical A:
        call    0005h

        ld      de,fcb_a
        ld      c,15
        call    0005h
        ld      (ix+0),a
        call    reset_fcb_a
        call    set_boundary_dma
        ld      de,fcb_a
        ld      c,20                    ; two sequential records across 4000h
        call    0005h
        ld      (ix+1),a
        ld      a,h
        ld      (ix+2),a
        ld      a,(fcb_a+32)
        ld      (ix+3),a
        call    check_a_pattern
        ld      (ix+4),a

        call    reset_fcb_a
        call    clear_boundary_dma
        call    set_boundary_dma
        ld      de,fcb_a
        ld      c,33                    ; random multirecord read, R0 restored
        call    0005h
        ld      (ix+5),a
        ld      a,h
        ld      (ix+6),a
        ld      a,(fcb_a+12)
        ld      (ix+7),a
        ld      a,(fcb_a+14)
        ld      (ix+8),a
        ld      a,(fcb_a+32)
        ld      (ix+9),a
        ld      a,(fcb_a+33)
        ld      (ix+10),a
        call    check_a_pattern
        ld      (ix+11),a

        ld      e,12
        ld      c,14                    ; volatile M:
        call    0005h
        ld      de,fcb_m
        ld      c,22
        call    0005h
        ld      (ix+12),a
        call    fill_m_pattern
        call    set_boundary_dma
        ld      de,fcb_m
        ld      c,21                    ; source crosses 3FFFh/4000h
        call    0005h
        ld      (ix+13),a
        ld      a,h
        ld      (ix+14),a
        ld      a,(fcb_m+32)
        ld      (ix+15),a

        call    reset_fcb_m
        ld      de,fcb_m
        ld      c,15
        call    0005h
        ld      (ix+16),a
        call    clear_boundary_dma
        call    set_boundary_dma
        ld      de,fcb_m
        ld      c,20                    ; destination crosses 3FFFh/4000h
        call    0005h
        ld      (ix+17),a
        ld      a,h
        ld      (ix+18),a
        ld      a,(fcb_m+32)
        ld      (ix+19),a
        call    check_m_pattern
        ld      (ix+20),a

        call    reset_fcb_m
        call    clear_boundary_dma
        call    set_boundary_dma
        ld      de,fcb_m
        ld      c,33
        call    0005h
        ld      (ix+21),a
        ld      a,h
        ld      (ix+22),a
        ld      a,(fcb_m+12)
        ld      (ix+23),a
        ld      a,(fcb_m+14)
        ld      (ix+24),a
        ld      a,(fcb_m+32)
        ld      (ix+25),a
        ld      a,(fcb_m+33)
        ld      (ix+26),a
        call    check_m_pattern
        ld      (ix+27),a
.done:
        jr      .done

set_boundary_dma:
        ld      de,DMA
        ld      c,26
        call    0005h
        ld      e,2
        ld      c,44
        jp      0005h

reset_fcb_a:
        ld      hl,fcb_a+12
        jr      reset_fcb_position
reset_fcb_m:
        ld      hl,fcb_m+12
reset_fcb_position:
        xor     a
        ld      b,4                     ; EX, S1, S2 and RC
.extent:
        ld      (hl),a
        inc     hl
        djnz    .extent
        ld      de,16
        add     hl,de
        ld      (hl),a                  ; CR
        inc     hl
        ld      (hl),a                  ; R0
        inc     hl
        ld      (hl),a                  ; R1
        inc     hl
        ld      (hl),a                  ; R2
        ret

clear_boundary_dma:
        ld      hl,DMA
        ld      de,DMA+1
        xor     a
        ld      (hl),a
        ld      bc,255
        ldir
        ret

fill_m_pattern:
        ld      hl,DMA
        ld      b,128
        ld      a,03ch
.first:
        ld      (hl),a
        inc     hl
        djnz    .first
        ld      b,128
        ld      a,0c3h
.second:
        ld      (hl),a
        inc     hl
        djnz    .second
        ret

check_a_pattern:
        ld      hl,DMA
        ld      b,128
        ld      a,0a5h
        call    check_run
        ret     nz
        ld      b,128
        ld      a,05ah
        call    check_run
        ret     nz
        xor     a
        ret

check_m_pattern:
        ld      hl,DMA
        ld      b,128
        ld      a,03ch
        call    check_run
        ret     nz
        ld      b,128
        ld      a,0c3h
        call    check_run
        ret     nz
        xor     a
        ret

; A=expected, HL=first byte, B=count. Return NZ/A=1 at first mismatch.
check_run:
        cp      (hl)
        jr      nz,.bad
        inc     hl
        djnz    check_run
        xor     a
        ret
.bad:
        ld      a,1
        or      a
        ret

signature:      db      'FDB1'
fcb_a:          db      1,'BOUND   BIN'
                defs    24,0
fcb_m:          db      13,'BOUND   BIN'
                defs    24,0

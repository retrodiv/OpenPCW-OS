; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Black-box CP/M Plus multisector completion-count probe.  Logical I/O errors
; return in H the number of 128-byte records completed before the failure.
        org     0100h

RESULT          equ     03800h
DMA_A           equ     03000h
DMA_M           equ     03400h
DMA_LARGE       equ     04000h

start:
        ld      hl,signature
        ld      de,RESULT
        ld      bc,4
        ldir
        ld      ix,RESULT+4

        ld      e,0ffh
        ld      c,45                    ; return physical/logical errors
        call    0005h
        ld      e,0
        ld      c,14                    ; select physical A:
        call    0005h

        ld      de,fcb_a
        ld      c,15
        call    0005h
        ld      (ix+0),a
        ld      de,DMA_A
        ld      c,26
        call    0005h
        ld      e,2
        ld      c,44
        call    0005h
        ld      de,fcb_a
        ld      c,20                    ; exactly two records: success
        call    0005h
        ld      (ix+1),a
        ld      a,h
        ld      (ix+2),a
        ld      a,(fcb_a+32)
        ld      (ix+3),a

        call    reset_fcb_a
        ld      de,fcb_a
        ld      c,15
        call    0005h
        ld      (ix+4),a
        ld      de,DMA_A
        ld      c,26
        call    0005h
        ld      e,3
        ld      c,44
        call    0005h
        ld      de,fcb_a
        ld      c,20                    ; EOF after two of three records
        call    0005h
        ld      (ix+5),a
        ld      a,h
        ld      (ix+6),a
        ld      a,(fcb_a+32)
        ld      (ix+7),a

        call    reset_fcb_a
        ld      de,fcb_a
        ld      c,15
        call    0005h
        ld      (ix+16),a
        ld      a,1
        ld      (fcb_a+33),a
        xor     a
        ld      (fcb_a+34),a
        ld      (fcb_a+35),a
        ld      de,DMA_A
        ld      c,26
        call    0005h
        ld      e,3
        ld      c,44
        call    0005h
        ld      de,fcb_a
        ld      c,33                    ; random record 1, then EOF
        call    0005h
        ld      (ix+17),a
        ld      a,h
        ld      (ix+18),a
        ld      a,(fcb_a+12)
        ld      (ix+19),a
        ld      a,(fcb_a+14)
        ld      (ix+20),a
        ld      a,(fcb_a+32)
        ld      (ix+21),a
        ld      a,(fcb_a+33)
        ld      (ix+22),a

        ld      e,12
        ld      c,14                    ; select volatile M:
        call    0005h
        ld      de,fcb_m
        ld      c,22
        call    0005h
        ld      (ix+8),a
        call    fill_m_dma
        ld      de,DMA_M
        ld      c,26
        call    0005h
        ld      e,2
        ld      c,44
        call    0005h
        ld      de,fcb_m
        ld      c,21                    ; create two records in one call
        call    0005h
        ld      (ix+9),a
        ld      a,h
        ld      (ix+10),a
        ld      a,(fcb_m+32)
        ld      (ix+11),a

        call    reset_fcb_m
        ld      de,fcb_m
        ld      c,15
        call    0005h
        ld      (ix+12),a
        ld      de,DMA_M
        ld      c,26
        call    0005h
        ld      e,3
        ld      c,44
        call    0005h
        ld      de,fcb_m
        ld      c,20                    ; EOF after two of three records
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
        ld      (ix+23),a
        ld      a,1
        ld      (fcb_m+33),a
        xor     a
        ld      (fcb_m+34),a
        ld      (fcb_m+35),a
        ld      de,DMA_M
        ld      c,26
        call    0005h
        ld      e,3
        ld      c,44
        call    0005h
        ld      de,fcb_m
        ld      c,33                    ; random record 1, then EOF
        call    0005h
        ld      (ix+24),a
        ld      a,h
        ld      (ix+25),a
        ld      a,(fcb_m+12)
        ld      (ix+26),a
        ld      a,(fcb_m+14)
        ld      (ix+27),a
        ld      a,(fcb_m+32)
        ld      (ix+28),a
        ld      a,(fcb_m+33)
        ld      (ix+29),a

        ld      e,1
        ld      c,44
        call    0005h
        ld      hl,fcb_a
        call    set_random_out_of_range
        ld      de,fcb_a
        ld      c,33
        call    0005h
        ld      (ix+30),a
        ld      a,h
        ld      (ix+31),a
        ld      de,fcb_a
        ld      c,34
        call    0005h
        ld      (ix+32),a
        ld      a,h
        ld      (ix+33),a
        ld      de,fcb_a
        ld      c,40
        call    0005h
        ld      (ix+34),a
        ld      a,h
        ld      (ix+35),a

        ld      hl,fcb_m
        call    set_random_out_of_range
        ld      de,fcb_m
        ld      c,33
        call    0005h
        ld      (ix+36),a
        ld      a,h
        ld      (ix+37),a
        ld      de,fcb_m
        ld      c,34
        call    0005h
        ld      (ix+38),a
        ld      a,h
        ld      (ix+39),a
        ld      de,fcb_m
        ld      c,40
        call    0005h
        ld      (ix+40),a
        ld      a,h
        ld      (ix+41),a

        ; Exercise a complete 128-record CP/M Plus request and its deferred
        ; extent boundary. This is the loader pattern used by large banked
        ; applications: the public cursor must reach CP/M's deferred extent
        ; boundary rather than advancing by only one record.
        ld      e,0
        ld      c,14
        call    0005h
        ld      de,fcb_large
        ld      c,15
        call    0005h
        ld      (ix+42),a
        ld      de,DMA_LARGE
        ld      c,26
        call    0005h
        ld      e,128
        ld      c,44
        call    0005h
        ld      de,fcb_large
        ld      c,20
        call    0005h
        ld      (ix+43),a
        ld      a,h
        ld      (ix+44),a
        ld      a,(fcb_large+12)
        ld      (ix+45),a
        ld      a,(fcb_large+14)
        ld      (ix+46),a
        ld      a,(fcb_large+32)
        ld      (ix+47),a

.done:
        jr      .done

set_random_out_of_range:
        ld      de,33
        add     hl,de
        xor     a
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),4
        ret

reset_fcb_a:
        ld      hl,fcb_a+12
        jr      reset_fcb_position
reset_fcb_m:
        ld      hl,fcb_m+12
reset_fcb_position:
        xor     a
        ld      b,4
.extent:
        ld      (hl),a
        inc     hl
        djnz    .extent
        ld      de,16
        add     hl,de
        ld      (hl),a                  ; clear CR at FCB+32
        ret

fill_m_dma:
        ld      hl,DMA_M
        ld      de,DMA_M+1
        ld      (hl),05ah
        ld      bc,255
        ldir
        ret

signature:      db      'FMS1'
fcb_a:          db      1,'MULTI   BIN'
                defs    24,0
fcb_m:          db      13,'MSTEST  BIN'
                defs    24,0
fcb_large:      db      1,'LARGE   BIN'
                defs    24,0

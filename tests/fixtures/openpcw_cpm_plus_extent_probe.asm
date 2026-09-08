; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Black-box CP/M Plus sequential-extent and per-FCB cursor probe.  A two-record
; read beginning at record 127 must cross EX=0/CR=127 to EX=1/CR=1. Two FCBs
; for the same file are then interleaved to prove that no process-global file
; cursor leaks between them. Exercise physical A: and volatile M:.
        org     0100h

RESULT          equ     03800h
DMA             equ     03000h
BIG_DMA         equ     04000h

start:
        ld      hl,signature
        ld      de,RESULT
        ld      bc,4
        ldir
        ld      ix,RESULT+4

        ld      e,0ffh
        ld      c,45                    ; return errors
        call    0005h
        ld      e,0
        ld      c,14                    ; physical A:
        call    0005h

        ld      de,fcb_a1
        ld      c,15
        call    0005h
        ld      (ix+0),a
        ld      hl,fcb_a1
        call    set_position_127
        ld      de,DMA
        ld      c,26
        call    0005h
        ld      e,2
        ld      c,44
        call    0005h
        ld      de,fcb_a1
        ld      c,20
        call    0005h
        ld      (ix+1),a
        ld      a,h
        ld      (ix+2),a
        ld      a,(fcb_a1+12)
        ld      (ix+3),a
        ld      a,(fcb_a1+14)
        ld      (ix+4),a
        ld      a,(fcb_a1+32)
        ld      (ix+5),a
        call    check_cross_pattern
        ld      (ix+6),a

        ld      hl,fcb_a1
        call    reset_fcb_position
        ld      de,fcb_a1
        ld      c,15
        call    0005h
        ld      (ix+7),a
        ld      hl,fcb_a2
        call    reset_fcb_position
        ld      de,fcb_a2
        ld      c,15
        call    0005h
        ld      (ix+8),a

        ld      hl,fcb_a1
        call    set_position_127
        ld      de,DMA
        call    read_one
        ld      (ix+9),a
        ld      a,(DMA)
        call    check_7f
        ld      (ix+10),a
        ld      a,(fcb_a1+12)
        ld      (ix+11),a
        ld      a,(fcb_a1+32)
        ld      (ix+12),a

        ld      hl,fcb_a2
        call    set_position_0
        ld      de,DMA+128
        call    read_one
        ld      (ix+13),a
        ld      a,(DMA+128)
        or      a
        call    nz,set_bad
        ld      (ix+14),a
        ld      a,(fcb_a2+12)
        ld      (ix+15),a
        ld      a,(fcb_a2+32)
        ld      (ix+16),a

        ld      de,DMA+256
        ld      hl,fcb_a1
        call    read_one_hl
        ld      (ix+17),a
        ld      a,(DMA+256)
        call    check_80
        ld      (ix+18),a
        ld      a,(fcb_a1+12)
        ld      (ix+19),a
        ld      a,(fcb_a1+32)
        ld      (ix+20),a

        ld      e,12
        ld      c,14                    ; volatile M:
        call    0005h
        ld      de,fcb_m1
        ld      c,22
        call    0005h
        ld      (ix+21),a
        call    fill_128_records
        ld      de,BIG_DMA
        ld      c,26
        call    0005h
        ld      e,128
        ld      c,44
        call    0005h
        ld      de,fcb_m1
        ld      c,21
        call    0005h
        ld      (ix+22),a
        ld      a,h
        ld      (ix+23),a
        ld      a,(fcb_m1+12)
        ld      (ix+24),a
        ld      a,(fcb_m1+32)
        ld      (ix+25),a

        ld      hl,DMA
        ld      a,080h
        call    fill_one_record
        ld      de,DMA
        ld      c,26
        call    0005h
        ld      e,1
        ld      c,44
        call    0005h
        ld      de,fcb_m1
        ld      c,21
        call    0005h
        ld      (ix+26),a
        ld      a,h
        ld      (ix+27),a
        ld      a,(fcb_m1+12)
        ld      (ix+28),a
        ld      a,(fcb_m1+32)
        ld      (ix+29),a

        ld      hl,fcb_m1
        call    reset_fcb_position
        ld      de,fcb_m1
        ld      c,15
        call    0005h
        ld      (ix+30),a
        ld      hl,fcb_m1
        call    set_position_127
        ld      de,DMA
        ld      c,26
        call    0005h
        ld      e,2
        ld      c,44
        call    0005h
        ld      de,fcb_m1
        ld      c,20
        call    0005h
        ld      (ix+31),a
        ld      a,h
        ld      (ix+32),a
        ld      a,(fcb_m1+12)
        ld      (ix+33),a
        ld      a,(fcb_m1+14)
        ld      (ix+34),a
        ld      a,(fcb_m1+32)
        ld      (ix+35),a
        call    check_cross_pattern
        ld      (ix+36),a

        ld      hl,fcb_m1
        call    reset_fcb_position
        ld      de,fcb_m1
        ld      c,15
        call    0005h
        ld      (ix+37),a
        ld      hl,fcb_m2
        call    reset_fcb_position
        ld      de,fcb_m2
        ld      c,15
        call    0005h
        ld      (ix+38),a

        ld      hl,fcb_m1
        call    set_position_127
        ld      de,DMA
        call    read_one
        ld      (ix+39),a
        ld      a,(DMA)
        call    check_7f
        ld      (ix+40),a
        ld      a,(fcb_m1+12)
        ld      (ix+41),a
        ld      a,(fcb_m1+32)
        ld      (ix+42),a

        ld      hl,fcb_m2
        call    set_position_0
        ld      de,DMA+128
        call    read_one
        ld      (ix+43),a
        ld      a,(DMA+128)
        or      a
        call    nz,set_bad
        ld      (ix+44),a
        ld      a,(fcb_m2+12)
        ld      (ix+45),a
        ld      a,(fcb_m2+32)
        ld      (ix+46),a

        ld      de,DMA+256
        ld      hl,fcb_m1
        call    read_one_hl
        ld      (ix+47),a
        ld      a,(DMA+256)
        call    check_80
        ld      (ix+48),a
        ld      a,(fcb_m1+12)
        ld      (ix+49),a
        ld      a,(fcb_m1+32)
        ld      (ix+50),a
.done:
        jr      .done

; HL=FCB, DE=DMA. This entry preserves the caller's FCB in HL until it has
; installed the DMA and then performs a one-record sequential read.
read_one:
read_one_hl:
        push    hl
        push    de
        ld      c,26
        call    0005h
        ld      e,1
        ld      c,44
        call    0005h
        pop     de                      ; discard saved DMA
        pop     de                      ; FCB
        ld      c,20
        jp      0005h

set_position_127:
        call    set_position_0
        push    hl
        ld      de,32
        add     hl,de
        ld      (hl),127
        pop     hl
        ret

set_position_0:
reset_fcb_position:
        push    hl
        ld      de,12
        add     hl,de
        xor     a
        ld      b,4
.extent:
        ld      (hl),a
        inc     hl
        djnz    .extent
        ld      de,16
        add     hl,de
        ld      b,4
.record:
        ld      (hl),a
        inc     hl
        djnz    .record
        pop     hl
        ret

check_cross_pattern:
        ld      a,(DMA)
        cp      07fh
        jr      nz,set_bad
        ld      a,(DMA+127)
        cp      07fh
        jr      nz,set_bad
        ld      a,(DMA+128)
        cp      080h
        jr      nz,set_bad
        ld      a,(DMA+255)
        cp      080h
        jr      nz,set_bad
        xor     a
        ret
check_7f:
        cp      07fh
        jr      nz,set_bad
        xor     a
        ret
check_80:
        cp      080h
        jr      nz,set_bad
        xor     a
        ret
set_bad:
        ld      a,1
        ret

; Fill 4000h..7FFFh with 128 records whose byte value is their record index.
fill_128_records:
        ld      hl,BIG_DMA
        xor     a
        ld      (fill_value),a
        ld      a,128
        ld      (fill_left),a
.next:
        ld      a,(fill_value)
        ld      (hl),a
        push    hl
        pop     de
        inc     de
        ld      bc,127
        ldir
        ex      de,hl                   ; next 128-byte record
        ld      a,(fill_value)
        inc     a
        ld      (fill_value),a
        ld      a,(fill_left)
        dec     a
        ld      (fill_left),a
        jr      nz,.next
        ret

; A=value, HL=record start.
fill_one_record:
        ld      (hl),a
        push    hl
        pop     de
        inc     de
        ld      bc,127
        ldir
        ret

signature:      db      'FEX1'
fill_value:     db      0
fill_left:      db      0
fcb_a1:         db      1,'EXTENT  BIN'
                defs    24,0
fcb_a2:         db      1,'EXTENT  BIN'
                defs    24,0
fcb_m1:         db      13,'EXTENT  BIN'
                defs    24,0
fcb_m2:         db      13,'EXTENT  BIN'
                defs    24,0

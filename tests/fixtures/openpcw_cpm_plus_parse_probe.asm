; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Black-box CP/M Plus Function 152 probe. Results are left at 3200h.

        org     0100h

start:
        ld      sp,4000h
        ld      hl,result_marker
        ld      de,3200h
        ld      bc,4
        ldir

        ld      de,pfcb1
        ld      c,152
        call    0005h
        ld      de,input1
        or      a
        sbc     hl,de
        ld      (3204h),hl
        ld      hl,fcb1
        ld      de,3206h
        ld      bc,36
        ldir

        ld      de,pfcb2
        ld      c,152
        call    0005h
        ld      (322ah),hl
        ld      hl,fcb2
        ld      de,322ch
        ld      bc,36
        ldir

        ld      de,pfcb3
        ld      c,152
        call    0005h
        ld      de,input3
        or      a
        sbc     hl,de
        ld      (3250h),hl
        ld      hl,fcb3
        ld      de,3252h
        ld      bc,36
        ldir

        ld      de,pfcb4
        ld      c,152
        call    0005h
        ld      (3276h),hl
        ld      de,pfcb5
        ld      c,152
        call    0005h
        ld      (3278h),hl
        ld      de,pfcb6
        ld      c,152
        call    0005h
        ld      (327ah),hl
        ld      de,pfcb7
        ld      c,152
        call    0005h
        ld      (327ch),hl

        ld      a,0aah
        ld      (327eh),a
.hang:
        jr      .hang

result_marker:
        db      'OPPF'

pfcb1:  dw input1,fcb1
pfcb2:  dw input2,fcb2
pfcb3:  dw input3,fcb3
pfcb4:  dw input4,fcb4
pfcb5:  dw input5,fcb5
pfcb6:  dw input6,fcb6
pfcb7:  dw input7,fcb7

input1: db ' ',9,'m:foo*.b*;secret next',0
input2: db 'A:',13
input3: db 'thing.dat,tail',0
input4: db '123456789.COM',0
input5: db 'BAD',1,0
input6: defs 128,' '
        db 0
input7: db ' ',9,13

fcb1:   defs 36,0cch
fcb2:   defs 36,0cch
fcb3:   defs 36,0cch
fcb4:   defs 36,0cch
fcb5:   defs 36,0cch
fcb6:   defs 36,0cch
fcb7:   defs 36,0cch

; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Black-box CP/M Plus Functions 17/18 probe. Results are left at 3300h.

        org     0100h

start:
        ld      sp,4000h
        ld      hl,result_marker
        ld      de,3300h
        ld      bc,4
        ldir
        ld      de,dma_buffer
        ld      c,26
        call    0005h
        xor     a
        ld      (330fh),a

        ld      de,physical_fcb
        ld      c,17
        call    0005h
        ld      (3304h),a
        ld      hl,dma_buffer+32
        ld      de,3310h
        ld      bc,32
        ldir
        ld      c,18
        call    0005h
        ld      (3305h),a
        call    0005h
        ld      (3306h),a
        call    0005h
        ld      (3307h),a

        ld      de,raw_fcb
        ld      c,17
        call    0005h
        ld      (3308h),a
        ld      hl,dma_buffer
        ld      de,3330h
        ld      bc,32
        ldir

        ld      e,1
        ld      c,32
        call    0005h
        ld      de,user_fcb
        ld      c,17
        call    0005h
        ld      (3309h),a
        ld      hl,dma_buffer
        ld      de,3350h
        ld      bc,32
        ldir

        ld      e,0
        ld      c,32
        call    0005h
        ld      e,12
        ld      c,14
        call    0005h
        ld      de,alpha_fcb
        ld      c,22
        call    0005h
        ld      (330ah),a
        ld      de,beta_fcb
        ld      c,22
        call    0005h
        ld      (330bh),a

        ld      de,m_wildcard_fcb
        ld      c,17
        call    0005h
        ld      (330ch),a
        ld      hl,dma_buffer
        ld      de,3370h
        ld      bc,32
        ldir
        ld      c,18
        call    0005h
        ld      (330dh),a
        ld      hl,dma_buffer+32
        ld      de,3390h
        ld      bc,32
        ldir
        ld      c,18
        call    0005h
        ld      (330eh),a

        ld      a,0aah
        ld      (33b0h),a
.hang:
        jr      .hang

result_marker:
        db      'OPSR'
physical_fcb:
        db      1,'TEST?   COM','?'
        defs    23,0
raw_fcb:
        db      '?'
        defs    35,0
user_fcb:
        db      1,'TEST3   DAT',0
        defs    23,0
alpha_fcb:
        db      13,'ALPHA   COM'
        defs    24,0
beta_fcb:
        db      13,'BETA    DAT'
        defs    24,0
m_wildcard_fcb:
        db      13,'???????????','?'
        defs    23,0
dma_buffer:
        defs    128,0

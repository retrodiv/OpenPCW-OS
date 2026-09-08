; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Black-box CP/M Plus process/disk-state conformance probe. Results are left
; at 3100h so the host harness can compare repeatable native executions.

        org     0100h

start:
        ld      sp,4000h
        ld      hl,result_marker
        ld      de,3100h
        ld      bc,4
        ldir

        ld      c,12              ; CP/M Plus version
        call    0005h
        ld      (3104h),hl

        ld      c,24              ; A: is logged at transient entry
        call    0005h
        ld      (3106h),hl
        ld      c,28              ; write-protect current A:
        call    0005h
        ld      (3108h),a
        ld      c,29
        call    0005h
        ld      (3109h),hl

        ld      de,0001h          ; reset A: clears login and R/O bits
        ld      c,37
        call    0005h
        ld      (310bh),a
        ld      c,24
        call    0005h
        ld      (310ch),hl
        ld      c,29
        call    0005h
        ld      (310eh),hl

        ld      e,12              ; select/log in M:
        ld      c,14
        call    0005h
        ld      (3110h),a
        ld      c,24
        call    0005h
        ld      (3111h),hl
        ld      c,25
        call    0005h
        ld      (3113h),a
        ld      c,28
        call    0005h
        ld      (3114h),a
        ld      c,29
        call    0005h
        ld      (3115h),hl
        ld      de,1000h          ; reset M:
        ld      c,37
        call    0005h
        ld      (3117h),a
        ld      c,24
        call    0005h
        ld      (3118h),hl
        ld      c,29
        call    0005h
        ld      (311ah),hl

        ld      e,023h            ; user codes are reduced modulo 16
        ld      c,32
        call    0005h
        ld      (311ch),a
        ld      e,0ffh
        call    0005h
        ld      (311dh),a

        ld      c,38              ; MP/M compatibility no-ops
        call    0005h
        ld      (311eh),a
        ld      c,39
        call    0005h
        ld      (311fh),a
        ld      c,41
        call    0005h
        ld      (3120h),a
        ld      a,h
        ld      (3121h),a
        ld      c,42
        call    0005h
        ld      (3122h),a
        ld      c,43
        call    0005h
        ld      (3123h),a

        ld      c,44              ; valid range is exactly 1..128
        ld      e,0
        call    0005h
        ld      (3124h),a
        ld      e,129
        call    0005h
        ld      (3125h),a
        ld      e,128
        call    0005h
        ld      (3126h),a
        ld      e,1
        call    0005h
        ld      (3127h),a

        ld      c,45              ; normalize and publish error mode
        ld      e,0feh
        call    0005h
        ld      (3128h),a
        ld      de,scb_parameter
        ld      c,49
        call    0005h
        ld      (3129h),hl

        ld      c,48              ; write-through implementation flushes cleanly
        ld      e,0ffh
        call    0005h
        ld      (312bh),a

        ld      de,1234h          ; program return code
        ld      c,108
        call    0005h
        ld      de,0ffffh
        call    0005h
        ld      (312ch),hl

        ld      de,0302h          ; console mode
        ld      c,109
        call    0005h
        ld      de,0ffffh
        call    0005h
        ld      (312eh),hl

        ld      de,0ffffh         ; output delimiter defaults to '$'
        ld      c,110
        call    0005h
        ld      (3130h),a
        ld      de,0023h          ; then accepts '#'
        call    0005h
        ld      de,0ffffh
        call    0005h
        ld      (3131h),a
        ld      de,0024h          ; leave the process default restored
        call    0005h

        ld      de,empty_ccb       ; block calls route through native bank
        ld      c,111
        call    0005h
        ld      (3132h),a
        ld      c,112
        call    0005h
        ld      (3133h),a

        ld      de,random_fcb      ; extent 34, current record 5 => 001105h
        ld      c,36
        call    0005h
        ld      hl,random_fcb+33
        ld      de,3134h
        ld      bc,3
        ldir

        ld      de,sparse_m_fcb   ; create M:SPARSE.DAT for user 3
        ld      c,22
        call    0005h
        ld      (3137h),a
        ld      de,sparse_dma
        ld      c,26
        call    0005h
        ld      de,sparse_m_fcb   ; write only maximum record 262143
        ld      c,34
        call    0005h
        ld      (3138h),a
        ld      c,35
        call    0005h
        ld      (3139h),a
        ld      hl,sparse_m_fcb+33
        ld      de,313ah
        ld      bc,3
        ldir

        ld      e,0               ; physical fixture belongs to user 0
        ld      c,32
        call    0005h
        ld      de,sparse_a_fcb   ; extents 0 and 3 => 386 records
        ld      c,35
        call    0005h
        ld      (313dh),a
        ld      hl,sparse_a_fcb+33
        ld      de,313eh
        ld      bc,3
        ldir

        ld      de,clock_set_data ; day 1234h, 23:59:00
        ld      c,104
        call    0005h
        ld      de,clock_get_data
        ld      c,105
        call    0005h
        ld      hl,clock_get_data
        ld      de,3141h
        ld      bc,4
        ldir
        ld      (3145h),a

        ld      bc,306            ; safely crosses one 300 Hz second
.clock_wait:
        halt
        dec     bc
        ld      a,b
        or      c
        jr      nz,.clock_wait
        ld      de,clock_get_data
        ld      c,105
        call    0005h
        ld      hl,clock_get_data
        ld      de,3146h
        ld      bc,4
        ldir
        ld      (314ah),a

        ld      de,clock_set_data ; verify 23:59:00 + 60 s -> next day
        ld      c,104
        call    0005h
        ld      bc,18006          ; 60 seconds plus a safe tick margin
.clock_day_wait:
        halt
        dec     bc
        ld      a,b
        or      c
        jr      nz,.clock_day_wait
        ld      de,clock_get_data
        ld      c,105
        call    0005h
        ld      hl,clock_get_data
        ld      de,314bh
        ld      bc,4
        ldir
        ld      (314fh),a

        ld      de,password_data  ; retained eight-byte process password
        ld      c,106
        call    0005h
        ld      (3150h),a

        ld      de,serial_buffer  ; project OS serial is exactly six bytes
        ld      c,107
        call    0005h
        ld      hl,serial_buffer
        ld      de,3151h
        ld      bc,6
        ldir

        ld      b,05ah            ; PCW CP/M compatibility probe 96
        ld      hl,1234h
        ld      c,96
        call    0005h
        ld      (3157h),a
        ld      a,b
        ld      (3158h),a
        ld      (3159h),hl

        ld      a,0aah
        ld      (315bh),a
.hang:
        jr      .hang

result_marker:
        db      'OPST'
scb_parameter:
        db      04bh,0,0,0
empty_ccb:
        dw      result_marker,0
random_fcb:
        db      0
        defs    11,020h
        db      2                 ; EX
        db      0
        db      1                 ; S2: extent = (1 * 32) + 2
        defs    17,0
        db      5                 ; CR
        db      0,0,0             ; R0/R1/R2 output
sparse_m_fcb:
        db      13
        db      'SPARSE  DAT'
        defs    21,0
        db      0ffh,0ffh,3       ; maximum random record 262143
sparse_a_fcb:
        db      1
        db      'SIZE    DAT'
        defs    24,0
sparse_dma:
        defs    128,05ah
clock_set_data:
        db      034h,012h,023h,059h
clock_get_data:
        defs    4,0cch
password_data:
        db      'PASSW0RD'
serial_buffer:
        defs    6,0cch

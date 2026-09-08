; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Exercise label passwords, Function-22 password assignment and destructive
; password checks on both the physical A: disk and volatile M: disk.

        org     0100h

RESULT          equ     03800h

start:
        ld      sp,04000h
        ld      hl,signature
        ld      de,RESULT
        ld      bc,4
        ldir
        ld      e,0ffh
        ld      c,45
        call    0005h

        ld      hl,a_blocks
        ld      de,RESULT+4
        call    exercise_drive
        ld      hl,m_blocks
        ld      de,RESULT+32
        call    exercise_drive
        ld      a,0aah
        ld      (RESULT+63),a
.done:
        jr      .done

; HL points to six consecutive FCBs: label-create, label-update, make,
; info, open and delete. DE points to the result block.
exercise_drive:
        push    de
        push    hl
        ld      de,password_pair
        ld      c,26
        call    0005h
        pop     hl
        push    hl
        ex      de,hl
        ld      c,100
        call    0005h
        ld      b,a
        ld      c,h
        pop     hl
        pop     de
        ld      a,b
        ld      (de),a
        inc     de
        ld      a,c
        ld      (de),a
        inc     de

        ; Wrong label password must reject a policy update.
        push    de
        push    hl
        ld      de,wrong_password
        ld      c,26
        call    0005h
        pop     hl
        push    hl
        ld      bc,36
        add     hl,bc
        ex      de,hl
        ld      c,100
        call    0005h
        ld      b,a
        ld      c,h
        pop     hl
        pop     de
        ld      a,b
        ld      (de),a
        inc     de
        ld      a,c
        ld      (de),a
        inc     de

        ; The existing label password supplied at DMA+0 permits the update.
        push    de
        push    hl
        ld      de,label_password
        ld      c,26
        call    0005h
        pop     hl
        push    hl
        ld      bc,36
        add     hl,bc
        ex      de,hl
        ld      c,100
        call    0005h
        ld      b,a
        ld      c,h
        pop     hl
        pop     de
        ld      a,b
        ld      (de),a
        inc     de
        ld      a,c
        ld      (de),a
        inc     de

        ; f6' on Make assigns DMA+0 as the new file password.
        push    de
        push    hl
        ld      de,file_password_block
        ld      c,26
        call    0005h
        pop     hl
        push    hl
        ld      bc,72
        add     hl,bc
        ex      de,hl
        ld      c,22
        call    0005h
        ld      b,a
        ld      c,h
        pop     hl
        pop     de
        ld      a,b
        ld      (de),a
        inc     de
        ld      a,c
        ld      (de),a
        inc     de

        push    de
        push    hl
        ld      bc,108
        add     hl,bc
        ex      de,hl
        ld      c,102
        call    0005h
        ld      b,a
        ld      c,h
        pop     hl
        pop     de
        ld      a,b
        ld      (de),a
        inc     de
        ld      a,c
        ld      (de),a
        inc     de
        push    hl
        ld      bc,120
        add     hl,bc
        ld      a,(hl)
        pop     hl
        ld      (de),a
        inc     de

        push    de
        push    hl
        ld      de,wrong_password
        ld      c,26
        call    0005h
        pop     hl
        push    hl
        ld      bc,144
        add     hl,bc
        ex      de,hl
        ld      c,15
        call    0005h
        ld      b,a
        ld      c,h
        pop     hl
        pop     de
        ld      a,b
        ld      (de),a
        inc     de
        ld      a,c
        ld      (de),a
        inc     de

        push    de
        push    hl
        ld      de,file_password
        ld      c,26
        call    0005h
        pop     hl
        push    hl
        ld      bc,144
        add     hl,bc
        ex      de,hl
        ld      c,15
        call    0005h
        ld      b,a
        ld      c,h
        pop     hl
        pop     de
        ld      a,b
        ld      (de),a
        inc     de
        ld      a,c
        ld      (de),a
        inc     de

        ; Directory mutation checks the password independently of Open.
        push    de
        push    hl
        ld      de,wrong_password
        ld      c,26
        call    0005h
        pop     hl
        push    hl
        ld      bc,180
        add     hl,bc
        ex      de,hl
        ld      c,19
        call    0005h
        ld      b,a
        ld      c,h
        pop     hl
        pop     de
        ld      a,b
        ld      (de),a
        inc     de
        ld      a,c
        ld      (de),a
        inc     de

        push    de
        push    hl
        ld      de,file_password
        ld      c,26
        call    0005h
        pop     hl
        ld      bc,180
        add     hl,bc
        ex      de,hl
        ld      c,19
        call    0005h
        ld      b,a
        ld      c,h
        pop     de
        ld      a,b
        ld      (de),a
        inc     de
        ld      a,c
        ld      (de),a
        inc     de
        ld      a,055h
        ld      (de),a
        ret

signature:      db      'PMUT'
password_pair:
wrong_password: db      'BADPASS!'
label_password: db      'LABPASS!'
file_password:  db      'FILEPASS'
file_password_block:
        db      'FILEPASS',080h

a_blocks:
a_label_create:
        db      1,'PASSWORDLBL',081h
        defs    23,0
a_label_update:
        db      1,'PASSWORDLBL',080h
        defs    23,0
a_make:
        db      1,'AUTO ',0a0h,'  ','DAT',080h
        defs    23,0
a_info:
        db      1,'AUTO    DAT'
        defs    24,0
a_open:
        db      1,'AUTO    DAT'
        defs    24,0
a_delete:
        db      1,'AUTO    DAT'
        defs    24,0

m_blocks:
m_label_create:
        db      13,'PASSWORDLBL',081h
        defs    23,0
m_label_update:
        db      13,'PASSWORDLBL',080h
        defs    23,0
m_make:
        db      13,'AUTO ',0a0h,'  ','DAT',080h
        defs    23,0
m_info:
        db      13,'AUTO    DAT'
        defs    24,0
m_open:
        db      13,'AUTO    DAT'
        defs    24,0
m_delete:
        db      13,'AUTO    DAT'
        defs    24,0

; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Project-authored CP/M Plus password/XFCB probe for OpenPCW-OS's M: drive.
; Results are left at 3800h for the host-side contract test.

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

        ld      de,target_make_fcb
        ld      c,22
        call    0005h
        ld      (RESULT+4),a
        ld      a,h
        ld      (RESULT+5),a
        ld      de,target_make_fcb
        ld      c,16
        call    0005h

        ld      de,label_fcb
        ld      c,100
        call    0005h
        ld      (RESULT+6),a
        ld      a,h
        ld      (RESULT+7),a
        ld      e,12
        ld      c,101
        call    0005h
        ld      (RESULT+8),a

        ld      de,password_pair
        ld      c,26
        call    0005h
        ld      de,target_assign_fcb
        ld      c,103
        call    0005h
        ld      (RESULT+9),a
        ld      a,h
        ld      (RESULT+10),a

        ld      de,target_info_fcb
        ld      c,102
        call    0005h
        ld      (RESULT+11),a
        ld      a,h
        ld      (RESULT+12),a
        ld      a,(target_info_fcb+12)
        ld      (RESULT+13),a

        ld      e,12
        ld      c,14
        call    0005h
        ld      de,directory_buffer
        ld      c,26
        call    0005h
        ld      de,all_entries_fcb
        ld      c,17
        call    0005h
.search_entry:
        cp      0ffh
        jr      z,.search_done
        add     a,a
        add     a,a
        add     a,a
        add     a,a
        add     a,a
        ld      e,a
        ld      d,0
        ld      hl,directory_buffer
        add     hl,de
        ld      a,(hl)
        cp      010h
        jr      nz,.search_next
        ld      de,RESULT+32
        ld      bc,32
        ldir
        jr      .search_done
.search_next:
        ld      c,18
        call    0005h
        jr      .search_entry
.search_done:

        ld      de,wrong_password
        ld      c,26
        call    0005h
        ld      de,target_wrong_fcb
        ld      c,15
        call    0005h
        ld      (RESULT+14),a
        ld      a,h
        ld      (RESULT+15),a

        ld      de,new_password
        ld      c,26
        call    0005h
        ld      de,target_good_fcb
        ld      c,15
        call    0005h
        ld      (RESULT+16),a
        ld      a,h
        ld      (RESULT+17),a
        ld      de,target_good_fcb
        ld      c,16
        call    0005h
        ld      (RESULT+18),a
        ld      a,h
        ld      (RESULT+19),a

        ld      de,new_password
        ld      c,106
        call    0005h
        ld      de,wrong_password
        ld      c,26
        call    0005h
        ld      de,target_default_fcb
        ld      c,15
        call    0005h
        ld      (RESULT+20),a
        ld      a,h
        ld      (RESULT+21),a

        ld      a,0aah
        ld      (RESULT+22),a
.done:
        jr      .done

signature:      db      'MPWD'
label_fcb:
        db      13
        db      'PASSWORDLBL'
        db      080h
        defs    23,0
target_make_fcb:
        db      13
        db      'TARGET  DAT'
        defs    24,0
target_assign_fcb:
        db      13
        db      'TARGET  DAT'
        db      081h
        defs    23,0
target_info_fcb:
        db      13
        db      'TARGET  DAT'
        defs    24,0
target_wrong_fcb:
        db      13
        db      'TARGET  DAT'
        defs    24,0
target_good_fcb:
        db      13
        db      'TARGET  DAT'
        defs    24,0
target_default_fcb:
        db      13
        db      'TARGET  DAT'
        defs    24,0
all_entries_fcb:
        db      '?'
        defs    35,'?'
password_pair:
wrong_password: db      'BADPASS!'
new_password:   db      'NEWPASS!'
directory_buffer:
        defs    128,0

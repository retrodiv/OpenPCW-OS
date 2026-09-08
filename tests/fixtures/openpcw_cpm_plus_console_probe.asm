; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Black-box CP/M Plus console/AUX conformance probe. It uses only the public
; BDOS entry at 0005h and leaves its result record at 3000h for the host test.

        org     0100h

start:
        ld      sp,4000h
        ld      hl,result_template
        ld      de,3000h
        ld      bc,result_template_end-result_template
        ldir

; Do not mistake the RETURN used to launch this program for fresh input.
.wait_release:
        ld      c,6
        ld      e,0feh            ; Direct Console status
        call    0005h
        or      a
        jr      nz,.wait_release
        ld      (3004h),a

        ld      c,7               ; AUX input status: no configured device
        call    0005h
        ld      (3005h),a
        ld      c,8               ; AUX output status: no configured device
        call    0005h
        ld      (3006h),a
        ld      c,3               ; AUX input on an absent device: CP/M EOF
        call    0005h
        ld      (3007h),a

        ld      c,4               ; Absent AUXOUT/LST must remain harmless
        ld      e,'A'
        call    0005h
        ld      c,5
        ld      e,'L'
        call    0005h

        ld      a,055h
        ld      (3008h),a
        ld      c,6
        ld      e,0fdh            ; Direct Console blocking input
        call    0005h
        ld      (3009h),a
        ld      a,0aah
        ld      (300ah),a

        ; Direct Console output returns A=0 in this compatibility contract.
        ; Check the register result as well as the visible character because
        ; callers can inspect A after the operation.
        ld      c,6
        ld      e,'!'
        call    0005h
        ld      (300bh),a
.hang:
        jr      .hang

result_template:
        db      'OPCW',0ffh,0ffh,0ffh,0ffh,0,0ffh,0,0ffh
result_template_end:

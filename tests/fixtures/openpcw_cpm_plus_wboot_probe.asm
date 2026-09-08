; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Non-returning BDOS 50 / BIOS WBOOT lifecycle probe. The host launches this
; COM twice. The first invocation leaves a persistent phase marker and calls
; WBOOT through the documented BIOS parameter block. The second invocation
; proves that command processing resumed and that Page Zero was rebuilt.

        org     0100h

start:
        ld      sp,4000h
        ld      hl,3600h
        ld      de,result_marker
        ld      b,4
.marker_check:
        ld      a,(de)
        cp      (hl)
        jr      nz,.first_run
        inc     de
        inc     hl
        djnz    .marker_check
        ld      a,(3604h)
        cp      1
        jr      nz,.first_run

.second_run:
        ld      a,2
        ld      (3604h),a
        ld      b,0
        ld      a,(0000h)         ; JP WBOOT
        cp      0c3h
        jr      nz,.page_zero_vector
        set     0,b
.page_zero_vector:
        ld      hl,(0001h)
        ld      a,h
        or      l
        jr      z,.page_zero_target
        set     1,b
.page_zero_target:
        ld      a,(hl)            ; public WBOOT vector is executable JP
        cp      0c3h
        jr      nz,.page_zero_bdos
        set     2,b
.page_zero_bdos:
        ld      a,(0005h)         ; JP current BDOS/RSX head
        cp      0c3h
        jr      nz,.page_zero_bdos_target
        set     3,b
.page_zero_bdos_target:
        ld      hl,(0006h)
        ld      a,h
        or      l
        jr      z,.page_zero_result
        set     4,b
.page_zero_result:
        ld      a,b
        ld      (3605h),a
        ld      a,0aah
        ld      (3606h),a
        ld      a,b
        cp      01fh
        ld      de,result_pass
        jr      z,.print_result
        ld      de,result_page_zero_failure
.print_result:
        ld      c,9
        call    0005h
.finished:
        jr      .finished

.first_run:
        ld      hl,result_marker
        ld      de,3600h
        ld      bc,4
        ldir
        ld      a,1
        ld      (3604h),a
        xor     a
        ld      (3605h),a
        ld      de,bios_pb
        ld      c,50
        call    0005h
        ; WBOOT is the sole non-returning BIOS call. Reaching here is failure;
        ; a subsequent harness command cannot repair this byte while we spin.
        ld      a,0eeh
        ld      (3605h),a
        ld      de,result_returned
        ld      c,9
        call    0005h
        jr      .finished

bios_pb:
        db      1,0              ; BIOS function 1 = WBOOT
        dw      0,0,0
result_marker:
        db      'OPWB'
result_pass:
        db      13,10,'OPENPCW WBOOT PASS',13,10,'$'
result_page_zero_failure:
        db      13,10,'OPENPCW WBOOT PAGE ZERO FAIL',13,10,'$'
result_returned:
        db      13,10,'OPENPCW WBOOT RETURNED',13,10,'$'

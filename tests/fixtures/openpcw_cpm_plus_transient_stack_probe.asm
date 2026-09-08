; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Plain-transient stack-isolation probe. It retains sixteen application stack
; words while opening and reading its own COM file, then publishes a marker.
; This exercises a deeper call frame than the resident BDOS front end and
; proves that application stack traffic cannot modify resident instructions.

        org     0100h

start:
        jp      probe_start
probe_start:
        ld      hl,05aa5h
        ld      b,16
.reserve_application_frames:
        push    hl
        djnz    .reserve_application_frames

        ld      de,self_fcb
        ld      c,15
        call    0005h
        inc     a
        jr      z,.publish_failure

        ld      de,read_buffer
        ld      c,26
        call    0005h
        ld      de,self_fcb
        ld      c,20
        call    0005h
        or      a
        jr      nz,.publish_failure

        ld      a,(read_buffer)
        cp      0c3h              ; COM begins with JP probe_start
        jr      nz,.publish_failure
        xor     a
        jr      .publish_result
.publish_failure:
        ld      a,0ffh
.publish_result:
        ld      (03604h),a
        ld      hl,result_marker
        ld      de,03600h
        ld      bc,4
        ldir

        ld      b,16
.release_application_frames:
        pop     hl
        djnz    .release_application_frames
        ret

self_fcb:
        db      0,'STACK   COM',0,0,0,0
        defs    16,0
        db      0,0,0,0
result_marker:
        db      'OPST'
read_buffer:
        defs    128,0

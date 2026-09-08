; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Public XBIOS geometry-selection probe. The containing test disk exposes this
; transient through its ordinary one-reserved-track catalog, then places
; ACTIVE.DAT in a second catalog reached only when DD L XDPB selects a
; nine-reserved-track geometry. BDOS 13 must reset filesystem state without
; discarding that validated XDPB selection.

        org     0100h

RESULT          equ     03900h
DMA             equ     RESULT+16

start:
        ld      sp,03b00h
        ld      hl,result_initial
        ld      de,RESULT
        ld      bc,16
        ldir

        ; USERF is WBOOT+57h in the CP/M Plus BIOS jump table. Its service
        ; word follows CALL, as specified by the PCW XBIOS calling convention.
        ld      hl,(0001h)
        ld      de,0057h
        add     hl,de
        ld      (call_xbios+1),hl

        ; XBIOS receives the independent specification from common memory,
        ; which stays visible while its private low page replaces the TPA.
        ld      hl,nine_reserved_tracks
        ld      de,0c100h
        ld      bc,10
        ldir

        ; Use the public active DPB/XDPB storage returned by BDOS 31. DD L
        ; XDPB validates the common-memory specification at HL, publishes the
        ; 27-byte XDPB at IX, and selects it for later login.
        ld      c,31
        call    0005h
        push    hl
        pop     ix
        ld      hl,0c100h
call_xbios:
        call    0000h
        dw      00a1h                   ; DD L XDPB
        push    af
        pop     bc
        ld      a,b
        ld      (RESULT+4),a
        ld      a,c
        and     1
        ld      (RESULT+5),a

        ; A CP/M filesystem reset is the important boundary under test: the
        ; selected XDPB remains active while directory and allocation caches
        ; are rebuilt from the newly selected catalog location.
        ld      c,13
        call    0005h
        ld      (RESULT+6),a

        ld      de,target_fcb
        ld      c,15
        call    0005h
        ld      (RESULT+7),a

        ld      de,DMA
        ld      c,26
        call    0005h
        ld      de,target_fcb
        ld      c,20
        call    0005h
        ld      (RESULT+8),a
.done:
        jr      .done

result_initial:
        db      'OPA1'
        defs    12,0ffh

; Format 0, one side, 40 tracks, nine 512-byte sectors, nine reserved tracks,
; 1K allocation blocks, two directory blocks, and standard RW/GAP3 values.
nine_reserved_tracks:
        db      0,0,40,9,2,9,3,2,02ah,052h

target_fcb:
        db      1                       ; explicit physical A:
        db      'ACTIVE  DAT'
        defs    24,0

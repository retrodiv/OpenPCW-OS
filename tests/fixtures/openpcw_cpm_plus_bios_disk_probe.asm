; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Black-box public CP/M Plus disk-BIOS probe.  It derives every vector from
; Page Zero's WBOOT operand, writes two physical sectors across a track
; boundary, reads them back, and leaves compact results at 3400h.

        org     0100h

start:
        ld      sp,4000h
        ld      hl,result_marker
        ld      de,3400h
        ld      bc,4
        ldir

        ; SELDSK A: must return a DPH whose +12 word points at a 36-record
        ; physical-track DPB (nine 512-byte sectors).
        ld      hl,(0001h)
        ld      de,0018h
        add     hl,de
        ld      c,0
        ld      e,0
        call    call_bios
        ld      a,h
        or      l
        jr      z,.dph_missing
        ld      a,1
.dph_missing:
        ld      (3404h),a
        ld      de,12
        add     hl,de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ex      de,hl
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      (3405h),de

        ; An absent B: drive is represented by a null DPH.
        ld      hl,(0001h)
        ld      de,0018h
        add     hl,de
        ld      c,1
        ld      e,0
        call    call_bios
        ld      a,h
        or      l
        ld      (3407h),a

        ; Restore A: and verify identity sector translation without a table.
        ld      hl,(0001h)
        ld      de,0018h
        add     hl,de
        ld      c,0
        ld      e,0ffh
        call    call_bios
        ld      hl,(0001h)
        ld      de,002dh
        add     hl,de
        ld      bc,7
        ld      de,0
        call    call_bios
        ld      (3408h),hl

        ; Fill two physical sectors with distinct patterns. Track 38 sector 8
        ; plus MULTIO=2 deliberately crosses to track 39 sector 0.
        ld      hl,3500h
        ld      de,3501h
        ld      bc,511
        ld      (hl),05ah
        ldir
        ld      hl,3700h
        ld      de,3701h
        ld      bc,511
        ld      (hl),0a5h
        ldir

        ld      hl,(0001h)        ; SETBNK transient bank 1
        ld      de,0051h
        add     hl,de
        ld      a,1
        call    call_bios
        ld      hl,(0001h)        ; SETTRK 38
        ld      de,001bh
        add     hl,de
        ld      bc,38
        call    call_bios
        ld      hl,(0001h)        ; SETSEC 8
        ld      de,001eh
        add     hl,de
        ld      bc,8
        call    call_bios
        ld      hl,(0001h)        ; SETDMA 3500h
        ld      de,0021h
        add     hl,de
        ld      bc,3500h
        call    call_bios
        ld      hl,(0001h)        ; MULTIO 2
        ld      de,0042h
        add     hl,de
        ld      c,2
        call    call_bios
        ld      hl,(0001h)        ; WRITE
        ld      de,0027h
        add     hl,de
        ld      c,0
        call    call_bios
        ld      (340ah),a
        ld      hl,(0001h)        ; FLUSH
        ld      de,0045h
        add     hl,de
        call    call_bios
        ld      (340bh),a

        xor     a
        ld      hl,3500h
        ld      de,3501h
        ld      bc,1023
        ld      (hl),a
        ldir
        ld      hl,(0001h)        ; READ with the same retained geometry/DMA
        ld      de,0024h
        add     hl,de
        call    call_bios
        ld      (340ch),a

        ld      hl,3500h
        ld      bc,512
        ld      e,05ah
        call    verify_pattern
        ld      (340dh),a
        ld      hl,3700h
        ld      bc,512
        ld      e,0a5h
        call    verify_pattern
        ld      (340eh),a

        ; HOME must override the previous track. Read track 0 sector 0 into a
        ; separate DMA; the generated fixture's disk specification starts 00h.
        ld      hl,(0001h)
        ld      de,0042h
        add     hl,de
        ld      c,1
        call    call_bios
        ld      hl,(0001h)
        ld      de,0015h
        add     hl,de
        call    call_bios
        ld      hl,(0001h)
        ld      de,001eh
        add     hl,de
        ld      bc,0
        call    call_bios
        ld      hl,(0001h)
        ld      de,0021h
        add     hl,de
        ld      bc,3900h
        call    call_bios
        ld      hl,(0001h)
        ld      de,0024h
        add     hl,de
        call    call_bios
        ld      (340fh),a
        ld      a,(3900h)
        ld      (3410h),a

        ; Seed a 512-byte DMA buffer in the known free bank-0 gap at
        ; 5000h..51FFh using four legal one-shot 128-byte XMOVEs. SETBNK=0
        ; must make WRITE consume that buffer; SETBNK=1 must then let READ
        ; return the same physical sector to the transient bank.
        ld      hl,(0001h)
        ld      de,0054h
        add     hl,de
        ld      (call_xmove+1),hl
        ld      hl,(0001h)
        ld      de,0048h
        add     hl,de
        ld      (call_move+1),hl
        ld      hl,3a00h
        ld      de,3a01h
        ld      bc,511
        ld      (hl),06ch
        ldir
        ld      de,3a00h
        ld      hl,5000h
        ld      a,4
.seed_bank_zero:
        push    af
        ld      bc,0001h           ; XMOVE destination 0, source 1
call_xmove:
        call    0000h
        ld      bc,128
call_move:
        call    0000h
        pop     af
        dec     a
        jr      nz,.seed_bank_zero

        ld      hl,(0001h)         ; SETBNK 0
        ld      de,0051h
        add     hl,de
        xor     a
        call    call_bios
        ld      hl,(0001h)         ; SETTRK 38
        ld      de,001bh
        add     hl,de
        ld      bc,38
        call    call_bios
        ld      hl,(0001h)         ; SETSEC 7
        ld      de,001eh
        add     hl,de
        ld      bc,7
        call    call_bios
        ld      hl,(0001h)         ; SETDMA 5000h in bank 0
        ld      de,0021h
        add     hl,de
        ld      bc,5000h
        call    call_bios
        ld      hl,(0001h)         ; WRITE from bank 0
        ld      de,0027h
        add     hl,de
        ld      c,0
        call    call_bios
        ld      (3411h),a

        xor     a
        ld      hl,3a00h
        ld      de,3a01h
        ld      bc,511
        ld      (hl),a
        ldir
        ld      hl,(0001h)         ; SETBNK 1
        ld      de,0051h
        add     hl,de
        ld      a,1
        call    call_bios
        ld      hl,(0001h)         ; SETDMA 3A00h in bank 1
        ld      de,0021h
        add     hl,de
        ld      bc,3a00h
        call    call_bios
        ld      hl,(0001h)         ; READ into bank 1
        ld      de,0024h
        add     hl,de
        call    call_bios
        ld      (3412h),a
        ld      hl,3a00h
        ld      bc,512
        ld      e,06ch
        call    verify_pattern
        ld      (3413h),a
        ld      a,0aah
        ld      (3414h),a
.finished:
        jr      .finished

; Call the JP vector whose address is in HL while retaining its documented
; register inputs. The operand is transient-owned self-modifying code.
call_bios:
        ld      (call_target+1),hl
call_target:
        call    0000h
        ret

; HL=data, BC=count, E=expected. Return A=1 only when every byte matches.
verify_pattern:
.next:
        ld      a,(hl)
        cp      e
        jr      nz,.bad
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,.next
        ld      a,1
        ret
.bad:
        xor     a
        ret

result_marker:
        db      'OPBI'

; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; BDOS 50 / banked BIOS conformance probe. Results are left at 3600h.

        org     0100h

start:
        ld      sp,4000h
        ld      hl,result_marker
        ld      de,3600h
        ld      bc,4
        ldir

        ld      hl,pattern_a
        ld      de,2400h
        ld      bc,16
        ldir
        ld      a,25              ; MOVE within selected bank 1
        ld      (bios_pb),a
        ld      bc,16
        ld      (bios_pb+2),bc
        ld      de,2400h
        ld      (bios_pb+4),de
        ld      hl,2500h
        ld      (bios_pb+6),hl
        call    call_bios_50
        ld      (3605h),bc
        ld      (3607h),de
        ld      (3609h),hl
        ld      hl,2500h
        ld      de,pattern_a
        ld      b,16
        call    compare_bytes
        ld      (3604h),a

        ld      hl,overlap_initial
        ld      de,2900h
        ld      bc,16
        ldir
        ld      a,25
        ld      (bios_pb),a
        ld      bc,12
        ld      (bios_pb+2),bc
        ld      de,2900h
        ld      (bios_pb+4),de
        ld      hl,2904h
        ld      (bios_pb+6),hl
        call    call_bios_50
        ld      hl,2900h
        ld      de,overlap_expected
        ld      b,16
        call    compare_bytes
        ld      (360bh),a

        ; Copy bank 1 -> bank 0 and back. Each XMOVE applies to exactly one
        ; following MOVE; 3A00h is above the maximum native-module footprint.
        ld      hl,pattern_b
        ld      de,2600h
        ld      bc,16
        ldir
        ld      a,29              ; XMOVE B=dest 0, C=source 1
        ld      (bios_pb),a
        ld      bc,0001h
        ld      (bios_pb+2),bc
        call    call_bios_50
        ld      a,25
        ld      (bios_pb),a
        ld      bc,16
        ld      (bios_pb+2),bc
        ld      de,2600h
        ld      (bios_pb+4),de
        ld      hl,3a00h
        ld      (bios_pb+6),hl
        call    call_bios_50
        ld      a,29              ; XMOVE B=dest 1, C=source 0
        ld      (bios_pb),a
        ld      bc,0100h
        ld      (bios_pb+2),bc
        call    call_bios_50
        ld      a,25
        ld      (bios_pb),a
        ld      bc,16
        ld      (bios_pb+2),bc
        ld      de,3a00h
        ld      (bios_pb+4),de
        ld      hl,2800h
        ld      (bios_pb+6),hl
        call    call_bios_50
        ld      hl,2800h
        ld      de,pattern_b
        ld      b,16
        call    compare_bytes
        ld      (360ch),a

        ; Function 50 must intercept SELMEM instead of mapping this transient
        ; out. The following ordinary MOVE must therefore still use bank 1.
        ld      a,27
        ld      (bios_pb),a
        xor     a
        ld      (bios_pb+1),a
        ld      bc,0a1b2h
        ld      (bios_pb+2),bc
        ld      de,0c3d4h
        ld      (bios_pb+4),de
        ld      hl,0e5f6h
        ld      (bios_pb+6),hl
        call    call_bios_50
        ld      (360eh),a
        ld      hl,pattern_c
        ld      de,2b00h
        ld      bc,16
        ldir
        ld      a,25
        ld      (bios_pb),a
        ld      bc,16
        ld      (bios_pb+2),bc
        ld      de,2b00h
        ld      (bios_pb+4),de
        ld      hl,2c00h
        ld      (bios_pb+6),hl
        call    call_bios_50
        ld      hl,2c00h
        ld      de,pattern_c
        ld      b,16
        call    compare_bytes
        ld      (360dh),a

        ; Exercise the real public SELMEM vector from common memory.  The
        ; callback switches to bank 0, performs an ordinary (non-XMOVE) MOVE,
        ; restores bank 1 and returns through a common stack.  Derive vectors
        ; from Page Zero so this is valid for every conforming BIOS layout.
        ld      hl,pattern_d
        ld      de,2e00h
        ld      bc,16
        ldir
        ld      a,29              ; seed bank 0: destination 0, source 1
        ld      (bios_pb),a
        ld      bc,0001h
        ld      (bios_pb+2),bc
        call    call_bios_50
        ld      a,25
        ld      (bios_pb),a
        ld      bc,16
        ld      (bios_pb+2),bc
        ld      de,2e00h
        ld      (bios_pb+4),de
        ld      hl,5000h           ; free bank-0 gap below screen RAM
        ld      (bios_pb+6),hl
        call    call_bios_50

        ld      hl,bank0_callback
        ld      de,BANK0_CALLBACK_ADDR
        ld      bc,bank0_callback_end-bank0_callback
        ldir
        ld      hl,(0001h)        ; Page Zero points at WBOOT
        ld      de,04eh            ; SELMEM is WBOOT + 4Eh
        add     hl,de
        ld      (BANK0_CALLBACK_ADDR+callback_selmem_0+1-bank0_callback),hl
        ld      (BANK0_CALLBACK_ADDR+callback_selmem_1+1-bank0_callback),hl
        ld      hl,(0001h)
        ld      de,048h            ; MOVE is WBOOT + 48h
        add     hl,de
        ld      (BANK0_CALLBACK_ADDR+callback_move+1-bank0_callback),hl
        call    BANK0_CALLBACK_ADDR
        ld      hl,BANK0_CALLBACK_ADDR+callback_selmem_registers-bank0_callback
        ld      de,selmem_register_expected
        ld      b,20
        call    compare_bytes
        ld      (3638h),a

        ld      a,29              ; inspect bank 0 from restored bank 1
        ld      (bios_pb),a
        ld      bc,0100h           ; destination 1, source 0
        ld      (bios_pb+2),bc
        call    call_bios_50
        ld      a,25
        ld      (bios_pb),a
        ld      bc,16
        ld      (bios_pb+2),bc
        ld      de,5100h
        ld      (bios_pb+4),de
        ld      hl,3100h
        ld      (bios_pb+6),hl
        call    call_bios_50
        ld      hl,3100h
        ld      de,pattern_d
        ld      b,16
        call    compare_bytes
        ld      (362fh),a

        ; Source-side bank/common boundary: BFF8h..BFFFh belongs to source
        ; bank 1, while C000h..C007h is common and must ignore the bank number.
        ld      hl,boundary_pattern
        ld      de,0bff8h
        ld      bc,16
        ldir
        ld      a,29
        ld      (bios_pb),a
        ld      bc,0001h           ; destination 0, source 1
        ld      (bios_pb+2),bc
        call    call_bios_50
        ld      a,25
        ld      (bios_pb),a
        ld      bc,16
        ld      (bios_pb+2),bc
        ld      de,0bff8h
        ld      (bios_pb+4),de
        ld      hl,5200h           ; free bank-0 gap below screen RAM
        ld      (bios_pb+6),hl
        call    call_bios_50
        ld      (3632h),bc
        ld      (3634h),de
        ld      (3636h),hl
        ld      a,29
        ld      (bios_pb),a
        ld      bc,0100h           ; destination 1, source 0
        ld      (bios_pb+2),bc
        call    call_bios_50
        ld      a,25
        ld      (bios_pb),a
        ld      bc,16
        ld      (bios_pb+2),bc
        ld      de,5200h
        ld      (bios_pb+4),de
        ld      hl,3300h
        ld      (bios_pb+6),hl
        call    call_bios_50
        ld      hl,3300h
        ld      de,boundary_pattern
        ld      b,16
        call    compare_bytes
        ld      (3630h),a

        ; Destination-side boundary in current bank 1: the first eight bytes
        ; are banked and the final eight are common. Read the mixed range back.
        ld      hl,boundary_pattern
        ld      de,3400h
        ld      bc,16
        ldir
        ld      a,25
        ld      (bios_pb),a
        ld      bc,16
        ld      (bios_pb+2),bc
        ld      de,3400h
        ld      (bios_pb+4),de
        ld      hl,0bff8h
        ld      (bios_pb+6),hl
        call    call_bios_50
        ld      a,25
        ld      (bios_pb),a
        ld      bc,16
        ld      (bios_pb+2),bc
        ld      de,0bff8h
        ld      (bios_pb+4),de
        ld      hl,3500h
        ld      (bios_pb+6),hl
        call    call_bios_50
        ld      hl,3500h
        ld      de,boundary_pattern
        ld      b,16
        call    compare_bytes
        ld      (3631h),a

        ld      hl,skew_table
        ld      de,2d00h
        ld      bc,4
        ldir
        ld      a,16              ; SECTRN BC=2 through supplied table
        ld      (bios_pb),a
        ld      bc,2
        ld      (bios_pb+2),bc
        ld      de,2d00h
        ld      (bios_pb+4),de
        call    call_bios_50
        ld      (360fh),hl

        ld      a,26              ; TIME must preserve its input DE and HL
        ld      (bios_pb),a
        ld      bc,0
        ld      (bios_pb+2),bc
        ld      de,1234h
        ld      (bios_pb+4),de
        ld      hl,5678h
        ld      (bios_pb+6),hl
        call    call_bios_50
        ld      (3611h),de
        ld      (3613h),hl

        ; Put the clock close to the end of its current one-second phase, then
        ; update the published SCB fields and notify the BIOS with TIME C=FFh.
        ; 270 ticks before plus 50 after would cross 300 ticks if TIME failed
        ; to restart the phase.  Both snapshots must therefore retain second
        ; 47h.  This is deliberately a black-box timing assertion: it does not
        ; inspect OpenPCW's private clock state.
        ld      de,clock_phase_base
        ld      c,104
        call    0005h
        ld      bc,270
.clock_phase_advance:
        halt
        dec     bc
        ld      a,b
        or      c
        jr      nz,.clock_phase_advance

        ld      de,scb_day_write
        ld      c,49
        call    0005h
        ld      de,scb_hour_write
        ld      c,49
        call    0005h
        ld      de,scb_minute_write
        ld      c,49
        call    0005h
        ld      de,scb_second_write
        ld      c,49
        call    0005h

        ld      a,26
        ld      (bios_pb),a
        ld      bc,00ffh          ; TIME C=FFh: BDOS has set the SCB clock
        ld      (bios_pb+2),bc
        ld      de,0a55ah
        ld      (bios_pb+4),de
        ld      hl,05aa5h
        ld      (bios_pb+6),hl
        call    call_bios_50
        ld      (3618h),de
        ld      (361ah),hl

        ld      de,clock_phase_result
        ld      c,105
        call    0005h
        ld      hl,clock_phase_result
        ld      de,361ch
        ld      bc,4
        ldir
        ld      (3620h),a

        ld      bc,50
.clock_phase_verify:
        halt
        dec     bc
        ld      a,b
        or      c
        jr      nz,.clock_phase_verify
        ld      de,clock_phase_result
        ld      c,105
        call    0005h
        ld      hl,clock_phase_result
        ld      de,3621h
        ld      bc,4
        ldir
        ld      (3625h),a

        ; Complete one second from the restarted phase.  TIME C=0 must copy
        ; the live BIOS clock back into the published SCB while preserving
        ; DE/HL.  Reading the SCB through documented BDOS function 49 keeps
        ; this probe independent of its physical address.
        ld      bc,256
.clock_sync_verify:
        halt
        dec     bc
        ld      a,b
        or      c
        jr      nz,.clock_sync_verify
        ld      a,26
        ld      (bios_pb),a
        ld      bc,0
        ld      (bios_pb+2),bc
        ld      de,1357h
        ld      (bios_pb+4),de
        ld      hl,2468h
        ld      (bios_pb+6),hl
        call    call_bios_50
        ld      (3626h),de
        ld      (3628h),hl

        ld      de,scb_day_read
        ld      c,49
        call    0005h
        ld      (362ah),hl
        ld      de,scb_hour_read
        ld      c,49
        call    0005h
        ld      (362ch),a
        ld      de,scb_minute_read
        ld      c,49
        call    0005h
        ld      (362dh),a
        ld      de,scb_second_read
        ld      c,49
        call    0005h
        ld      (362eh),a

        ld      a,20              ; DEVTBL -> "CRT   ", mode 03h
        ld      (bios_pb),a
        call    call_bios_50
        ld      de,character_expected
        ld      b,7
        call    compare_bytes
        ld      (3615h),a

        ld      a,22              ; DRVTBL entry A: must point at a DPH
        ld      (bios_pb),a
        call    call_bios_50
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      a,d
        or      e
        jr      z,.drive_missing
        ld      a,1
.drive_missing:
        ld      (3616h),a
        ld      a,0aah
        ld      (3617h),a
.finished:
        jr      .finished

call_bios_50:
        ld      de,bios_pb
        ld      c,50
        call    0005h
        ret

BANK0_CALLBACK_ADDR equ 0e000h
BANK0_CALLBACK_STACK equ 0e100h

; This blob is copied to common memory. Every internal writable address is
; expressed relative to its installed address so it remains position-valid.
bank0_callback:
        ld      (BANK0_CALLBACK_ADDR+callback_saved_sp-bank0_callback),sp
        ld      sp,BANK0_CALLBACK_STACK
        ld      bc,1234h
        ld      de,5678h
        ld      hl,09abch
        ld      ix,1357h
        ld      iy,2468h
        xor     a
callback_selmem_0:
        call    0000h
        ld      (BANK0_CALLBACK_ADDR+callback_selmem_registers-bank0_callback),bc
        ld      (BANK0_CALLBACK_ADDR+callback_selmem_registers+2-bank0_callback),de
        ld      (BANK0_CALLBACK_ADDR+callback_selmem_registers+4-bank0_callback),hl
        push    ix
        pop     hl
        ld      (BANK0_CALLBACK_ADDR+callback_selmem_registers+6-bank0_callback),hl
        push    iy
        pop     hl
        ld      (BANK0_CALLBACK_ADDR+callback_selmem_registers+8-bank0_callback),hl
        ld      de,5000h
        ld      hl,5100h
        ld      bc,16
callback_move:
        call    0000h
        ld      bc,2143h
        ld      de,6587h
        ld      hl,0cba9h
        ld      ix,7531h
        ld      iy,8642h
        ld      a,1
callback_selmem_1:
        call    0000h
        ld      (BANK0_CALLBACK_ADDR+callback_selmem_registers+10-bank0_callback),bc
        ld      (BANK0_CALLBACK_ADDR+callback_selmem_registers+12-bank0_callback),de
        ld      (BANK0_CALLBACK_ADDR+callback_selmem_registers+14-bank0_callback),hl
        push    ix
        pop     hl
        ld      (BANK0_CALLBACK_ADDR+callback_selmem_registers+16-bank0_callback),hl
        push    iy
        pop     hl
        ld      (BANK0_CALLBACK_ADDR+callback_selmem_registers+18-bank0_callback),hl
        ld      sp,(BANK0_CALLBACK_ADDR+callback_saved_sp-bank0_callback)
        ret
callback_saved_sp:
        dw      0
callback_selmem_registers:
        defs    20,0
bank0_callback_end:

; HL=actual, DE=expected, B=count. Return A=1 for an exact match.
compare_bytes:
.compare_next:
        ld      a,(de)
        cp      (hl)
        jr      nz,.compare_bad
        inc     de
        inc     hl
        djnz    .compare_next
        ld      a,1
        ret
.compare_bad:
        xor     a
        ret

bios_pb:
        db      0,0
        dw      0,0,0
result_marker:
        db      'OP50'
pattern_a:
        db      10h,11h,12h,13h,14h,15h,16h,17h
        db      18h,19h,1ah,1bh,1ch,1dh,1eh,1fh
pattern_b:
        db      0a0h,0a1h,0a2h,0a3h,0a4h,0a5h,0a6h,0a7h
        db      0a8h,0a9h,0aah,0abh,0ach,0adh,0aeh,0afh
pattern_c:
        db      31h,32h,33h,34h,35h,36h,37h,38h
        db      39h,3ah,3bh,3ch,3dh,3eh,3fh,40h
pattern_d:
        db      51h,52h,53h,54h,55h,56h,57h,58h
        db      59h,5ah,5bh,5ch,5dh,5eh,5fh,60h
boundary_pattern:
        db      81h,82h,83h,84h,85h,86h,87h,88h
        db      91h,92h,93h,94h,95h,96h,97h,98h
selmem_register_expected:
        dw      1234h,5678h,09abch,1357h,2468h
        dw      2143h,6587h,0cba9h,7531h,8642h
overlap_initial:
        db      0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
overlap_expected:
        db      0,1,2,3,0,1,2,3,4,5,6,7,8,9,10,11
skew_table:
        db      9,7,5,3
character_expected:
        db      'CRT   ',03h
clock_phase_base:
        db      1,0,0,0
clock_phase_result:
        defs    4,0cch
scb_day_write:
        db      058h,0feh,034h,012h
scb_hour_write:
        db      05ah,0ffh,023h,0
scb_minute_write:
        db      05bh,0ffh,059h,0
scb_second_write:
        db      05ch,0ffh,047h,0
scb_day_read:
        db      058h,0,0,0
scb_hour_read:
        db      05ah,0,0,0
scb_minute_read:
        db      05bh,0,0,0
scb_second_read:
        db      05ch,0,0,0

; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Project-authored PCW bootstrap for the optional MAME integration test.
;
; MAME's PCW8256 driver copies exactly 256 bytes from offset 0300h of its
; printer-MCU region to Z80 RAM at 0002h, then starts the Z80 at 0000h. The
; project fixture implements the documented first-sector transfer through the
; published PCW ports and uPD765 command protocol. See REF-PCW-BOOT and
; REF-PCW-IO.
;
; The first physical sector is read to F000h and entered at F010h, which is
; the public PCW boot-disc contract used by OpenPCW-OS's boot.asm.

        org     0002h

bootstrap_entry:
        di
        ld      sp,0eff0h

; MAME currently establishes this mapping before copying the bootstrap, but
; make the loader independent of that implementation detail and match a cold
; PCW's first 64 KiB explicitly.
        ld      a,080h
        out     (0f0h),a
        inc     a
        out     (0f1h),a
        inc     a
        out     (0f2h),a
        inc     a
        out     (0f3h),a

        ld      a,9                     ; floppy motor on
        out     (0f8h),a
        ld      a,4                     ; synchronous polling, no FDC IRQ/NMI
        out     (0f8h),a

; Select non-DMA mode before the first transfer.  A reset uPD765 defaults to
; DMA handshaking, which deliberately reports overrun when a PCW polls it.
        ld      a,3                     ; SPECIFY
        call    fdc_write
        ld      a,04fh                  ; SRT/HUT
        call    fdc_write
        ld      a,3                     ; HLT plus ND=1
        call    fdc_write

; Allow the physical drive to reach speed.  MAME does not need the complete
; delay, but keeping it here makes the same 256-byte program hardware-sane.
        ld      b,10
.motor_tenth:
        push    bc
        ld      de,03c19h               ; about 100 ms at PCW Z80 speed
.motor_delay:
        dec     de
        ld      a,d
        or      e
        jr      nz,.motor_delay
        pop     bc
        djnz    .motor_tenth

; Recalibrate instead of assuming that the head was already on cylinder zero.
        ld      a,7
        call    fdc_write
        xor     a
        call    fdc_write
.recalibrate_irq:
        in      a,(0f8h)
        and     020h
        jr      z,.recalibrate_irq
        ld      a,8
        call    fdc_write
        call    fdc_read                ; ST0
        and     0c0h
        jr      nz,boot_error
        call    fdc_read                ; present cylinder
        or      a
        jr      nz,boot_error

; READ DATA: drive/head 0, C/H 0, sector 1, 512 bytes, single-sector EOT.
        ld      hl,0f000h
        ld      de,read_command
        ld      b,read_command_end-read_command
.command:
        ld      a,(de)
        inc     de
        call    fdc_write
        djnz    .command

        ld      bc,512
.data:
        call    fdc_read
        ld      (hl),a
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,.data

; Accept the benign End-Of-Cylinder tuple produced after a complete sector,
; as well as an all-zero status tuple, exactly like the MIT stage-two reader.
        call    fdc_read
        ld      b,a                     ; ST0
        call    fdc_read
        ld      c,a                     ; ST1
        call    fdc_read                ; ST2
        or      a
        jr      nz,boot_error
        ld      a,b
        or      a
        jr      z,.normal_status
        cp      040h
        jr      nz,boot_error
        ld      a,c
        cp      080h
        jr      z,.status_ok
        jr      boot_error
.normal_status:
        ld      a,c
        or      a
        jr      nz,boot_error
.status_ok:
        ld      b,4                     ; drain C/H/R/N
.drain:
        call    fdc_read
        djnz    .drain
        jp      0f010h

boot_error:
        ld      a,10                    ; motor off, then fail visibly/stably
        out     (0f8h),a
.hang:
        jr      .hang

fdc_write:
        push    bc
        ld      b,a
.write_wait:
        in      a,(0)
        and     0c0h
        cp      080h
        jr      nz,.write_wait
        ld      a,b
        out     (1),a
        pop     bc
        ret

fdc_read:
        in      a,(0)
        and     0c0h
        cp      0c0h
        jr      nz,fdc_read
        in      a,(1)
        ret

read_command:
        db      046h,0,0,0,1,2,1,02ah,0ffh
read_command_end:

bootstrap_end:
        defs    258-bootstrap_end,0

; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Native PCW second-stage loader. It talks to the uPD765A in non-DMA mode at
; ports 00h/01h and uses only documented PCW system-control and paging ports.
; The binary is embedded in boot.asm and relocated to B000h before execution.

        org     0b000h

; Physical block 8 is the private system page immediately below M:. It is
; outside both published CP/M banks and RAM-disc pages 9..15/31.
OPENPCW_RUNTIME_PAGE equ 088h

stage2_entry:
        di
        ld      sp,0eff0h

; The loader itself lives in physical block 2. Map physical block 7 at C000h
; so the final common kernel can be read directly to F200h.
        ld      a,087h
        out     (0f3h),a
        ld      a,9               ; floppy motor on
        out     (0f8h),a
        ld      a,4               ; ignore FDC IRQ/NMI; this loader polls
        out     (0f8h),a

; The current kernel occupies seven 512-byte sectors, physical IDs 2..8 on
; track zero. The builder rejects a payload that exceeds this explicit stage-1
; limit; the later banked kernel image will use the same reader over more
; tracks.
        ld      hl,0f200h
        ld      d,0               ; cylinder
        ld      e,2               ; first sector ID
.sector_loop:
        call    read_sector
        jr      c,boot_error
        inc     e
        ld      a,e
        cp      9
        jr      nz,.sector_loop

; Physical sector 9 follows the common image and starts the native hardware
; module. Tracks 1 through 6 provide the remaining sectors. The ordinary
; native image spans physical block 0 and protected physical block 8.
; It is independent of the common shell and remains hidden while applications
; use the conventional transient blocks 4,5,6,7.
        ld      a,080h
        out     (0f0h),a
        ld      a,OPENPCW_RUNTIME_PAGE
        out     (0f1h),a
        ld      hl,0100h
        ld      d,0
        ld      e,9
        call    read_sector
        jr      c,boot_error
        ld      d,1
.native_track:
        call    seek_track
        jr      c,boot_error
        ld      e,1
.native_loop:
        call    read_sector
        jr      c,boot_error
        inc     e
        ld      a,e
        cp      10
        jr      nz,.native_loop
        inc     d
        ld      a,d
        cp      7
        jr      nz,.native_track

; Track 7 holds the independently assembled service overlays. They run from
; physical block 3 through F2 only while a filesystem service is active,
; leaving the normal 48K transient mapping untouched at every public entry
; and return. The loader itself is still executing from F2/block 2, so
; populate block 3 through F1.
        ld      a,083h
        out     (0f1h),a
        ld      hl,04000h
        call    seek_track
        jr      c,boot_error
        ld      e,1
.overlay_loop:
        call    read_sector
        jr      c,boot_error
        inc     e
        ld      a,e
        cp      10
        jr      nz,.overlay_loop

; Enter the conventional 48K transient bank plus the resident common block.
        ld      a,084h
        out     (0f0h),a
        inc     a
        out     (0f1h),a
        inc     a
        out     (0f2h),a
        inc     a
        out     (0f3h),a
        jp      0f200h

boot_error:
        ld      a,10              ; stop the motor before exposing failure
        out     (0f8h),a
.hang:
        jr      .hang

seek_track:
        ld      a,00fh            ; SEEK
        call    fdc_write
        xor     a                 ; drive/head zero
        call    fdc_write
        ld      a,d               ; requested physical cylinder
        call    fdc_write
.wait_irq:
        in      a,(0f8h)
        and     020h
        jr      z,.wait_irq
        ld      a,8               ; SENSE INTERRUPT STATUS
        call    fdc_write
        call    fdc_read          ; ST0
        and     0c0h
        jr      nz,.seek_error
        call    fdc_read          ; present cylinder
        cp      d
        jr      nz,.seek_error
        or      a
        ret
.seek_error:
        scf
        ret

; Read one MFM 512-byte sector from drive/head zero. D=cylinder, E=sector ID,
; HL=destination. Returns HL advanced by 512 and carry set on a 765 error.
read_sector:
        ld      a,046h            ; READ DATA, MFM, single track
        call    fdc_write
        xor     a                 ; drive 0, head 0
        call    fdc_write
        ld      a,d               ; C
        call    fdc_write
        xor     a                 ; H
        call    fdc_write
        ld      a,e               ; R
        call    fdc_write
        ld      a,2               ; N: 512 bytes
        call    fdc_write
        ld      a,e               ; EOT: stop after this sector
        call    fdc_write
        ld      a,02ah            ; GPL
        call    fdc_write
        ld      a,0ffh            ; DTL (unused for N != 0)
        call    fdc_write

        ld      bc,512
.data:
        call    fdc_read
        ld      (hl),a
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,.data

; Result phase. A 765 reports ST0=40h/ST1=80h (End Of Cylinder) when EOT is
; the sector just consumed, despite having delivered its complete 512-byte
; payload. Accept that exact benign tuple as well as 00h/00h/00h; all other
; status combinations are real errors. This avoids depending on a host's
; timing for the PCW terminal-count gate-array line.
        call    fdc_read
        ld      b,a               ; ST0
        call    fdc_read
        ld      c,a               ; ST1
        call    fdc_read
        or      a                 ; ST2
        jr      nz,.result_error
        ld      a,b
        or      a
        jr      z,.normal_status
        cp      040h
        jr      nz,.result_error
        ld      a,c
        cp      080h
        jr      z,.status_ok
        jr      .result_error
.normal_status:
        ld      a,c
        or      a
        jr      nz,.result_error
.status_ok:
        ld      b,4
.drain:
        call    fdc_read
        djnz    .drain
        or      a                 ; clear carry
        ret
.result_error:
        scf
        ret

; Wait until RQM=1 and DIO=0, then send A to the data register.
fdc_write:
        push    bc
        ld      b,a
.wait:
        in      a,(0)
        and     0c0h
        cp      080h
        jr      nz,.wait
        ld      a,b
        out     (1),a
        pop     bc
        ret

; Wait until RQM=1 and DIO=1, then receive A from the data register.
fdc_read:
        in      a,(0)
        and     0c0h
        cp      0c0h
        jr      nz,fdc_read
        in      a,(1)
        ret

stage2_end:

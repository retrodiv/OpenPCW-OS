; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Project-authored native hardware module for the standalone OpenPCW-OS
; kernel, designed from REF-PCW-HARDWARE, REF-PCW-IO, REF-PCW-XBIOS, and
; REF-CPM3-PG.
; Its low executable page runs from physical block 0, its private runtime page
; uses protected physical block 8, outside both published CP/M banks and the
; M: RAM disc, while the resident common block 7 stays at C000h-FFFFh. See
; DES-NATIVE-001, DES-MEM-001, and VAL-BUILD-LAYOUT.

        org     0100h

; Physical block 8 is the private system page immediately below M:. It is
; outside published CP/M banks 0/1 (0..2 and 4..6), common block 7 and the
; RAM-disc pages 9..15/31. Takeover loaders may reuse system block 1.
OPENPCW_RUNTIME_PAGE        equ 088h
SPARSE_METADATA_PAGE        equ 083h
; Keep the independently loaded block-three overlays below offset 1200h. The
; sparse metadata occupies the remaining contiguous tail: 2 KiB directory,
; 768-byte allocation table and 384-byte validity map.
SPARSE_DIRECTORY_BASE       equ 05200h
SPARSE_DIRECTORY_F2_BASE    equ 09200h
SPARSE_ALLOCATION_BASE      equ 05a00h
SPARSE_VALIDITY_BASE        equ 05d00h
SPARSE_PASSWORD_BASE        equ 05e80h
SPARSE_PASSWORD_F2_BASE     equ 09e80h
SPARSE_LABEL_BASE           equ 06280h
SPARSE_LABEL_F2_BASE        equ 0a280h
SPARSE_PRIVATE_END          equ 06295h

; The deterministic builder generates these resident-handler addresses from
; kernel.asm's symbol file before assembling this separately linked module.
; This keeps the protected selector table symbolic and build-checked.
        include "kernel_dispatch.inc"

; Fixed internal common-bank state shared by the resident and hidden modules.
; kernel.asm pins both locations with explicit DEFS boundaries.
OPENPCW_COMMON_CURRENT_DISK equ 0f808h
OPENPCW_COMMON_SCB          equ 0f81bh
OPENPCW_COMMON_SCB_USER     equ 0f85fh
OPENPCW_COMMON_ERROR_MODE   equ 0f809h
OPENPCW_COMMON_ERROR_ABORT  equ KERNEL_NATIVE_PHYSICAL_ERROR_ABORT
OPENPCW_COMMON_SAVED_AF     equ 0f80ah
OPENPCW_COMMON_ARGUMENT_A   equ 0f816h
OPENPCW_COMMON_GENCOM_MODE  equ 0f818h
OPENPCW_COMMON_GENCOM_CHAIN equ 0f819h
OPENPCW_COMMON_TERMINAL_F7  equ 0f8bah
OPENPCW_COMMON_MULTISECTOR  equ 0f7f8h
OPENPCW_COMMON_DISK_PARAMS  equ 0ff80h
OPENPCW_COMMON_MOTOR_TICKS  equ 0ff8eh
motor_ready                 equ 0ff90h
; FF7Eh is a retained common-workspace word whose former private-interrupt
; owner is no longer present. Use its low byte for values which must survive
; a temporary F2 mapping without dirtying takeover-visible physical block 8.
OPENPCW_COMMON_TPA_BYTE     equ 0ff7eh
OPENPCW_COMMON_LOGIN_VECTOR equ 0ffd3h
OPENPCW_COMMON_RO_VECTOR    equ 0ffd5h
OPENPCW_COMMON_CLOCK_TICKS  equ 0fffch
OPENPCW_COMMON_RESTORE_PAGE equ 0fe31h
OPENPCW_COMMON_COMMAND_BUFFER equ 0f7a6h
; SELMEM owns this persistent bank-selection byte. RESTORE_PAGE instead
; describes the page in which an interrupted instruction must resume and is
; deliberately changed to the private system page while a native service runs.
OPENPCW_COMMON_RESUME_PAGE  equ 0ff65h
; Cold-only text shares the resident interrupt-stack source range. Interrupts
; remain disabled until the banner is complete, after which the bytes are free
; to serve their documented runtime stack purpose.
OPENPCW_COMMON_BANNER_PREFIX equ 0f389h
GENCOM_BIOS_ALIAS_BACKUP     equ 07fa0h

native_jump_table:
        jp      native_init
        jp      native_putc
        jp      native_status
        jp      native_getc
        jp      native_execute
        jp      native_open
        jp      native_read
        jp      native_seek_record
        jp      native_xbios_login
        jp      native_xbios_read_sector
        jp      native_prepare_gencom
        jp      native_sparse_write
        jp      native_sparse_read
        jp      native_m_bdos
        jp      native_disk_reset
        jp      native_xbios_low_read
        jp      native_bios_disk
        jp      native_direct_bios
        jp      native_bdos_console_status
        jp      native_read_line
        jp      native_userf_safe_dispatch

; Initialise the PCW roller table, the MIT-licensed font, display ports and terminal.
native_init:
; Install the small executable part of the public banked-BIOS ABI in unused
; common memory below the resident kernel. Keeping these routines outside the
; kernel's stacks prevents an interrupt or nested BIOS call from rewriting
; the code that performs the bank switch.
        ld      hl,bios_helper_blob
        ld      de,0f060h
        ld      bc,bios_helper_blob_end-bios_helper_blob
        ldir
        call    native_publish_bios_aliases

; Publish the current A: geometry in the ordinary CP/M 3 DPB format. The
; native login routine derives every field from the disk specification read
; from the active medium. See DES-FS-A-001 and REF-CPM3-PG.
        xor     a
        ld      (disk_logged_in),a
        ld      (cached_entry_valid),a
        ld      (sector_cache_valid),a
        call    native_detect_ram
        call    native_publish_disk_tables
        call    native_publish_char_table
        call    native_sparse_init
        call    native_xbios_disk_defaults

        xor     a
        ld      hl,native_default_password
        ld      b,8
.clear_default_password:
        ld      (hl),a
        inc     hl
        djnz    .clear_default_password
        ld      (cursor_x),a
        ld      (cursor_y),a
        ld      (key_pending),a
        ld      (key_pending_valid),a
        ld      (escape_state),a
        call    keyboard_init_page_one

; Build 256 documented roller words for the public PCW screen environment at
; 05930h (REF-PCW-XBIOS).  This conventional 720-byte lead row is observable
; through roller RAM by software that prepares a SCR RUN callback, so the
; terminal and application-facing screen view share the same origin.
; Eight interleaved lines occupy each 720-byte text row.
        ld      hl,05930h
        ld      de,0b600h
        ld      b,32
.roller_group:
        push    bc
        ld      b,8
.roller_line:
        push    hl
        ld      a,l
        ld      c,a
        srl     h
        rr      l
        ld      a,l
        and     0f8h
        ld      l,a
        ld      a,c
        and     7
        or      l
        ld      l,a
        ld      a,l
        ld      (de),a
        inc     de
        ld      a,h
        ld      (de),a
        inc     de
        pop     hl
        inc     hl
        djnz    .roller_line
        ld      bc,712
        add     hl,bc
        pop     bc
        djnz    .roller_group

; Unpack the 128 eight-row glyphs selected from the pinned Microsoft MIT
; font into character RAM. The high half aliases the low 7-bit alphabet.
; See DES-FONT-001 and docs/THIRD_PARTY.md for the complete source mapping.
        call    native_install_low_font
        ld      hl,0b800h
        ld      de,0bc00h
        ld      bc,1024
        ldir

        call    terminal_clear
        ld      a,05bh            ; roller table at physical 0B600h
        out     (0f5h),a
        xor     a
        out     (0f6h),a          ; top roller line
        ld      a,05fh
        out     (0f7h),a          ; display enabled, normal video
        ld      a,10
        jp      native_init_screen_vectors

; Runtime copy for the common-memory BIOS helpers. All bytes are assembled
; from this MIT source and copied verbatim by native_init. The first routine
; is installed at F060h; the padding places DRVTBL at F080h.
bios_helper_blob:
        cp      2
        ret     nc
        push    af
        di
        add     a,a
        add     a,a
        or      080h
        ld      (0fe31h),a
        ld      (0ff65h),a
        out     (0f0h),a
        inc     a
        out     (0f1h),a
        inc     a
        out     (0f2h),a
        ld      a,087h
        out     (0f3h),a
        pop     af
        ei
        ret
        defs    020h-($-bios_helper_blob),0
        ld      hl,0fb40h
        ret
bios_helper_blob_end:

; A=character. Implements the small control set used by the shell and BDOS.
native_putc:
        ld      (terminal_character),a
        ld      a,(escape_state)
        or      a
        jp      z,.normal_character
        cp      1
        jr      z,.escape_command
        cp      2
        jp      z,.escape_row
        cp      3
        jp      z,.escape_column
        cp      4
        jp      z,.escape_attribute
        cp      5
        jp      z,terminal_escape_view_top
        cp      6
        jp      z,terminal_escape_view_left
        cp      7
        jp      z,terminal_escape_view_height
        cp      8
        jp      z,terminal_escape_view_width
        ; Unknown parameter state: safely return to ordinary parsing.
        xor     a
        ld      (escape_state),a
        ret
.escape_command:
        ld      a,(terminal_character)
        cp      'Y'
        jr      z,.escape_begin_position
        cp      'X'
        jr      z,.escape_begin_view
        cp      'E'
        jr      z,.escape_clear
        cp      'H'
        jr      z,.escape_home
        cp      'A'
        jr      z,.escape_up
        cp      'B'
        jr      z,.escape_down
        cp      'C'
        jr      z,.escape_right
        cp      'D'
        jp      z,.escape_left
        cp      'b'
        jr      z,.escape_begin_colour
        cp      'c'
        jr      z,.escape_begin_colour
        cp      'e'
        jp      z,.escape_attribute
        cp      'f'
        jp      z,.escape_attribute
        cp      'p'
        jp      z,.escape_attribute
        cp      'q'
        jr      z,.escape_attribute
        cp      'u'
        jr      c,.escape_unknown
        cp      'z'                      ; u..y are accepted attributes
        jr      c,.escape_attribute
        ; PCW terminal modes 0 and 1 are accepted control selectors. Bytes
        ; below '2' have no printable meaning in this command position, so
        ; accepting that compact range also covers both selectors directly.
.escape_unknown:
        cp      '2'
        jr      c,.escape_attribute
        ; The published terminal fallback displays an unknown command byte.
        xor     a
        ld      (escape_state),a
        jp      .normal_character
.escape_begin_position:
        ld      a,2
        ld      (escape_state),a
        ret
.escape_begin_view:
        ld      a,5
        ld      (escape_state),a
        ret
.escape_begin_colour:
        ld      a,4
        ld      (escape_state),a
        ret
.escape_clear:
        xor     a
        ld      (escape_state),a
        jp      terminal_clear_viewport
.escape_home:
        ld      a,(terminal_view_left)
        ld      (cursor_x),a
        ld      a,(terminal_view_top)
        ld      (cursor_y),a
        jr      .escape_attribute
.escape_up:
        ld      a,(cursor_y)
        ld      b,a
        ld      a,(terminal_view_top)
        cp      b
        ld      a,b
        jr      nc,.escape_store_y
        dec     a
.escape_store_y:
        ld      (cursor_y),a
        jr      .escape_attribute
.escape_down:
        ld      a,(terminal_bottom_row)
        ld      b,a
        ld      a,(cursor_y)
        cp      b
        jr      nc,.escape_store_y
        inc     a
        jr      .escape_store_y
.escape_right:
        ld      a,(terminal_view_right)
        ld      b,a
        ld      a,(cursor_x)
        cp      b
        jr      nc,.escape_store_x
        inc     a
.escape_store_x:
        ld      (cursor_x),a
        jr      .escape_attribute
.escape_left:
        ld      a,(cursor_x)
        ld      b,a
        ld      a,(terminal_view_left)
        cp      b
        ld      a,b
        jr      nc,.escape_store_x
        dec     a
        jr      .escape_store_x
.escape_attribute:
        xor     a
        ld      (escape_state),a
        ret
.escape_row:
        ld      a,(terminal_character)
        sub     32
        jr      nc,.escape_row_nonnegative
        xor     a
.escape_row_nonnegative:
        ld      b,a
        ld      a,(terminal_bottom_row)
        ld      c,a
        ld      a,(terminal_view_top)
        ld      d,a
        ld      a,c
        sub     d
        cp      b
        jr      c,.escape_row_ready
        ld      a,b
.escape_row_ready:
        add     a,d
        ld      (escape_position_row),a
        ld      a,3
        ld      (escape_state),a
        ret
.escape_column:
        ld      a,(terminal_character)
        sub     32
        jr      nc,.escape_column_nonnegative
        xor     a
.escape_column_nonnegative:
        ld      b,a
        ld      a,(terminal_view_right)
        ld      c,a
        ld      a,(terminal_view_left)
        ld      d,a
        ld      a,c
        sub     d
        cp      b
        jr      c,.escape_column_ready
        ld      a,b
.escape_column_ready:
        add     a,d
        ld      (cursor_x),a
        ld      a,(escape_position_row)
        ld      (cursor_y),a
        jr      .escape_attribute
.normal_character:
        ld      a,(terminal_character)
        cp      27
        jr      z,.begin_escape
        cp      7
        ret     z
        cp      8
        jr      z,.backspace
        cp      9
        jr      z,.tab
        cp      10
        jr      z,.line_feed
        cp      12
        jp      z,terminal_clear_viewport
        cp      13
        jr      z,.carriage_return
        cp      32
        ret     c
        call    terminal_draw_cell
        ld      a,(cursor_x)
        ld      b,a
        ld      a,(terminal_view_right)
        cp      b
        ld      a,b
        jr      nz,.advance_x
        ld      a,(terminal_view_left)
        ld      (cursor_x),a
        jr      terminal_next_line
.advance_x:
        inc     a
        jr      .store_x
.begin_escape:
        ld      a,1
        ld      (escape_state),a
        ret
.store_x:
        ld      (cursor_x),a
        ret
.carriage_return:
        ld      a,(terminal_view_left)
        ld      (cursor_x),a
        ret
.line_feed:
        jr      terminal_next_line
.backspace:
        ld      a,(cursor_x)
        ld      b,a
        ld      a,(terminal_view_left)
        cp      b
        ret     nc
        ld      a,b
        dec     a
        ld      (cursor_x),a
        ld      a,' '
        jp      terminal_draw_cell
.tab:
        ld      a,' '
        call    native_putc
        ld      a,(cursor_x)
        ld      b,a
        ld      a,(terminal_view_left)
        ld      c,a
        ld      a,b
        sub     c
        and     7
        jr      nz,.tab
        ret

terminal_next_line:
        ld      a,(cursor_y)
        inc     a
        ld      b,a
        ld      a,(terminal_bottom_row)
        cp      b
        ld      a,b
        jr      nc,.store
        call    terminal_scroll
        ld      a,(terminal_bottom_row)
.store:
        ld      (cursor_y),a
        ret

; Draw A at the current 90x32 cell. Applications may redefine any of the 256
; public glyphs in the conventional B800h-BFFFh bitmap, so render from that
; writable table rather than from the immutable build-time font below. In this
; PCW layout the eight scanlines of a character are adjacent; successive
; character columns are eight bytes apart.
terminal_draw_cell:
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      de,0b800h
        add     hl,de
        push    hl

        ld      hl,05930h
        ld      a,(cursor_y)
        or      a
        jr      z,.row_ready
        ld      b,a
        ld      de,720
.add_row:
        add     hl,de
        djnz    .add_row
.row_ready:
        ld      a,(cursor_x)
        ld      e,a
        ld      d,0
        ex      de,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,de
        ex      de,hl                    ; DE=physical screen destination
        pop     hl                       ; HL=writable glyph bitmap
        ld      bc,8
        jp      native_screen_copy_private

; Return FFh when a translated character is buffered, zero otherwise. The
; page-one keyboard engine owns raw numbering, five translation states,
; expansion strings and the documented repeat timing.
native_status:
        ld      a,(key_pending_valid)
        or      a
        jr      nz,.ready
        call    keyboard_scan
        jr      nc,.none
        ld      (key_pending),a
        ld      a,1
        ld      (key_pending_valid),a
.ready:
        ld      a,0ffh
        ret
.none:
        xor     a
        ret

; BDOS Function 11 has a narrower result contract than BIOS CONST or Direct
; Console status: ready is 01h rather than FFh, and Console Mode bit zero asks
; it to report only a pending CTRL-C. The character remains buffered.
native_bdos_console_status:
        call    native_status
        or      a
        ret     z
        ld      a,(OPENPCW_COMMON_SCB+033h)
        and     1
        jr      z,.bdos_ready
        ld      a,(key_pending)
        cp      3
        jr      nz,.bdos_none
.bdos_ready:
        ld      a,1
        ret
.bdos_none:
        xor     a
        ret

native_getc:
.wait:
        call    native_status
        or      a
        jr      z,.wait
        ld      a,(key_pending)
        ld      b,a
        xor     a
        ld      (key_pending_valid),a
        ld      a,b
        ret

; A CP/M disk-system reset forgets derived geometry and cached sectors so the
; next login rebuilds filesystem state. The separately retained DD L XDPB
; specification survives Function 13; shell media exchange and DD INIT use
; native_disk_media_reset when they intentionally begin a new media lifecycle.
native_disk_reset:
        xor     a
        ld      (disk_logged_in),a
        ld      (cached_entry_valid),a
        ld      (sector_cache_valid),a
        ret

; Publish the drive table and the two project-authored DPHs for plain COMs as
; well as GENCOM containers. The documented pointers and DPB geometry are
; populated from the active A: medium and this kernel's volatile sparse M:
; RAM disk. See DES-FS-A-001, DES-FS-M-001, and REF-CPM3-PG.
native_publish_disk_tables:
        xor     a
        ld      hl,0fb40h
        ld      de,0fb41h
        ld      (hl),a
        ld      bc,051h
        ldir
        ld      hl,0fb60h
        ld      (0fb40h),hl
        ld      hl,0fb79h
        ld      (0fb58h),hl
        ld      hl,0fb9ch
        ld      (0fb6ch),hl
        ld      hl,0fbc0h
        ld      (0fb85h),hl
        ld      hl,native_a_alv
        ld      (0fb70h),hl
        ld      hl,native_m_alv
        ld      (0fb89h),hl
        ld      ix,0fb9ch
        ld      c,0
        call    native_xbios_login
        ld      hl,gencom_m_dpb
        ld      de,0fbc0h
        ld      bc,gencom_m_dpb_end-gencom_m_dpb
        ldir
        ld      a,(native_m_blocks)
        dec     a
        ld      (0fbc5h),a
        xor     a
        ld      (0fbc6h),a
        ret

; Determine whether page 25 is independent from page 9. Extended PCW paging
; wraps the page number at 16 pages on a 256 KiB machine and at 32 pages on a
; 512 KiB machine. The probe preserves the byte it touches, so it is valid on
; emulators and physical hardware and does not depend on a model identifier.
native_detect_ram:
        ld      a,089h
        out     (0f1h),a
        ld      a,(04000h)
        ld      (native_ram_probe_page9),a
        ld      b,a
        cpl
        ld      c,a
        ld      a,099h
        out     (0f1h),a
        ld      a,(04000h)
        ld      (native_ram_probe_page25),a
        ld      a,c
        ld      (04000h),a
        ld      a,089h
        out     (0f1h),a
        ld      a,(04000h)
        cp      b
        jr      nz,.ram_is_256k
        ld      a,099h
        out     (0f1h),a
        ld      a,(native_ram_probe_page25)
        ld      (04000h),a
        ld      a,32
        jr      .ram_size_ready
.ram_is_256k:
        ld      a,16
.ram_size_ready:
        ld      (native_ram_pages),a
        ld      a,089h
        out     (0f1h),a
        ld      a,(native_ram_probe_page9)
        ld      (04000h),a
        ld      a,OPENPCW_RUNTIME_PAGE
        out     (0f1h),a
        ld      a,(native_ram_pages)
        ; The ordinary PCW M: layout starts at page 9 and extends through the
        ; final physical page. Its first two 2 KiB blocks hold the directory;
        ; every remaining block is data. The private sparse metadata lives in
        ; protected block 3 and therefore does not reduce public capacity.
        sub     9
        add     a,a
        add     a,a
        add     a,a
        ld      (native_m_blocks),a
        sub     2
        ld      (native_m_data_blocks),a
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      (native_m_records),hl
        ret

native_publish_char_table:
        ld      hl,native_character_table
        ld      de,0fb30h
        ld      bc,native_character_table_end-native_character_table
        ldir
        ret

; CP/M Plus public disk BIOS ------------------------------------------------
;
; Entry 0130h is called by the common-memory vectors.  A is an internal
; operation number; the documented BIOS parameters remain in A/BC/DE as
; appropriate (SETBNK's input A is carried in C by its tiny common stub).
; Physical A: requests use the same independently written geometry parser and
; uPD765 engine as XBIOS.  Transfers are write-through, so FLUSH is immediate.
native_bios_disk:
        cp      14
        jp      nc,.bios_bad
        push    de
        push    hl
        ld      l,a
        ld      h,0
        add     hl,hl
        ld      de,.bios_table
        add     hl,de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      (bios_dispatch_jump+1),de
        pop     hl
        pop     de
bios_dispatch_jump:
        jp      0000h
.bios_table:
        dw      .bios_home,.bios_select,.bios_set_track,.bios_set_sector
        dw      .bios_set_dma,.bios_read,.bios_write,.bios_multio
        dw      .bios_flush,.bios_set_bank,.bios_move,.bios_time
        dw      .bios_xmove,.bios_sector_translate

.bios_home:
        ld      hl,0
        ld      (bios_track),hl
        xor     a
        ret
.bios_select:
        ld      a,c
        or      a
        jr      z,.bios_select_a
        cp      12
        jr      z,.bios_select_m
.bios_select_bad:
        ld      hl,0
        xor     a
        ret
.bios_select_a:
        call    disk_login
        jr      c,.bios_select_bad
        xor     a
        ld      (bios_drive),a
        ld      hl,0fb60h
        ret
.bios_select_m:
        ld      a,12
        ld      (bios_drive),a
        ld      hl,0fb79h
        xor     a
        ret
.bios_set_track:
        ld      (bios_track),bc
        xor     a
        ret
.bios_set_sector:
        ld      (bios_sector),bc
        xor     a
        ret
.bios_set_dma:
        ld      (bios_dma),bc
        xor     a
        ret
.bios_multio:
        ld      a,c
        or      a
        jr      nz,.bios_multio_ready
        inc     a
.bios_multio_ready:
        ld      (bios_multisector),a
        xor     a
        ret
.bios_flush:
        xor     a
        ret
.bios_set_bank:
        ld      a,c
        cp      2
        jr      nc,.bios_bad
        ld      (bios_dma_bank),a
        xor     a
        ret
.bios_move:
        jp      native_bios_move
.bios_time:
        jp      native_bios_time
.bios_xmove:
        jp      native_bios_xmove
.bios_sector_translate:
        jp      native_bios_sector_translate
.bios_bad:
        ld      a,1
        ret

.bios_transfer_setup:
        ld      a,(bios_drive)
        or      a
        jr      nz,.bios_bad
        ld      a,(bios_dma_bank)
        cp      2
        jr      nc,.bios_bad
        ld      hl,(bios_track)
        ld      (bios_work_track),hl
        ld      hl,(bios_sector)
        ld      (bios_work_sector),hl
        ld      hl,(bios_dma)
        ld      (bios_work_dma),hl
        ld      a,(bios_multisector)
        or      a
        jr      nz,.bios_transfer_count
        inc     a
.bios_transfer_count:
        ld      (bios_remaining),a
        xor     a
        ret

.bios_read:
        call    .bios_transfer_setup
        or      a
        ret     nz
.bios_read_next:
        call    .bios_read_current
        or      a
        ret     nz
        call    .bios_advance
        ld      a,(bios_remaining)
        dec     a
        ld      (bios_remaining),a
        jr      nz,.bios_read_next
        xor     a
        ret

.bios_read_current:
        ld      a,(bios_work_track+1)
        or      a
        jr      nz,.bios_bad
        ld      a,(bios_work_sector+1)
        or      a
        jr      nz,.bios_bad
        ld      hl,(bios_work_dma)
        ld      a,(bios_dma_bank)
        ld      b,a
        ld      c,0                       ; transfer setup accepted only A:
        ld      a,(bios_work_track)
        ld      d,a
        ld      a,(bios_work_sector)
        ld      e,a
        xor     a                        ; internal BIOS path always transfers
        ; DD READ SECTOR takes its sector-ID base from the caller's XDPB.
        ; The ordinary BIOS has no IX parameter, so select the active A: XDPB
        ; published by SELDSK before sharing the documented XBIOS primitive.
        ld      ix,0fb9ch
        call    native_xbios_read_sector
        or      a
        ret     z
        ld      a,1
        ret

.bios_write:
        call    .bios_transfer_setup
        or      a
        ret     nz
.bios_write_next:
        call    .bios_write_current
        or      a
        ret     nz
        call    .bios_advance
        ld      a,(bios_remaining)
        dec     a
        ld      (bios_remaining),a
        jr      nz,.bios_write_next
        xor     a
        ret

.bios_write_current:
        ld      a,(bios_work_track+1)
        or      a
        jp      nz,.bios_bad
        ld      a,(bios_work_sector+1)
        or      a
        jp      nz,.bios_bad
        ld      hl,(bios_work_dma)
        ld      a,(bios_dma_bank)
        ld      b,a
        ld      c,0                       ; transfer setup accepted only A:
        ld      a,(bios_work_track)
        ld      d,a
        ld      a,(bios_work_sector)
        ld      e,a
        call    native_xbios_write_sector
        or      a
        ret     z
        cp      1
        ld      a,2                    ; CP/M BIOS write-protected result
        ret     z
        ld      a,1
        ret

.bios_advance:
        ld      hl,(bios_work_dma)
        ld      de,512
        add     hl,de
        ld      (bios_work_dma),hl
        ld      hl,(bios_work_sector)
        inc     hl
        ld      (bios_work_sector),hl
        ld      a,h
        or      a
        ret     nz
        ld      a,(disk_sectors)
        cp      l
        ret     nz
        ld      hl,0
        ld      (bios_work_sector),hl
        ld      hl,(bios_work_track)
        inc     hl
        ld      (bios_work_track),hl
        ret

; MOVE copies within the bank currently selected by SELMEM, unless a preceding
; XMOVE supplied one-shot source/destination banks.  The copy is memmove-safe
; for overlapping same-bank ranges and returns BC=0 with DE/HL advanced as the
; published BIOS contract requires.
native_bios_move:
        ld      a,(bios_xmove_pending)
        or      a
        jr      nz,.move_banks_ready
        ld      a,(OPENPCW_COMMON_RESUME_PAGE)
        srl     a
        srl     a
        and     1
        ld      (bios_move_source_bank),a
        ld      (bios_move_destination_bank),a
.move_banks_ready:
        xor     a
        ld      (bios_xmove_pending),a

        push    hl
        add     hl,bc
        ld      (bios_move_return_hl),hl
        pop     hl
        push    hl
        push    de
        ex      de,hl
        add     hl,bc
        ld      (bios_move_return_de),hl
        pop     de
        pop     hl
        ld      a,b
        or      c
        jr      z,.move_done

        push    bc
        ld      a,(bios_move_source_bank)
        ld      b,a
        ld      a,(bios_move_destination_bank)
        cp      b
        pop     bc
        jr      nz,.move_forward
        push    hl
        or      a
        sbc     hl,de
        jr      c,.move_not_overlap
        jr      z,.move_not_overlap
        or      a
        sbc     hl,bc
        pop     hl
        jr      c,.move_backward_prepare
        jr      .move_forward
.move_not_overlap:
        pop     hl
        jr      .move_forward

.move_backward_prepare:
        push    bc
        dec     bc
        add     hl,bc
        ex      de,hl
        add     hl,bc
        ex      de,hl
        pop     bc
.move_backward:
        ex      de,hl
        call    native_bios_move_read
        ex      de,hl
        call    native_bios_move_write
        dec     de
        dec     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,.move_backward
        jr      .move_done

.move_forward:
        ex      de,hl
        call    native_bios_move_read
        ex      de,hl
        call    native_bios_move_write
        inc     de
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,.move_forward
.move_done:
        ld      de,(bios_move_return_de)
        ld      hl,(bios_move_return_hl)
        ld      bc,0
        xor     a
        ret

; Read/write one abstract address through F1 while the native service code
; remains executable in physical page 0 at F0. Addresses in C000h-FFFFh always
; resolve to common physical page 7, independent of the selected CP/M bank.
native_bios_move_read:
        push    bc
        ld      c,h
        ld      a,h
        cp      0c0h
        jr      nc,.move_read_common
        and     0c0h
        rlca
        rlca
        ld      b,a
        ld      a,(bios_move_source_bank)
        add     a,a
        add     a,a
        add     a,b
        or      080h
        jr      .move_read_map
.move_read_common:
        ld      a,087h
.move_read_map:
        out     (0f1h),a
        ld      a,h
        and     03fh
        or      040h
        ld      h,a
        ld      a,(hl)
        ld      h,c
        pop     bc
        ret

native_bios_move_write:
        push    bc
        ld      b,a
        ld      c,h
        ld      a,h
        cp      0c0h
        jr      nc,.move_write_common
        and     0c0h
        rlca
        rlca
        push    bc
        ld      b,a
        ld      a,(bios_move_destination_bank)
        add     a,a
        add     a,a
        add     a,b
        pop     bc
        or      080h
        jr      .move_write_map
.move_write_common:
        ld      a,087h
.move_write_map:
        out     (0f1h),a
        ld      a,h
        and     03fh
        or      040h
        ld      h,a
        ld      a,b
        ld      (hl),a
        ld      h,c
        pop     bc
        ret

native_bios_time:
        ld      a,c
        cp      0ffh
        jr      nz,.time_done
        push    hl
        ld      hl,300
        ld      (OPENPCW_COMMON_CLOCK_TICKS),hl
        pop     hl
.time_done:
        xor     a
        ret

native_bios_xmove:
        ld      a,b
        cp      2
        jr      nc,.xmove_bad
        ld      (bios_move_destination_bank),a
        ld      a,c
        cp      2
        jr      nc,.xmove_bad
        ld      (bios_move_source_bank),a
        ld      a,1
        ld      (bios_xmove_pending),a
        xor     a
        ret
.xmove_bad:
        ld      a,1
        ret

native_bios_sector_translate:
        ld      a,d
        or      e
        jr      nz,.sector_table
        ld      h,b
        ld      l,c
        xor     a
        ret
.sector_table:
        ex      de,hl
        add     hl,bc
        ld      a,(bios_move_source_bank)
        push    af
        ld      a,(OPENPCW_COMMON_RESUME_PAGE)
        srl     a
        srl     a
        and     1
        ld      (bios_move_source_bank),a
        call    native_bios_move_read
        ld      c,a
        pop     af
        ld      (bios_move_source_bank),a
        ld      l,c
        ld      h,0
        xor     a
        ret

; BDOS 50 entry at 0133h.  Read the documented eight-byte BIOS parameter
; block from transient bank 1, restore its requested register file, and invoke
; the corresponding independently implemented BIOS primitive. Function 27 is
; deliberately intercepted: CP/M Plus requires BDOS 50 SELMEM to return A=0
; without mapping the caller out of memory.
native_direct_bios:
        push    de
        pop     hl
        call    gencom_tpa_read
        ld      (direct_bios_function),a
        inc     hl
        call    gencom_tpa_read
        ld      (direct_bios_a),a
        inc     hl
        call    gencom_tpa_read
        ld      (direct_bios_bc),a
        inc     hl
        call    gencom_tpa_read
        ld      (direct_bios_bc+1),a
        inc     hl
        call    gencom_tpa_read
        ld      (direct_bios_de),a
        inc     hl
        call    gencom_tpa_read
        ld      (direct_bios_de+1),a
        inc     hl
        call    gencom_tpa_read
        ld      (direct_bios_hl),a
        inc     hl
        call    gencom_tpa_read
        ld      (direct_bios_hl+1),a
        ; gencom_tpa_read deliberately leaves F1 on the transient page that
        ; supplied the BIOSPB byte.  Direct BIOS disk primitives can call
        ; helpers which execute from the private runtime page at 4000h, so
        ; restore that page before dispatching the requested function.
        ld      a,OPENPCW_RUNTIME_PAGE
        out     (0f1h),a
        ld      bc,(direct_bios_bc)
        ld      de,(direct_bios_de)
        ld      hl,(direct_bios_hl)
        ld      a,(direct_bios_function)
        sub     2
        cp      28
        jr      nc,.direct_bad
        ld      e,a
        ld      d,0
        ld      hl,.direct_table
        add     hl,de
        add     hl,de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      (direct_dispatch_jump+1),de
        ld      de,(direct_bios_de)
        ld      hl,(direct_bios_hl)
direct_dispatch_jump:
        jp      0000h
.direct_bad:
        ld      a,0ffh
        ret
.direct_table:
        dw      .direct_const,.direct_conin,.direct_conout,.direct_no_output
        dw      .direct_no_output,.direct_reader,.direct_home,.direct_select
        dw      .direct_set_track,.direct_set_sector,.direct_set_dma
        dw      .direct_read,.direct_write,.direct_not_ready,.direct_sector
        dw      .direct_ready,.direct_not_ready,.direct_ready,.direct_devtbl
        dw      .direct_no_output,.direct_drvtbl,.direct_multio,.direct_flush
        dw      .direct_move,.direct_time,.direct_selmem,.direct_set_bank
        dw      .direct_xmove
.direct_const:
        jp      native_status
.direct_conin:
        jp      native_getc
.direct_conout:
        ld      a,c
        jp      native_putc
.direct_no_output:
        xor     a
        ret
.direct_reader:
        ld      a,01ah
        ret
.direct_home:
        xor     a
        jp      native_bios_disk
.direct_select:
        ld      a,1
        jp      native_bios_disk
.direct_set_track:
        ld      a,2
        jp      native_bios_disk
.direct_set_sector:
        ld      a,3
        jp      native_bios_disk
.direct_set_dma:
        ld      a,4
        jp      native_bios_disk
.direct_write:
        ld      a,6
        jp      native_bios_disk
.direct_not_ready:
        xor     a
        ret
.direct_sector:
        ld      a,13
        jp      native_bios_disk
.direct_ready:
        ld      a,0ffh
        ret
.direct_devtbl:
        ld      hl,0fb30h
        xor     a
        ret
.direct_drvtbl:
        ld      hl,0fb40h
        xor     a
        ret
.direct_multio:
        ld      a,7
        jp      native_bios_disk
.direct_flush:
        ld      a,8
        jp      native_bios_disk
.direct_move:
        ld      a,10
        jp      native_bios_disk
.direct_time:
        ld      a,11
        jp      native_bios_disk
.direct_selmem:
        xor     a
        ret
.direct_set_bank:
        ld      a,(direct_bios_a)
        ld      c,a
        ld      a,9
        jp      native_bios_disk
.direct_xmove:
        ld      a,12
        jp      native_bios_disk

; DD LOGIN (XBIOS 0092h). Discover the inserted medium and publish the
; documented 27-byte XDPB at IX. Return the format number in A with carry
; clear, or FFh with carry set when drive A cannot be logged in.
native_xbios_login:
        ld      a,c
        and     3
        jp      nz,.login_bad
        call    disk_login
        jp      c,.login_bad
        push    ix
        pop     hl
        ld      b,27
        xor     a
.login_clear:
        ld      (hl),a
        inc     hl
        djnz    .login_clear

        ld      a,(disk_sectors)
        add     a,a
        add     a,a
        ld      (ix+0),a                 ; 128-byte records per track
        ld      a,(disk_block_shift)
        ld      (ix+2),a
        ld      b,a
        ld      a,1
.login_block_mask:
        add     a,a
        djnz    .login_block_mask
        dec     a
        ld      (ix+3),a

        ld      a,(disk_block_shift)
        ld      b,a
        ld      a,(disk_dsm+1)
        or      a
        ld      a,b
        jr      z,.login_small_exm
        dec     a
.login_small_exm:
        sub     3
        ld      b,a
        ld      a,1
        jr      z,.login_exm_ready
.login_exm_scale:
        add     a,a
        djnz    .login_exm_scale
.login_exm_ready:
        dec     a
        ld      (ix+4),a

        ld      hl,(disk_dsm)
        ld      (ix+5),l
        ld      (ix+6),h
        ld      a,(disk_block_shift)
        ld      b,a
        ld      e,4
.login_dir_scale:
        sla     e
        djnz    .login_dir_scale
        ld      a,(disk_dir_blocks)
        call    multiply_8
        dec     hl
        ld      (ix+7),l
        ld      (ix+8),h
        inc     hl
        srl     h
        rr      l
        srl     h
        rr      l
        ld      (ix+11),l
        ld      (ix+12),h

        ld      a,(disk_dir_blocks)
        cp      17
        jp      nc,.login_bad
        ld      b,a
        ld      a,16
        sub     b
        ld      b,a
        ld      hl,0ffffh
        jr      z,.login_allocation_ready
.login_allocation_shift:
        add     hl,hl
        djnz    .login_allocation_shift
.login_allocation_ready:
        ld      (ix+9),h
        ld      (ix+10),l
        ld      a,(disk_reserved)
        ld      (ix+13),a
        ld      (ix+15),2                ; 512-byte physical sectors
        ld      (ix+16),3
        ld      a,(disk_side_mode)
        ld      (ix+17),a
        ld      a,(disk_tracks)
        ld      (ix+18),a
        ld      a,(disk_sectors)
        ld      (ix+19),a
        ld      a,(disk_sector_base)
        ld      (ix+20),a
        xor     a
        ld      (ix+21),a
        ld      a,2
        ld      (ix+22),a
        ld      a,02ah
        ld      (ix+23),a
        ld      a,052h
        ld      (ix+24),a
        ld      a,060h
        ld      (ix+25),a

        ld      a,(disk_sector_base)
        cp      041h
        ld      a,1
        jr      z,.login_good
        ld      a,(disk_sector_base)
        cp      0c1h
        ld      a,2
        jr      z,.login_good
        ld      a,(disk_side_mode)
        or      a
        jr      z,.login_good
        ld      a,3
.login_good:
        ; DD LOGIN also returns the allocation-vector length in DE and the
        ; four-byte-per-directory-entry hash-table length in HL.  Several
        ; PCW loaders consume these documented results immediately instead
        ; of re-reading the XDPB, so do not leak our working registers here.
        push    af
        ld      hl,(disk_dsm)
        srl     h
        rr      l
        srl     h
        rr      l
        inc     hl
        inc     hl
        ex      de,hl                   ; DSM / 4 + 2 allocation bytes
        ld      l,(ix+7)
        ld      h,(ix+8)
        inc     hl                      ; DRM + 1 directory entries
        add     hl,hl
        add     hl,hl                   ; four hash bytes per entry
        pop     af
        or      a
        ret
.login_bad:
        ld      a,0ffh
        scf
        ret

; DD READ/CHECK SECTOR (XBIOS 0086h/008Ch). A selects transfer (zero) or
; comparison (one), B selects either published CP/M bank, C drive A, D the
; logical track, E the zero-based logical sector, and HL the memory address.
; The common wrapper turns the compact native result (zero success/equal, one
; different, four error) into each documented flag contract.
native_xbios_read_sector:
        ld      (xbios_check_mode),a
        ld      a,c
        and     3
        jr      nz,.read_bad
        ld      a,b
        cp      2
        jr      nc,.read_bad
        ld      (xbios_bank),a
        ld      a,e
        ld      (xbios_sector),a
        ld      (xbios_destination),hl
        push    de                      ; preserve the requested track/sector
        ld      de,0fe01h                ; a 512-byte request may start at FE00h
        or      a
        sbc     hl,de
        jr      nc,.read_bad_pop
        call    disk_login
        pop     de
        jr      c,.read_bad
        call    native_map_physical_sector
        jr      c,.read_bad
        ; DD READ/CHECK SECTOR receives IX as the public Amstrad XDPB.  Its
        ; first-physical-sector field is intentionally mutable: protected
        ; media use the freeze flag and replace this byte to address unusual
        ; sector IDs on an otherwise ordinary track.  The shared mapper above
        ; has already validated the logical track/sector and selected the
        ; cylinder/head; publish the XDPB-derived R byte before issuing READ.
        ld      a,(xbios_sector)
        add     a,(ix+20)
        ld      e,a
        ld      hl,sector_buffer
        call    fdc_read_sector
        jr      c,.read_bad
        ld      hl,(xbios_destination)
        ld      de,sector_buffer
        ld      bc,512
        ld      a,(xbios_check_mode)
        or      a
        jr      nz,.check_sector
.transfer_sector:
        ld      a,(de)
        call    xbios_cpm_write
        inc     hl
        inc     de
        dec     bc
        ld      a,b
        or      c
        jr      nz,.transfer_sector
        xor     a
        ret
.check_sector:
        call    xbios_cpm_read
        ex      de,hl
        cp      (hl)
        ex      de,hl
        jr      nz,.check_different
        inc     hl
        inc     de
        dec     bc
        ld      a,b
        or      c
        jr      nz,.check_sector
        xor     a
        ret
.check_different:
        ld      a,1
        ret
.read_bad_pop:
        pop     de
.read_bad:
        ld      a,4
        scf
        ret

; Read or write one byte through either published CP/M bank while this native
; module remains executable in physical block zero. F1 is a disposable 16K
; window: bank 0 uses PCW blocks 0/1/3, bank 1 uses 4/5/6, and both use common
; block 7 for C000h-FFFFh. Both byte helpers preserve HL and BC.
xbios_cpm_map:
        ld      c,h
        ld      a,h
        and     0c0h
        rlca
        rlca
        ld      b,a                     ; logical 16K page 0..3
        cp      3
        jr      z,.cpm_common
        ld      a,(xbios_bank)
        or      a
        ld      a,b
        jr      z,.cpm_system
        add     a,4
        jr      .cpm_page_ready
.cpm_system:
        cp      2
        jr      nz,.cpm_page_ready
        inc     a                        ; logical page 2 uses physical block 3
        jr      .cpm_page_ready
.cpm_common:
        ld      a,7
.cpm_page_ready:
        or      080h
        out     (0f1h),a
        ld      a,c
        and     03fh
        or      040h
        ld      h,a
        ret

xbios_cpm_read:
        push    bc
        call    xbios_cpm_map
        ld      a,(hl)
        ld      h,c
        pop     bc
        ret

xbios_cpm_write:
        push    bc
        push    af
        call    xbios_cpm_map
        pop     af
        ld      (hl),a
        ld      h,c
        pop     bc
        ret

; Map a zero-based logical CP/M physical-sector location to the controller's
; cylinder/head/R identifier.  Input D=logical track and E=sector index;
; output D=cylinder, C=head and E=R after a successful seek.  The mapping is
; shared by XBIOS and the public BIOS read/write paths.
native_map_physical_sector:
        ld      a,e
        ld      b,a
        ld      a,(disk_sectors)
        cp      b
        jr      c,.physical_bad
        jr      z,.physical_bad
        ld      a,(disk_side_mode)
        ld      b,a
        or      a
        jr      z,.physical_one_side
        ld      a,(disk_tracks)
        add     a,a
        cp      d
        jr      c,.physical_bad
        jr      z,.physical_bad
        ld      a,b
        cp      1
        jr      nz,.physical_successive
        ld      a,d
        and     1
        ld      c,a
        srl     d
        jr      .physical_location_ready
.physical_successive:
        ld      a,(disk_tracks)
        cp      d
        jr      c,.physical_second_side
        jr      z,.physical_second_side
        ld      c,0
        jr      .physical_location_ready
.physical_second_side:
        add     a,a
        dec     a
        sub     d
        ld      d,a
        ld      c,1
        jr      .physical_location_ready
.physical_one_side:
        ld      a,(disk_tracks)
        cp      d
        jr      c,.physical_bad
        jr      z,.physical_bad
        ld      c,0
.physical_location_ready:
        ld      a,(disk_sector_base)
        add     a,e
        ld      e,a
        push    bc
        ld      a,d
        call    fdc_seek
        pop     bc
        ret
.physical_bad:
        scf
        ret

; DD L READ (XBIOS 00ADh). HL addresses the documented common-memory
; descriptor: CP/M bank, destination, byte count, command length, then a raw
; uPD765 read command. This interface permits raw sector access outside
; filesystem services, so perform the transfer through the real controller
; and return the ordinary seven-byte result packet at FFE1h (length at FFE0h).
native_xbios_low_read:
        push    hl
        pop     ix
        ld      a,h
        cp      0c0h
        jp      c,.low_invalid
        ld      a,(ix+0)
        cp      2
        jp      nc,.low_invalid
        ld      (low_bank),a
        ld      l,(ix+1)
        ld      h,(ix+2)
        ld      (low_address),hl
        ld      e,(ix+3)
        ld      d,(ix+4)
        ld      (low_remaining),de
        ld      a,d
        or      e
        jp      z,.low_invalid
        add     hl,de
        jr      nc,.low_range_ok
        ld      a,h
        or      l
        jp      nz,.low_invalid
.low_range_ok:
        ld      a,(ix+5)
        cp      9
        jp      c,.low_invalid
        cp      17
        jp      nc,.low_invalid
        ld      a,(ix+6)
        and     01fh
        cp      6
        jr      z,.low_command_ok
        cp      0ch
        jp      nz,.low_invalid
.low_command_ok:
        ld      a,(ix+6)
        ld      (low_command),a
        ld      a,(ix+7)
        ld      (low_unit),a
        ld      a,(ix+7)
        rrca
        rrca
        and     1
        ld      (low_side),a
        ld      a,(ix+8)
        ld      (low_cylinder),a
        ld      a,(ix+10)
        ld      (low_sector),a
        ld      a,(ix+9)
        ld      (low_head),a
        ld      a,(ix+11)
        cp      7
        jr      nc,.low_invalid
        ld      (low_n),a
        ld      a,(ix+12)
        ld      (low_end_sector),a
        ld      a,(ix+13)
        ld      (low_gpl),a
        ld      a,(ix+14)
        ld      (low_dtl),a

        ld      a,9
        out     (0f8h),a
        ld      a,4
        out     (0f8h),a
        ld      a,(low_cylinder)
        call    fdc_seek
        jr      c,.low_no_data
.low_next_sector:
        call    fdc_low_read_sector
        jr      c,.low_no_data
        ld      hl,(low_remaining)
        ld      a,h
        or      l
        jr      z,.low_success
        ld      a,(low_sector)
        ld      b,a
        ld      a,(low_end_sector)
        cp      b
        jr      z,.low_no_data
        inc     b
        ld      a,b
        ld      (low_sector),a
        jr      .low_next_sector

.low_success:
        ld      hl,0ffe0h
        ld      (hl),7
        inc     hl
        ld      a,(low_side)
        add     a,a
        add     a,a
        ld      (hl),a
        inc     hl
        xor     a
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      a,(low_cylinder)
        ld      (hl),a
        inc     hl
        ld      a,(low_side)
        ld      (hl),a
        inc     hl
        ld      a,(low_sector)
        ld      (hl),a
        inc     hl
        ld      (hl),2
        ld      hl,0ffe0h
        xor     a
        ret

.low_no_data:
        ld      a,(low_side)
        add     a,a
        add     a,a
        or      040h
        jr      .low_error_packet
.low_invalid:
        ld      a,040h
.low_error_packet:
        ld      hl,0ffe0h
        ld      (hl),7
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),4
        inc     hl
        xor     a
        ld      (hl),a
        inc     hl
        ld      a,(low_cylinder)
        ld      (hl),a
        inc     hl
        ld      a,(low_side)
        ld      (hl),a
        inc     hl
        ld      a,(low_sector)
        ld      (hl),a
        inc     hl
        ld      (hl),2
        ld      hl,0ffe0h
        ld      a,4
        scf
        ret

; Execute one raw uPD765 sector transfer using the N value supplied by the
; caller. This is separate from the ordinary 512-byte filesystem reader:
; protected PCW disks legitimately use 2 KiB sectors. Stream directly into
; the selected CP/M bank so no oversized resident scratch buffer is needed.
fdc_low_read_sector:
        ld      a,(low_n)
        ld      b,a
        ld      hl,128
        or      a
        jr      z,.low_size_ready
.low_size_scale:
        add     hl,hl
        djnz    .low_size_scale
.low_size_ready:
        ld      (low_sector_bytes),hl

        ld      a,(low_command)
        call    fdc_write
        ld      a,(low_unit)
        call    fdc_write
        ld      a,(low_cylinder)
        call    fdc_write
        ld      a,(low_head)
        call    fdc_write
        ld      a,(low_sector)
        call    fdc_write
        ld      a,(low_n)
        call    fdc_write
        ld      a,(low_sector)          ; transfer exactly one sector
        call    fdc_write
        ld      a,(low_gpl)
        call    fdc_write
        ld      a,(low_dtl)
        call    fdc_write

; transfer = min(remaining, sector bytes)
        ld      hl,(low_remaining)
        ld      de,(low_sector_bytes)
        or      a
        sbc     hl,de
        jr      c,.low_short_transfer
        ex      de,hl
        jr      .low_transfer_ready
.low_short_transfer:
        ld      hl,(low_remaining)
.low_transfer_ready:
        ld      (low_transfer),hl
        ld      de,(low_address)
        ld      (low_cursor),de
        ld      b,h
        ld      c,l
        call    low_map_destination
.low_store_byte:
        ld      a,b
        or      c
        jr      z,.low_drain_setup
        call    fdc_read_data_or_result
        jr      c,.low_read_result_st0
        ld      (de),a
        inc     de
        dec     bc
        ld      a,d
        cp      080h
        jr      nz,.low_store_byte
        ld      a,b
        or      c
        jr      z,.low_drain_setup
        ; F1 exposes one 16K window at 4000h-7FFFh. A raw sector may
        ; legitimately straddle a CP/M bank boundary, so advance the logical
        ; cursor and remap before storing the next byte instead of leaking the
        ; remainder into whichever physical block happens to occupy F2.
        ld      hl,(low_cursor)
        ld      a,h
        and     0c0h
        add     a,040h
        ld      h,a
        ld      l,0
        ld      (low_cursor),hl
        call    low_map_destination
        jr      .low_store_byte

.low_drain_setup:
        ld      hl,(low_sector_bytes)
        ld      de,(low_transfer)
        or      a
        sbc     hl,de
        ld      b,h
        ld      c,l
.low_drain_byte:
        ld      a,b
        or      c
        jr      z,.low_read_result
        call    fdc_read_data_or_result
        jr      c,.low_read_result_st0
        dec     bc
        jr      .low_drain_byte

.low_read_result:
        call    fdc_read
.low_read_result_st0:
        ld      (last_fdc_st0),a
        and     0c0h
        ld      b,a
        call    fdc_read
        ld      (last_fdc_st1),a
        or      b
        ld      b,a
        call    fdc_read
        ld      (last_fdc_st2),a
        or      b
        ld      b,a
        ld      c,4
.low_result_drain:
        call    fdc_read
        dec     c
        jr      nz,.low_result_drain

        ld      a,b
        or      a
        jr      nz,.low_result_error

        ld      de,(low_transfer)
        ld      hl,(low_address)
        add     hl,de
        ld      (low_address),hl
        ld      hl,(low_remaining)
        or      a
        sbc     hl,de
        ld      (low_remaining),hl
        or      a
        ret
.low_result_error:
        scf
        ret

; Map low_cursor into F1 and return its window address in DE. Bank 0 is
; blocks 0/1/3, bank 1 is 4/5/6, and C000h-FFFFh is common block 7.
low_map_destination:
        ld      de,(low_cursor)
        ld      a,d
        and     0c0h
        rlca
        rlca
        cp      3
        jr      z,.low_map_common
        ld      (low_target_page),a
        ld      a,(low_bank)
        or      a
        jr      z,.low_map_system
        ld      a,(low_target_page)
        add     a,4
        jr      .low_map_ready
.low_map_system:
        ld      a,(low_target_page)
        cp      2
        jr      nz,.low_map_ready
        inc     a
        jr      .low_map_ready
.low_map_common:
        ld      a,7
.low_map_ready:
        or      080h
        out     (0f1h),a
        ld      a,d
        and     03fh
        or      040h
        ld      d,a
        ret

; Load a plain CP/M COM command from the disk currently in drive A. DE points
; to the zero-terminated command line in common memory. The transient image is
; written directly to physical blocks 4..6 through the 4000h paging window.
; Return A=1 on success, zero on failure.
native_execute:
        call    native_execute_dispatch
        jr      c,.failed
        ; Publish the CCP-owned Page Zero fields used by the resident command
        ; path. In particular, command tails are upper-case: real
        ; CP/M utilities such as XCK test option letters literally and would
        ; otherwise stop for input, consuming the next GET/SUBMIT character.
        ld      hl,native_prepare_command_page_zero_overlay
        call    native_cursor_overlay_call
        ; The shell is the native equivalent of CP/M's CCP. A command typed
        ; after replacing the physical disk must see the new medium without
        ; relying on an emulator-side disk-change notification. Invalidate
        ; the previous command's XDPB override, geometry and directory data
        ; before logging in drive A.
        call    native_disk_media_reset
        call    disk_login
        jr      c,.failed
        ld      hl,0100h
        ld      (load_address),hl
        ld      hl,sector_buffer
        ld      (copy_source),hl
        xor     a
        ld      (record_mode),a
        ld      hl,0
        ld      (wanted_extent),hl
.extent:
        call    load_extent
        jr      c,.finished
        ld      hl,(wanted_extent)
        inc     hl
        ld      (wanted_extent),hl
        ld      a,h
        cp      8                 ; EX/S2 publishes at most 2048 extents
        jr      c,.extent
.finished:
        ; Every non-empty extent advances the byte destination from 0100h.
        ; This also rejects an empty directory entry instead of executing
        ; whatever transient bytes happened to be resident previously.
        ld      hl,(load_address)
        dec     h
        ld      a,h
        or      l
        jr      z,.failed
        ld      a,1
        ret
.failed:
        xor     a
        ret

; Prepare a CP/M Plus GENCOM image after native_execute has copied the complete
; file, including its 256-byte header, into the transient bank at 0100h. This
; implements the published GENCOM container and relocatable RSX-prefix format
; described by REF-CPM3-PG and the project layout in DES-LINK-002.
;
; The native module executes from physical block 0 while the transient blocks
; 4..6 are reached through the 4000h paging window. Attached RSXs live in the
; common C000h-EFFFh range and the independent LOADER prefix occupies F300h.
; Return A=0 for a plain COM, A=1 for a prepared GENCOM (HL=chain head), or
; A=FFh for a malformed/unsupported image.
native_prepare_gencom:
        ld      hl,0100h
        call    gencom_tpa_read
        cp      0c9h
        jr      z,.gencom_header
        ; A plain COM launched from a resident GET/SUBMIT stream inherits its
        ; caller's active RSX chain. With no chain these resident variables
        ; contain the ordinary zero/F606h defaults.
        ld      hl,(OPENPCW_COMMON_GENCOM_CHAIN)
        ld      a,(OPENPCW_COMMON_GENCOM_MODE)
        ret
.gencom_header:
        ld      hl,0101h
        call    gencom_read_word
        ld      a,d
        or      e
        jp      z,.gencom_bad
        ld      (gencom_transient_size),de

; The source transient begins one page after the raw header. Both it and every
; attached module/bitmap must be inside the file that native_execute loaded.
        ld      hl,0200h
        add     hl,de
        jp      c,.gencom_bad
        ld      de,(load_address)
        or      a
        sbc     hl,de
        jp      nc,.gencom_source_end_equal
        jr      .gencom_source_end_ok
.gencom_source_end_equal:
        jp      nz,.gencom_bad
.gencom_source_end_ok:
; Raw native staging currently owns the conventional three transient blocks.
; Refuse a container whose source crosses into common RAM rather than letting
; it overwrite the resident kernel while it is being decoded.
        ld      hl,(load_address)
        ld      a,h
        cp      0c0h
        jp      nc,.gencom_bad

; Preserve the already resolved public BIOS aliases before the GENCOM
; workspace is rebuilt.  Their direct targets were derived from the authored
; resident table during cold initialization, while that table was intact.
        ld      hl,0fc00h
        ld      de,GENCOM_BIOS_ALIAS_BACKUP
        ld      bc,05dh
        ldir

; Construct the public, byte-independent LOADER prefix.
        xor     a
        ld      hl,0f300h
        ld      de,0f301h
        ld      (hl),a
        ld      bc,26                  ; exactly the public 27-byte prefix
        ldir
        ld      hl,native_serial_number
        ld      de,0f300h
        ld      bc,6
        ldir                            ; REF-CPM3-PG section 4.4.1 serial field
        ld      a,0c3h
        ld      (de),a                  ; LDIR leaves DE at prefix + 6
        ld      hl,0f609h
        ld      (0f307h),hl
        ld      (0f309h),a
        ld      hl,0f606h
        ld      (0f30ah),hl
        ld      a,7                    ; Page Zero's BDOS-link high byte
        ld      (0f30ch),a             ; high half is zero from the clear above
        ld      hl,gencom_loader_name
        ld      de,0f310h
        ld      bc,8
        ldir
        ld      a,0ffh
        ld      (0f318h),a
        ; F300h-F3FFh is the independent LOADER prefix. Allocate resident
        ; extensions below the conventional F000h ceiling; the three-page gap
        ; keeps the public BDOS-60 allocation result compatible with PCW
        ; loaders while leaving the high prefix and native kernel private.
        ld      hl,0f000h
        ld      (gencom_rsx_low),hl
        ld      hl,0f306h
        ld      (gencom_chain_entry),hl
        ld      hl,0110h
        ld      (gencom_descriptor),hl
        ld      a,15
        ld      (gencom_descriptors_left),a

.gencom_descriptor_loop:
        ld      hl,(gencom_descriptor)
        call    gencom_read_word
        ld      (gencom_file_offset),de
        call    gencom_read_word
        ld      (gencom_code_size),de
        ld      a,d
        or      e
        jr      nz,.gencom_descriptor_nonzero
        ld      de,(gencom_file_offset)
        ld      a,d
        or      e
        jp      z,.gencom_modules_done
        jp      .gencom_bad
.gencom_descriptor_nonzero:
        ld      de,(gencom_file_offset)
        ld      a,d
        or      e
        jp      z,.gencom_bad
        call    gencom_tpa_read       ; descriptor byte 4
        cp      0ffh
        jp      z,.gencom_next_descriptor ; nonbanked-only module

; Validate source code and its MSB-first relocation bitmap.
        ld      hl,(gencom_file_offset)
        ld      de,0100h
        add     hl,de
        jp      c,.gencom_bad
        ld      (gencom_source),hl
        ld      de,(gencom_code_size)
        add     hl,de
        jp      c,.gencom_bad
        ld      (gencom_bitmap),hl
        ex      de,hl
        ld      bc,7
        add     hl,bc
        jp      c,.gencom_bad
        srl     h
        rr      l
        srl     h
        rr      l
        srl     h
        rr      l
        ld      (gencom_bitmap_size),hl
        ex      de,hl                ; DE=bitmap size
        ld      hl,(gencom_bitmap)
        add     hl,de
        jp      c,.gencom_bad
        ld      de,(load_address)
        or      a
        sbc     hl,de
        jr      c,.gencom_module_source_ok
        jp      nz,.gencom_bad
.gencom_module_source_ok:

; Allocate whole pages downwards below the loader, never below C000h.
        ld      de,(gencom_code_size)
        ld      a,d
        ld      b,a
        ld      a,e
        or      a
        ld      a,b
        jr      z,.gencom_allocation_pages_ready
        inc     a
        jp      z,.gencom_bad
.gencom_allocation_pages_ready:
        ld      b,a
        ld      hl,(gencom_rsx_low)
        ld      a,h
        sub     b
        jp      c,.gencom_bad
        cp      0c0h
        jp      c,.gencom_bad
        ld      h,a
        ld      l,0
        ld      (gencom_module_base),hl
        ld      (gencom_destination),hl
        ld      a,h
        dec     a                    ; GENCOM images are assembled at page 1
        ld      (gencom_reloc_delta),a
        xor     a
        ld      (gencom_reloc_mask),a
        ld      de,(gencom_code_size)
        ld      (gencom_remaining),de
        call    gencom_relocate_bytes

.gencom_relocation_done:
; Zero page padding, then link the new prefix ahead of the older chain entry.
        ld      hl,(gencom_destination)
        ld      de,(gencom_rsx_low)
.gencom_clear_padding:
        or      a
        sbc     hl,de
        add     hl,de
        jr      z,.gencom_padding_done
        xor     a
        ld      (hl),a
        inc     hl
        jr      .gencom_clear_padding
.gencom_padding_done:
        ; REF-CPM3-PG section 4.4.1 requires every resident prefix to carry
        ; the same six-byte serial returned by BDOS 107.
        ld      hl,native_serial_number
        ld      de,(gencom_module_base)
        ld      bc,6
        ldir
        ld      hl,(gencom_module_base)
        ld      de,9
        add     hl,de
        ld      (hl),0c3h
        inc     hl
        ld      de,(gencom_chain_entry)
        ld      (hl),e
        inc     hl
        ld      (hl),d
        ld      hl,(gencom_module_base)
        ld      de,12
        add     hl,de
        ld      (hl),7                  ; Page Zero's BDOS-link high byte
        inc     hl
        ld      (hl),0
        ld      hl,(gencom_module_base)
        ld      de,24
        add     hl,de
        ld      (hl),0
        ; The previous chain member points back to the high byte of this
        ; module's NEXT operand. This is the link representation specified by
        ; the standard 27-byte RSX prefix (REF-CPM3-PG section 4.4.1).
        ld      de,0fff3h              ; prefix + 24 back to prefix + 11
        add     hl,de
        ex      de,hl
        ld      hl,(gencom_chain_entry)
        ld      bc,6
        add     hl,bc
        ld      (hl),e
        inc     hl
        ld      (hl),d
        ld      hl,(gencom_module_base)
        ld      (gencom_rsx_low),hl
        ld      de,6
        add     hl,de
        ld      (gencom_chain_entry),hl

.gencom_next_descriptor:
        ld      hl,(gencom_descriptor)
        ld      de,16
        add     hl,de
        ld      (gencom_descriptor),hl
        ld      a,(gencom_descriptors_left)
        dec     a
        ld      (gencom_descriptors_left),a
        jp      nz,.gencom_descriptor_loop

.gencom_modules_done:
        call    gencom_prepare_compat
; Move the transient page down exactly as a CP/M Plus GENCOM loader does.
        ld      hl,0200h
        ld      (gencom_source),hl
        ld      hl,0100h
        ld      (gencom_destination),hl
        ld      hl,(gencom_transient_size)
        ld      (gencom_remaining),hl
.gencom_copy_transient:
        ld      hl,(gencom_remaining)
        ld      a,h
        or      l
        jr      z,.gencom_ready
        ld      hl,(gencom_source)
        call    gencom_tpa_read
        inc     hl
        ld      (gencom_source),hl
        ld      hl,(gencom_destination)
        call    gencom_tpa_write
        inc     hl
        ld      (gencom_destination),hl
        ld      hl,(gencom_remaining)
        dec     hl
        ld      (gencom_remaining),hl
        jr      .gencom_copy_transient
.gencom_ready:
        ld      hl,(gencom_chain_entry)
        ld      a,1
        ret
.gencom_bad:
        ld      hl,(OPENPCW_COMMON_GENCOM_CHAIN)
        ld      a,0ffh
        ret

; Relocate gencom_remaining bytes from gencom_source to gencom_destination
; using the public MSB-first bitmap. Both attached RSXs and PRL overlays use
; this same format; gencom_tpa_write works for transient and common addresses.
gencom_relocate_bytes:
        ld      hl,(gencom_remaining)
        ld      a,h
        or      l
        ret     z
        ld      a,(gencom_reloc_mask)
        or      a
        jr      nz,.relocate_have_bitmap
        ld      hl,(gencom_bitmap)
        call    gencom_tpa_read
        ld      (gencom_bitmap_byte),a
        inc     hl
        ld      (gencom_bitmap),hl
        ld      a,080h
        ld      (gencom_reloc_mask),a
.relocate_have_bitmap:
        ld      hl,(gencom_source)
        call    gencom_tpa_read
        ld      (gencom_value),a
        inc     hl
        ld      (gencom_source),hl
        ld      a,(gencom_bitmap_byte)
        ld      b,a
        ld      a,(gencom_reloc_mask)
        and     b
        ld      a,(gencom_value)
        jr      z,.relocate_store
        ld      b,a
        ld      a,(gencom_reloc_delta)
        add     a,b
.relocate_store:
        ld      hl,(gencom_destination)
        call    gencom_tpa_write
        inc     hl
        ld      (gencom_destination),hl
        ld      a,(gencom_reloc_mask)
        srl     a
        ld      (gencom_reloc_mask),a
        ld      hl,(gencom_remaining)
        dec     hl
        ld      (gencom_remaining),hl
        jr      gencom_relocate_bytes

; Read/write an abstract 0000h-BFFFh caller address through the disposable F1
; window. Page zero is necessarily the ordinary transient block (CALL 0005h
; came from it); pages one and two follow the public Screen/BIOS shadows in
; physical block zero so a colour loader can receive DMA in its selected
; screen banks. Both helpers preserve HL and BC.
gencom_tpa_page:
        or      a
        jr      z,.gencom_tpa_page_zero
        dec     a
        jr      z,.gencom_tpa_page_one
        dec     a
        ld      a,(0062h)
        ret     z
        ld      a,087h
        ret
.gencom_tpa_page_one:
        ld      a,(0061h)
        ret
.gencom_tpa_page_zero:
        ld      a,084h
        ret

gencom_tpa_read:
        push    bc
        ld      c,h
        ld      a,h
        and     0c0h
        rlca
        rlca
        call    gencom_tpa_page
        out     (0f1h),a
        ld      a,h
        and     03fh
        or      040h
        ld      h,a
        ld      a,(hl)
        ld      h,c
        pop     bc
        ret

gencom_tpa_write:
        push    bc
        ld      b,a
        ld      c,h
        ld      a,h
        and     0c0h
        rlca
        rlca
        call    gencom_tpa_page
        out     (0f1h),a
        ld      a,h
        and     03fh
        or      040h
        ld      h,a
        ld      a,b
        ld      (hl),a
        ld      h,c
        pop     bc
        ret

; HL points at a transient-bank little-endian word. Return it in DE and leave
; HL advanced to the following byte.
gencom_read_word:
        call    gencom_tpa_read
        ld      e,a
        inc     hl
        call    gencom_tpa_read
        ld      d,a
        inc     hl
        ret

; Construct the conventional CP/M Plus loader workspace at runtime using the
; active command name, current drive parameters, and resident BIOS vectors.
; Keeping these records current lets resident extensions share the same state.
gencom_prepare_compat:
        xor     a
        ld      hl,0fb00h
        ld      de,0fb01h
        ld      (hl),a
        ld      bc,015ch
        ldir
        ld      a,1
        ld      (0fb00h),a
        ld      hl,wanted_name
        ld      de,0fb01h
        ld      bc,11
        ldir

; Rebuild the same public drive tables after the GENCOM workspace clear.
; A: is the inserted physical medium and M: is the volatile sparse RAM drive.
        call    native_publish_disk_tables
        call    native_publish_char_table
        ld      a,052h
        ld      (0fbb4h),a       ; cold transient state observed by GET
        ; SCB 3Ah is the LOADER compatibility anchor, not Page Zero's public
        ; BDOS vector. Adding the documented FD00h loader displacement to
        ; F606h selects the independent prefix entry at F306h.
        ld      hl,0f606h
        ld      (0fb98h),hl
        ld      hl,0080h
        ld      (0fbd8h),hl
        ld      hl,(gencom_chain_entry)
        ld      (0fbfeh),hl
        ; Standard loader clients derive this default-FCB pointer from the
        ; workspace anchor above. Publish it at the corresponding F598h slot.
        ld      hl,0fb00h
        ld      (0f598h),hl
        ld      hl,0fb79h
        ld      (0fb58h),hl       ; M: entry in the thirteen-word DRVTBL

; Restore the direct BOOT..USERF aliases saved before resident relocation.
; The standard FC00h table stays above resident allocation, so no second
; executable mirror is needed inside the extension-owned common range.
        ld      hl,GENCOM_BIOS_ALIAS_BACKUP
        ld      de,0fc00h
        ld      bc,05dh
        ldir
        ld      hl,0001h
        ld      a,003h
        call    gencom_tpa_write
        inc     hl
        ld      a,0fch
        call    gencom_tpa_write
        ret

gencom_loader_name:      db 'LOADER  '
native_character_table:
        db      'CRT   ',03h,0,0
native_character_table_end:
gencom_m_dpb:
        dw      128                      ; 128-byte records per logical track
        db      4,15,1                   ; 2K blocks, extent mask 1
        dw      0                        ; dynamic DSM: installed RAM minus 1
        dw      127                      ; 128 directory entries
        db      0c0h,0                   ; first two blocks hold the directory
        dw      08000h                   ; permanent medium: no check vector
        dw      3                        ; conventional PCW RAM-disk offset
        db      0,0                      ; 128-byte physical records
gencom_m_dpb_end:
gencom_descriptor:       dw 0
gencom_descriptors_left: db 0
gencom_file_offset:      dw 0
gencom_code_size:        dw 0
gencom_transient_size:   dw 0
gencom_bitmap_size:      dw 0
gencom_source:           dw 0
gencom_bitmap:           dw 0
gencom_destination:      dw 0
gencom_remaining:        dw 0
gencom_module_base:      dw 0
gencom_rsx_low:          dw 0
gencom_chain_entry:      dw 0
gencom_reloc_delta:      db 0
gencom_reloc_mask:       db 0
gencom_bitmap_byte:      db 0
gencom_value:            db 0

; Sparse M: record store ---------------------------------------------------
;
; CP/M Plus applications can create sparse files whose
; logical record numbers are far apart. Materialising the holes would require
; tens of megabytes, so the unused tail of private system block 3 holds a
; 128-slot directory, sparse per-block allocation keys and validity bitmaps.
; File data itself uses the standard public M: layout in pages 9..15/31 so
; software which follows an FCB allocation map sees the same bytes as BDOS.
; Neither application-owned page 8 nor live native code/data is aliased.
native_sparse_init:
        ld      a,SPARSE_METADATA_PAGE
        out     (0f1h),a
        xor     a
        ld      hl,SPARSE_DIRECTORY_BASE
        ld      de,SPARSE_DIRECTORY_BASE+1
        ld      (hl),a
        ld      bc,2047
        ldir
        ld      a,0ffh
        ld      hl,SPARSE_ALLOCATION_BASE
        ld      de,SPARSE_ALLOCATION_BASE+1
        ld      (hl),a
        ld      bc,767
        ldir
        xor     a
        ld      hl,SPARSE_VALIDITY_BASE
        ld      de,SPARSE_VALIDITY_BASE+1
        ld      (hl),a
        ld      bc,SPARSE_PRIVATE_END-SPARSE_VALIDITY_BASE-1
        ldir
        ; Publish an initially empty standard CP/M directory at the start of
        ; M:. Programs which follow an FCB allocation map can inspect the same
        ; physical RAM-disc image as BDOS on emulators and real hardware.
        ld      a,089h
        out     (0f1h),a
        ld      a,0e5h
        ld      hl,04000h
        ld      de,04001h
        ld      (hl),a
        ld      bc,4095
        ldir
        ld      a,OPENPCW_RUNTIME_PAGE
        out     (0f1h),a
        ret

; A=file slot, BC=low 16 bits of record, E=high record byte, HL=TPA DMA.
; Return A=0 on success, A=1 when the sparse store is full.
native_sparse_write:
        ld      (sparse_slot),a
        ld      (sparse_record),bc
        ld      a,e
        ld      (sparse_record+2),a
        ld      (sparse_dma),hl
        call    sparse_ensure_allocation
        or      a
        jr      nz,.sparse_write_bad
        call    sparse_mark_valid
        call    sparse_make_data_index
        ld      (sparse_data_index),hl
        ld      hl,(sparse_dma)
        ld      de,sparse_io_buffer
        ld      b,128
.sparse_write_fetch:
        call    gencom_tpa_read
        ld      (de),a
        inc     hl
        inc     de
        djnz    .sparse_write_fetch
        ld      hl,(sparse_data_index)
        call    sparse_map_data
        ex      de,hl
        ld      hl,sparse_io_buffer
        ld      bc,128
        ldir
        xor     a
        ret
.sparse_write_bad:
        ld      a,1
        ret

; Same register contract as native_sparse_write. Missing records return the
; normal CP/M random-read EOF status (A=1).
native_sparse_read:
        ld      (sparse_slot),a
        ld      (sparse_record),bc
        ld      a,e
        ld      (sparse_record+2),a
        ld      (sparse_dma),hl
        call    sparse_find
        jr      c,.sparse_read_bad
        call    sparse_map_data
        ld      de,sparse_io_buffer
        ld      bc,128
        ldir
        ld      hl,(sparse_dma)
        ld      de,sparse_io_buffer
        ld      b,128
.sparse_read_store:
        ld      a,(de)
        call    gencom_tpa_write
        inc     hl
        inc     de
        djnz    .sparse_read_store
        xor     a
        ret
.sparse_read_bad:
        ld      a,1
        ret

; Find the selected file's allocated 2 KiB block and verify the requested
; record-validity bit. Return a dense 0..2911 physical record index in HL.
sparse_find:
        call    sparse_make_block_key
        ld      a,SPARSE_METADATA_PAGE
        out     (0f1h),a
        ld      ix,SPARSE_ALLOCATION_BASE
        ld      a,(native_m_data_blocks)
        ld      b,a
        ld      c,0
.sparse_find_loop:
        ld      a,(sparse_slot)
        cp      (ix+0)
        jr      nz,.sparse_find_next
        ld      a,(sparse_block_key)
        cp      (ix+1)
        jr      nz,.sparse_find_next
        ld      a,(sparse_block_key+1)
        cp      (ix+2)
        jr      nz,.sparse_find_next
        ld      a,(sparse_block_key+2)
        cp      (ix+3)
        jr      nz,.sparse_find_next
        ld      a,c
        ld      (sparse_allocation_index),a
        call    sparse_record_is_valid
        jr      z,.sparse_find_missing
        call    sparse_make_data_index
        or      a
        ret
.sparse_find_next:
        ld      de,4
        add     ix,de
        inc     c
        djnz    .sparse_find_loop
.sparse_find_missing:
        scf
        ret

; HL=dense physical data-record index. The mapper adds the directory's 32
; records and exposes the resulting standard M: location in pages 9..15/31.
sparse_map_data:
        ld      (sparse_data_index),hl
        ld      hl,sparse_map_data_overlay
        jp      native_cursor_overlay_call

; Build allocation_index*16 + record-within-block.
sparse_make_data_index:
        ld      a,(sparse_allocation_index)
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      a,(sparse_record)
        and     00fh
        ld      e,a
        ld      d,0
        add     hl,de
        ret

; A=allocation index -> HL=its two-byte validity bitmap.
sparse_valid_address:
        ld      l,a
        ld      h,0
        add     hl,hl
        ld      de,SPARSE_VALIDITY_BASE
        add     hl,de
        ret

; Return the current record's bitmap byte in HL and one-bit mask in A.
sparse_record_mask:
        ld      a,(sparse_allocation_index)
        call    sparse_valid_address
        ld      a,(sparse_record)
        and     00fh
        cp      8
        jr      c,.sparse_mask_low
        inc     hl
        sub     8
.sparse_mask_low:
        ld      b,a
        ld      a,1
        jr      z,.sparse_mask_ready
.sparse_mask_shift:
        rlca
        djnz    .sparse_mask_shift
.sparse_mask_ready:
        ret

sparse_record_is_valid:
        call    sparse_record_mask
        and     (hl)
        ret

sparse_mark_valid:
        call    sparse_record_mask
        or      (hl)
        ld      (hl),a
        ret

; CP/M allocates M: in 2 KiB units even though the private record map remains
; sparse. Keep one four-byte key (file slot plus 24-bit logical block) for each
; physical data block. This makes Function 46 and out-of-space behaviour match
; the published DPB instead of counting partially written records as blocks.
sparse_make_block_key:
        ld      hl,(sparse_record)
        ld      a,(sparse_record+2)
        ld      b,4
.sparse_key_shift:
        srl     a
        rr      h
        rr      l
        djnz    .sparse_key_shift
        ld      (sparse_block_key),hl
        ld      (sparse_block_key+2),a
        ret

sparse_ensure_allocation:
        call    sparse_make_block_key
        ld      a,SPARSE_METADATA_PAGE
        out     (0f1h),a
        ld      ix,SPARSE_ALLOCATION_BASE
        ld      hl,0
        ld      (sparse_allocation_free),hl
        ld      a,0ffh
        ld      (sparse_allocation_free_index),a
        ld      a,(native_m_data_blocks)
        ld      b,a
        ld      c,0
.sparse_allocation_next:
        ld      a,(ix+0)
        cp      0ffh
        jr      z,.sparse_allocation_free_slot
        cp      0feh
        jr      z,.sparse_allocation_free_slot
        ld      a,(sparse_slot)
        cp      (ix+0)
        jr      nz,.sparse_allocation_advance
        ld      a,(sparse_block_key)
        cp      (ix+1)
        jr      nz,.sparse_allocation_advance
        ld      a,(sparse_block_key+1)
        cp      (ix+2)
        jr      nz,.sparse_allocation_advance
        ld      a,(sparse_block_key+2)
        cp      (ix+3)
        jr      nz,.sparse_allocation_advance
        ld      a,c
        ld      (sparse_allocation_index),a
        ; A second ensure in Function 40 must retain the pending first-map
        ; initialisation; the mapper clears this flag after filling the block.
        ld      a,(sparse_allocation_new)
        or      a
        xor     a
        ret
.sparse_allocation_free_slot:
        ld      hl,(sparse_allocation_free)
        ld      a,h
        or      l
        jr      nz,.sparse_allocation_advance
        push    ix
        pop     hl
        ld      (sparse_allocation_free),hl
        ld      a,c
        ld      (sparse_allocation_free_index),a
.sparse_allocation_advance:
        ld      de,4
        add     ix,de
        inc     c
        djnz    .sparse_allocation_next
        ld      ix,(sparse_allocation_free)
        push    ix
        pop     hl
        ld      a,h
        or      l
        jr      z,.sparse_allocation_full
        ld      a,(sparse_slot)
        ld      (ix+0),a
        ld      a,(sparse_block_key)
        ld      (ix+1),a
        ld      a,(sparse_block_key+1)
        ld      (ix+2),a
        ld      a,(sparse_block_key+2)
        ld      (ix+3),a
        ld      a,(sparse_allocation_free_index)
        ld      (sparse_allocation_index),a
        call    sparse_valid_address
        xor     a
        ld      (hl),a
        inc     hl
        ld      (hl),a
        ; A newly allocated public M: block is a formatted CP/M block.  Fill
        ; all 2 KiB with the erased E5h value before its first record is
        ; written, matching the physical image exposed through the FCB map;
        ; otherwise raw-bank clients observe zero-filled holes which differ
        ; from ordinary RAM-disc semantics.
        inc     a
        ld      (sparse_allocation_new),a
        xor     a
        ret
.sparse_allocation_full:
        ld      a,1
        ret

sparse_slot:             db 0
sparse_record:           db 0,0,0
sparse_dma:              dw 0
sparse_scan_left:        dw 0
sparse_data_index:       dw 0
sparse_block_key:        db 0,0,0
sparse_allocation_free:  dw 0
sparse_allocation_free_index: db 0
sparse_allocation_index: db 0
sparse_allocation_new:   db 0
sparse_valid_word:       dw 0
sparse_record_within:    db 0
sparse_io_buffer:        defs 128,0

; Volatile M: BDOS service ------------------------------------------------
;
; M: is the project-authored sparse RAM filesystem described by DES-FS-M-001.
; The resident kernel passes ordinary FCB and DMA addresses through entry
; 0127h; this banked service reads/writes those TPA addresses explicitly and
; owns all directory, extent and record policy.
;
; Input: A=BDOS function, DE=FCB/parameter block, HL=DMA,
;        B=multisector count for record I/O. Besides the M: filesystem this
;        entry hosts general BDOS services which need bank-one memory while
;        the native module is mapped at 0000h-BFFFh.
; Output: CP/M status in A (00 success, 01 read/write failure, FF directory
;         operation failure) and the documented value in HL. Most services
;         mirror A into HL; Function 152 returns its parser pointer directly.
native_m_bdos:
        ld      (m_function),a
        ld      (m_fcb),de
        ld      (m_dma),hl
        xor     a
        ld      (native_physical_error_code),a
        ld      a,b
        or      a
        jr      nz,.m_count_ready
        inc     a
.m_count_ready:
        ld      (m_count),a
        ld      a,(m_function)
        cp      18
        jr      z,.keep_search
        cp      24
        jr      z,.keep_search
        cp      104
        jr      c,.invalidate_search
        cp      113
        jr      c,.keep_search
.invalidate_search:
        xor     a
        ld      (native_search_valid),a
.keep_search:
        ld      a,(m_function)
        cp      59
        jr      nz,.not_rsx_prune
        ld      a,d
        or      e
        jp      z,native_prune_rsx_call
.not_rsx_prune:
        ld      a,(m_function)
        cp      1
        jp      z,native_console_input_result
        cp      27
        jp      z,native_get_allocation_vector
        cp      31
        jp      z,native_get_dpb
        cp      46
        jp      z,native_get_free_space
        cp      49
        jp      z,native_scb_result
        cp      24
        jp      z,native_return_login_vector
        cp      28
        jp      z,native_write_protect_result
        cp      29
        jp      z,native_return_ro_vector
        cp      104
        jp      z,native_set_date_time_result
        cp      105
        jp      z,native_get_date_time
        cp      106
        jp      z,native_set_default_password_result
        cp      107
        jp      z,native_return_serial_result
        cp      101
        jp      z,native_directory_label_result
        cp      109
        jp      z,native_console_mode
        cp      110
        jp      z,native_output_delimiter
        cp      17
        jp      z,native_search_first_result
        cp      18
        jp      z,native_search_next_result
        cp      152
        jp      z,native_parse_filename
        cp      35
        jr      nz,.not_compute_size
        call    native_open_prepare_bridge
        call    m_copy_name
        jp      native_compute_file_size_result
.not_compute_size:
        cp      36
        jp      z,native_set_random_record_result
        cp      111
        jp      z,native_print_block_result
        cp      112
        jp      z,native_list_block_result
        call    native_open_prepare_bridge
        call    m_copy_name
        call    native_fcb_drive
        cp      12
        jr      z,.m_dispatch
        or      a
        jr      z,.a_dispatch
        ld      a,0ffh
        jp      native_m_status_result
.a_dispatch:
        ld      a,(m_count)
        ld      (m_left),a
        call    a_copy_wanted_name
        ; m_copy_name leaves F1 on the caller's TPA. The protected-file
        ; preflight lives in native page one and scans before any mutation.
        ld      a,OPENPCW_RUNTIME_PAGE
        out     (0f1h),a
        call    native_reject_a_read_only_mutation
        ld      a,(m_function)
        cp      15
        jp      z,a_open_result
        cp      16
        jp      z,a_close_result
        cp      19
        jp      z,a_open_result
        cp      20
        jp      z,a_read_sequential_result
        cp      21
        jp      z,a_write_sequential_result
        cp      22
        jp      z,a_make_result
        cp      23
        jp      z,a_open_result
        cp      30
        jp      z,a_open_result
        cp      33
        jp      z,a_read_random_result
        cp      34
        jp      z,a_write_random_result
        cp      40
        jp      z,a_write_random_zero_result
        cp      59
        jp      z,a_load_overlay_result
        cp      99
        jp      z,a_open_result
        cp      100
        jp      z,a_open_result
        cp      102
        jp      z,a_read_stamps_result
        cp      103
        jp      z,a_open_result
        ld      a,0ffh
        jp      native_m_status_result
.m_dispatch:
        ; gencom_tpa_read leaves F1 on the caller's bank. Restore this native
        ; page before invoking the page-one mutation-policy helper.
        ld      a,OPENPCW_RUNTIME_PAGE
        out     (0f1h),a
        call    native_reject_read_only_mutation
        ld      a,(m_count)
        ld      (m_left),a
        ld      a,(m_function)
        cp      15
        jp      z,m_open_result
        cp      16
        jp      z,m_close_result
        cp      19
        jp      z,m_open_result
        cp      20
        jp      z,m_read_sequential_result
        cp      21
        jp      z,m_write_sequential_result
        cp      22
        jp      z,m_create_result
        cp      23
        jp      z,m_open_result
        cp      30
        jp      z,m_open_result
        cp      33
        jp      z,m_read_random_result
        cp      34
        jp      z,m_write_random_result
        cp      40
        jp      z,m_write_random_zero_result
        cp      99
        jp      z,m_open_result
        cp      100
        jp      z,m_open_result
        cp      102
        jp      z,m_open_result
        cp      103
        jp      z,m_open_result
        cp      59
        jp      z,m_load_overlay_result
        ld      a,0ffh
native_m_status_result:
        ld      l,a
        ld      h,0
        cp      0ffh
        ret     nz
        ld      a,(native_physical_error_code)
        ld      h,a
        or      a
        ld      a,l
        ret     z
        ld      a,(OPENPCW_COMMON_ERROR_MODE)
        cp      0feh
        jp      c,OPENPCW_COMMON_ERROR_ABORT
        ld      a,l
        ret

; Logical multisector read/write errors return the number of completed
; 128-byte records in H. A physical error (FFh) keeps H reserved for its
; physical-error code; the current controller paths report those separately.
native_io_status_result:
        ld      l,a
        ld      h,0
        or      a
        ret     z
        cp      0ffh
        jp      z,native_m_status_result
        ld      a,(m_left)
        ld      b,a
        ld      a,(m_count)
        sub     b
        ld      h,a
        ld      a,l
        ret

; BDOS 27/31/46 disk introspection. The allocation vectors are deliberately
; in bank zero, as on a banked CP/M Plus system; transients receive their
; stable addresses but cannot accidentally overwrite resident common code.
native_get_allocation_vector:
        ld      a,(OPENPCW_COMMON_CURRENT_DISK)
        or      a
        jr      z,.native_allocation_a
        cp      12
        jr      z,.native_allocation_m
        ld      hl,0ffffh
        ld      a,l
        ret
.native_allocation_a:
        ld      hl,native_a_alv
        ld      a,l
        ret
.native_allocation_m:
        ld      hl,native_m_alv
        ld      a,l
        ret

native_get_dpb:
        ld      a,(OPENPCW_COMMON_CURRENT_DISK)
        or      a
        jr      z,.native_dpb_a
        cp      12
        jr      z,.native_dpb_m
        ld      hl,0ffffh
        ld      a,l
        ret
.native_dpb_a:
        ld      ix,0fb9ch
        ld      c,0
        call    native_xbios_login
        jr      c,.native_dpb_bad
        ld      hl,0fb9ch
        ld      a,l
        ret
.native_dpb_m:
        ld      hl,0fbc0h
        ld      a,l
        ret
.native_dpb_bad:
        ld      hl,0ffffh
        ld      a,l
        ret

native_get_free_space:
        ld      hl,(m_fcb)
        ld      a,l
        or      a
        jr      z,.native_free_a
        cp      12
        jr      z,.native_free_m
        jp      native_free_bad
.native_free_a:
        call    disk_login
        jp      c,native_free_bad
        call    a_scan_used_blocks
        jp      c,native_free_bad
        ld      a,(disk_dir_blocks)
        ld      e,a
        ld      d,0
        ld      bc,0
.native_free_a_block:
        push    de
        ld      hl,(disk_dsm)
        or      a
        sbc     hl,de
        pop     de
        jr      c,.native_free_a_counted
        push    bc
        push    de
        call    overlay_block_used
        pop     de
        pop     bc
        jr      nz,.native_free_a_used
        inc     bc
.native_free_a_used:
        inc     de
        jr      .native_free_a_block
.native_free_a_counted:
        ld      h,b
        ld      l,c
        xor     a
        ld      a,(disk_block_shift)
        ld      b,a
        xor     a
.native_free_a_scale:
        add     hl,hl
        rla
        djnz    .native_free_a_scale
        jr      native_store_free_records
.native_free_m:
        ld      a,SPARSE_METADATA_PAGE
        out     (0f1h),a
        ld      ix,SPARSE_ALLOCATION_BASE
        ld      a,(native_m_data_blocks)
        ld      b,a
        ld      c,0
.native_free_m_allocation:
        ld      a,(ix+0)
        cp      0feh
        jr      c,.native_free_m_used
        inc     c
.native_free_m_used:
        ld      de,4
        add     ix,de
        djnz    .native_free_m_allocation
        ld      l,c
        ld      h,0
        xor     a
        ld      b,4
.native_free_m_scale:
        add     hl,hl
        rla
        djnz    .native_free_m_scale
native_store_free_records:
        ld      (native_free_records),hl
        ld      (native_free_records+2),a
        ld      hl,(m_dma)
        ld      a,(native_free_records)
        call    gencom_tpa_write
        inc     hl
        ld      a,(native_free_records+1)
        call    gencom_tpa_write
        inc     hl
        ld      a,(native_free_records+2)
        call    gencom_tpa_write
        xor     a
        ld      l,a
        ld      h,a
        ret
native_free_bad:
        ld      hl,04ffh
        ld      a,0ffh
        ret

native_compute_file_size_result:
        call    native_compute_file_size
        jp      native_m_status_result
native_set_random_record_result:
        call    native_set_random_record
        jp      native_m_status_result
native_search_first_result:
        call    native_search_first
        jp      native_m_status_result
native_search_next_result:
        call    native_search_next
        jp      native_m_status_result
native_set_date_time_result:
        call    native_set_date_time
        jp      native_m_status_result
native_set_default_password_result:
        call    native_set_default_password
        jp      native_m_status_result
native_return_serial_result:
        call    native_return_serial
        jp      native_m_status_result
native_directory_label_result:
        call    native_directory_label
        jp      native_m_status_result
native_print_block_result:
        call    native_print_block
        jp      native_m_status_result
native_list_block_result:
        call    native_list_block
        jp      native_m_status_result
m_read_sequential_result:
        call    m_read_sequential
        jp      native_io_status_result
m_write_sequential_result:
        call    m_write_sequential
        jp      native_io_status_result
m_read_random_result:
        call    m_read_random
        jp      native_io_status_result
m_write_random_result:
        call    m_write_random
        jp      native_io_status_result
m_write_random_zero_result:
        call    m_write_random_zero
        jp      native_io_status_result
m_load_overlay_result:
        call    m_load_overlay
        jp      native_m_status_result
a_write_sequential_result:
        call    a_write_sequential
        jp      native_io_status_result
a_write_random_result:
        xor     a
        ld      (a_zero_fill),a
        call    a_write_random
        jp      native_io_status_result
a_write_random_zero_result:
        ld      a,1
        ld      (a_zero_fill),a
        call    a_write_random
        jp      native_io_status_result
a_read_stamps_result:
        jp      a_open_result
a_load_overlay_result:
        call    a_load_overlay
        jp      native_m_status_result
a_open_result:
        call    native_open_a_bridge
        jp      native_m_status_result

; Physical A: reads use the protected native implementation below. Keeping
; their complete multisector loop in page one means an application may use its
; full published high transient stack while BDOS 20/33 continue to operate.
a_read_sequential_result:
a_read_random_result:
        jp      native_physical_read_result

; BDOS 17/18 retain a directory cursor and copy the complete four-entry
; directory record to the current DMA. Physical A: is scanned directly;
; volatile M: synthesizes the same public 32-byte entry format from its 128
; private file slots. A '?' drive requests an unfiltered raw directory scan.
native_search_first:
        ld      hl,(m_fcb)
        call    gencom_tpa_read
        cp      '?'
        jr      nz,.search_normal_drive
        ld      a,1
        ld      (native_search_raw),a
        ld      a,(OPENPCW_COMMON_CURRENT_DISK)
        and     00fh
        jr      .search_drive_ready
.search_normal_drive:
        xor     a
        ld      (native_search_raw),a
        call    native_fcb_drive
.search_drive_ready:
        cp      12
        jr      z,.search_store_drive
        or      a
        jr      nz,.search_bad
.search_store_drive:
        ld      (native_search_drive),a
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        ld      (native_search_user),a
        ld      hl,(m_fcb)
        inc     hl
        ld      de,native_search_pattern
        ld      b,12
.search_copy_pattern:
        call    gencom_tpa_read
        and     07fh
        ld      (de),a
        inc     hl
        inc     de
        djnz    .search_copy_pattern
        ld      hl,0
        ld      (native_search_cursor),hl
        ld      a,1
        ld      (native_search_valid),a
        jr      native_search_next
.search_bad:
        ld      a,0ffh
        ret

native_search_next:
        ld      a,(native_search_valid)
        or      a
        jp      z,.search_next_missing
        ld      a,(native_search_drive)
        cp      12
        jp      z,native_search_m_next
        call    disk_login
        jp      c,.search_next_missing
.search_a_next:
        ld      hl,(native_search_cursor)
        ld      a,l
        and     00fh
        ld      (native_search_entry),a
        inc     hl
        ld      (native_search_cursor),hl
        dec     hl
        ld      b,4
.search_sector_shift:
        srl     h
        rr      l
        djnz    .search_sector_shift
        ld      a,h
        or      a
        jp      nz,.search_next_missing
        ld      a,(disk_dir_sectors)
        cp      l
        jp      z,.search_next_missing
        jp      c,.search_next_missing
        ld      de,(disk_data_start)
        add     hl,de
        call    read_logical_sector
        jp      c,.search_next_missing
        ld      a,(native_search_entry)
        ld      l,a
        ld      h,0
        ld      b,5
.search_entry_shift:
        add     hl,hl
        djnz    .search_entry_shift
        ld      de,sector_buffer
        add     hl,de
        push    hl
        pop     ix
        ld      a,(native_search_raw)
        or      a
        jr      nz,.search_a_found
        ld      a,(native_search_user)
        cp      (ix+0)
        jr      nz,.search_a_next
        push    ix
        pop     de
        inc     de
        ld      hl,native_search_pattern
        ld      b,12
.search_a_compare:
        ld      a,(hl)
        cp      '?'
        jr      z,.search_a_compare_next
        ld      c,a
        ld      a,(de)
        and     07fh
        cp      c
        jr      nz,.search_a_next
.search_a_compare_next:
        inc     hl
        inc     de
        djnz    .search_a_compare
.search_a_found:
        ld      a,(native_search_entry)
        and     00ch
        ld      l,a
        ld      h,0
        ld      b,5
.search_group_shift:
        add     hl,hl
        djnz    .search_group_shift
        ld      de,sector_buffer
        add     hl,de
        ex      de,hl
        call    native_search_copy_dma
        ld      a,(native_search_entry)
        and     3
        ret
.search_next_missing:
        xor     a
        ld      (native_search_valid),a
        ld      a,0ffh
        ret

native_search_m_next:
        ld      hl,(native_search_cursor)
        ld      a,h
        or      a
        jr      nz,.search_m_special
        ld      a,l
        cp      128
        jr      nc,.search_m_special
        ld      (native_search_entry),a
        inc     hl
        ld      (native_search_cursor),hl
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      de,SPARSE_DIRECTORY_BASE
        add     hl,de
        push    hl
        pop     ix
        ld      a,SPARSE_METADATA_PAGE
        out     (0f1h),a
        ld      a,(native_search_raw)
        or      a
        jr      nz,.search_m_found
        ld      a,(native_search_user)
        inc     a
        cp      (ix+0)
        jr      nz,native_search_m_next
        push    ix
        pop     de
        inc     de
        ld      hl,native_search_pattern
        ld      b,11
.search_m_compare:
        ld      a,(hl)
        cp      '?'
        jr      z,.search_m_compare_next
        ld      c,a
        ld      a,(de)
        cp      c
        jr      nz,native_search_m_next
.search_m_compare_next:
        inc     hl
        inc     de
        djnz    .search_m_compare
        ld      a,(native_search_pattern+11)
        cp      '?'
        jr      z,.search_m_found
        or      a
        jr      nz,native_search_m_next
.search_m_found:
        call    native_search_build_m_group
        ld      de,sparse_io_buffer
        call    native_search_copy_dma
        ld      a,(native_search_entry)
        and     3
        ret
.search_m_missing:
        jp      .search_next_missing
.search_m_special:
        ld      a,(native_search_raw)
        or      a
        jr      z,.search_m_missing
        call    native_open_m_bridge
        ret

; DE=128-byte native buffer, copied to the current bank-one DMA.
native_search_copy_dma:
        ld      hl,(m_dma)
        ld      b,128
.search_dma_next:
        ld      a,(de)
        call    gencom_tpa_write
        inc     de
        inc     hl
        djnz    .search_dma_next
        ret

native_search_build_m_group:
        ld      a,(native_search_entry)
        and     0fch
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      de,SPARSE_DIRECTORY_BASE
        add     hl,de
        push    hl
        pop     ix
        ld      hl,sparse_io_buffer
        ld      c,4
.search_m_group_entry:
        ld      a,(ix+0)
        or      a
        jr      nz,.search_m_group_active
        ld      b,32
        ld      a,0e5h
.search_m_group_fill_free:
        ld      (hl),a
        inc     hl
        djnz    .search_m_group_fill_free
        jr      .search_m_group_advance
.search_m_group_active:
        ld      a,(ix+0)
        dec     a
        ld      (hl),a
        inc     hl
        push    ix
        pop     de
        inc     de
        ld      b,11
.search_m_group_name:
        ld      a,(de)
        ld      (hl),a
        inc     de
        inc     hl
        djnz    .search_m_group_name
        ; Private byte 12 packs the seven CP/M attributes f1'..f4' and
        ; t1'..t3'. Materialise them as the public high name/type bits.
        push    bc
        push    hl
        ld      de,-11
        add     hl,de
        ld      c,(ix+12)
        ld      b,4
.search_m_group_name_attrs:
        rr      c
        jr      nc,.search_m_group_name_attr_next
        set     7,(hl)
.search_m_group_name_attr_next:
        inc     hl
        djnz    .search_m_group_name_attrs
        ld      de,4
        add     hl,de
        ld      b,3
.search_m_group_type_attrs:
        rr      c
        jr      nc,.search_m_group_type_attr_next
        set     7,(hl)
.search_m_group_type_attr_next:
        inc     hl
        djnz    .search_m_group_type_attrs
        pop     hl
        push    hl
        xor     a
        ld      b,20
.search_m_group_clear:
        ld      (hl),a
        inc     hl
        djnz    .search_m_group_clear
        pop     de
        inc     de
        ld      a,(ix+13)
        ld      (de),a
        pop     bc
.search_m_group_advance:
        ld      de,16
        add     ix,de
        dec     c
        jr      nz,.search_m_group_entry
        ret

; BDOS 111/112 Character Control Blocks contain a bank-one string address and
; a 16-bit byte count. Console output uses the same authored terminal engine as
; ordinary native BDOS output; the unconfigured LST: device discards data.
native_print_block:
        ld      hl,(m_fcb)
        call    gencom_tpa_read
        ld      (native_block_address),a
        inc     hl
        call    gencom_tpa_read
        ld      (native_block_address+1),a
        inc     hl
        call    gencom_tpa_read
        ld      (native_block_count),a
        inc     hl
        call    gencom_tpa_read
        ld      (native_block_count+1),a
.native_print_block_next:
        ld      hl,(native_block_count)
        ld      a,h
        or      l
        jr      z,native_list_block
        dec     hl
        ld      (native_block_count),hl
        ld      hl,(native_block_address)
        ; The byte source lives in the transient bank, while ESC handlers for
        ; viewport and scrolling live in the protected runtime page. Restore
        ; that page before native_putc interprets the character.
        call    native_tpa_read_restore_page_one_bridge
        inc     hl
        ld      (native_block_address),hl
        call    native_putc
        jr      .native_print_block_next

native_list_block:
        xor     a
        ret

; BDOS 24 and 104/105/109/110 operate on state pinned in the common bank.
; The 300 Hz resident ticker advances the SCB clock, so this same code works
; unchanged in ZEsarPCW, MAME, JOYCE and on physical PCW hardware.
native_return_login_vector:
        ld      hl,(OPENPCW_COMMON_LOGIN_VECTOR)
        ld      a,l
        ret

native_current_drive_mask:
        ld      hl,1
        ld      a,(OPENPCW_COMMON_CURRENT_DISK)
        or      a
        ret     z
        ld      b,a
.drive_mask_shift:
        add     hl,hl
        djnz    .drive_mask_shift
        ret

native_write_protect_result:
        call    native_current_drive_mask
        ld      de,(OPENPCW_COMMON_RO_VECTOR)
        ld      a,l
        or      e
        ld      l,a
        ld      a,h
        or      d
        ld      h,a
        ld      (OPENPCW_COMMON_RO_VECTOR),hl
        xor     a
        jp      native_m_status_result

native_return_ro_vector:
        ld      hl,(OPENPCW_COMMON_RO_VECTOR)
        ld      a,l
        ret

native_set_date_time:
        ld      hl,(m_fcb)
        call    gencom_tpa_read
        ld      e,a
        inc     hl
        call    gencom_tpa_read
        ld      d,a
        ld      a,d
        or      e
        jr      nz,.set_date_nonzero
        inc     de
.set_date_nonzero:
        ld      (OPENPCW_COMMON_SCB+058h),de
        inc     hl
        call    gencom_tpa_read
        ld      (OPENPCW_COMMON_SCB+05ah),a
        inc     hl
        call    gencom_tpa_read
        ld      (OPENPCW_COMMON_SCB+05bh),a
        xor     a
        ld      (OPENPCW_COMMON_SCB+05ch),a
        ld      hl,300
        ld      (OPENPCW_COMMON_CLOCK_TICKS),hl
        ret

native_get_date_time:
        ld      hl,(m_fcb)
        ld      a,(OPENPCW_COMMON_SCB+058h)
        call    gencom_tpa_write
        inc     hl
        ld      a,(OPENPCW_COMMON_SCB+059h)
        call    gencom_tpa_write
        inc     hl
        ld      a,(OPENPCW_COMMON_SCB+05ah)
        call    gencom_tpa_write
        inc     hl
        ld      a,(OPENPCW_COMMON_SCB+05bh)
        call    gencom_tpa_write
        ld      a,(OPENPCW_COMMON_SCB+05ch)
        ld      l,a
        ld      h,0
        ret

native_console_mode:
        ld      hl,(m_fcb)
        ld      a,h
        and     l
        inc     a
        jr      nz,.console_mode_set
        ld      hl,(OPENPCW_COMMON_SCB+033h)
        ld      a,l
        ret
.console_mode_set:
        ld      (OPENPCW_COMMON_SCB+033h),hl
        xor     a
        ld      l,a
        ld      h,a
        ret

native_output_delimiter:
        ld      hl,(m_fcb)
        ld      a,h
        and     l
        inc     a
        jr      nz,.output_delimiter_set
        ld      a,(OPENPCW_COMMON_SCB+037h)
native_console_result_a_hl:
        ld      l,a
        ld      h,0
        ret
.output_delimiter_set:
        ld      a,l
        ld      (OPENPCW_COMMON_SCB+037h),a
        xor     a
        ld      l,a
        ld      h,a
        ret

; BDOS 106/107 expose process-local password state and the six-byte operating
; system serial field. OpenPCW-OS assigns the identifier below as part of
; its public service design. See DES-BDOS-004 and REF-CPM3-PG.
native_set_default_password:
        ld      hl,(m_fcb)
        ld      de,native_default_password
        ld      b,8
.set_password_byte:
        call    gencom_tpa_read
        ld      (de),a
        inc     hl
        inc     de
        djnz    .set_password_byte
        xor     a
        ret

native_return_serial:
        ld      hl,(m_fcb)
        ld      de,native_serial_number
        ld      b,6
.return_serial_byte:
        ld      a,(de)
        call    gencom_tpa_write
        inc     hl
        inc     de
        djnz    .return_serial_byte
        xor     a
        ret

native_serial_number:    db 'OPCW01'

; Function 101 reads the public CP/M Plus directory-label record. Functions
; 100, 102 and 103 use the banked label/XFCB/SFCB overlay below.
native_directory_label:
        ld      a,(m_fcb)          ; Function 101 passes the drive in E
        cp      12
        jr      z,.label_m
        or      a
        jr      nz,.label_invalid
        call    disk_login
        jr      c,.label_bad
        ld      a,020h
        call    a_find_special
        jr      c,.label_missing
        ld      a,(ix+12)
        or      1
        ret
.label_m:
        ld      a,(m_label_data)
        ret
.label_missing:
        or      a                  ; preserve FFh on physical I/O failure
        ret     nz
        xor     a
        ret
.label_bad:
        ld      a,0ffh
        ret
.label_invalid:
        ld      a,4
        ld      (native_physical_error_code),a
        jr      .label_bad

; Clear the password mode and both four-byte timestamp fields before the
; matching XFCB/SFCB overlays repopulate the fields that exist.
native_clear_fcb_stamps:
        ld      hl,(m_fcb)
        ld      de,12
        add     hl,de
        xor     a
        call    gencom_tpa_write
        ld      hl,(m_fcb)
        ld      de,24
        add     hl,de
        ld      b,8
.clear_stamp:
        call    gencom_tpa_write
        inc     hl
        djnz    .clear_stamp
        ret

a_read_stamps:
        call    disk_login
        jr      c,.a_stamps_bad
        call    a_name_is_exact
        jr      c,.a_stamps_bad
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        ld      (a_find_user),a
        ld      hl,0
        ld      (wanted_extent),hl
        call    a_find_extent       ; extent zero owns the SFCB subfield
        jr      c,.a_stamps_bad
        call    native_clear_fcb_stamps
        ld      a,(a_dir_index)
        and     3
        cp      3
        jr      z,.a_stamps_ok
        ld      c,a
.a_stamps_to_sfcb:
        ld      de,32
        add     ix,de
        inc     c
        ld      a,c
        cp      3
        jr      nz,.a_stamps_to_sfcb
        ld      a,(ix+0)
        cp      021h
        jr      nz,.a_stamps_ok
        push    ix
        pop     de
        inc     de
        ld      a,(a_dir_index)
        and     3
        jr      z,.a_stamps_source_ready
        ld      c,a
.a_stamps_source_offset:
        ld      a,e
        add     a,10
        ld      e,a
        jr      nc,.a_stamps_source_no_carry
        inc     d
.a_stamps_source_no_carry:
        dec     c
        jr      nz,.a_stamps_source_offset
.a_stamps_source_ready:
        ld      hl,(m_fcb)
        ld      bc,24
        add     hl,bc
        ld      b,8
.a_stamps_copy:
        ld      a,(de)
        call    gencom_tpa_write
        inc     de
        inc     hl
        djnz    .a_stamps_copy
.a_stamps_ok:
        xor     a
        ret
.a_stamps_bad:
        ld      a,0ffh
        ret

; Find a directory entry whose drive byte equals A.  IX and the directory
; sector/index remain selected on success. Carry returns A=0 for absent and
; A=FFh for a physical read error.
a_find_special:
        ld      (a_found),a
        xor     a
        ld      (a_dir_sector),a
.special_sector:
        ld      a,(a_dir_sector)
        ld      c,a
        ld      a,(disk_dir_sectors)
        cp      c
        jr      z,.special_missing
        call    a_directory_sector_address
        call    read_logical_sector
        jr      c,.special_io
        ld      ix,sector_buffer
        ld      b,16
        ld      c,0
.special_entry:
        ld      a,(a_found)
        cp      (ix+0)
        jr      z,.special_found
        ld      de,32
        add     ix,de
        inc     c
        djnz    .special_entry
        ld      a,(a_dir_sector)
        inc     a
        ld      (a_dir_sector),a
        jr      .special_sector
.special_found:
        ld      a,c
        ld      (a_dir_index),a
        xor     a
        ret
.special_missing:
        xor     a
        scf
        ret
.special_io:
        ld      a,0ffh
        scf
        ret

; BDOS 36 derives the next 24-bit random record from EX/S2/CR. Access the FCB
; through the bank-one helpers so the implementation is identical with the
; physical native module mapped at 0000h-BFFFh.
native_set_random_record:
        ld      hl,(m_fcb)
        ld      de,12
        add     hl,de
        call    gencom_tpa_read       ; EX
        and     01fh
        ld      b,a
        inc     hl
        inc     hl
        call    gencom_tpa_read       ; S2
        and     03fh
        ld      c,a
        ld      de,18
        add     hl,de                 ; CR at FCB+32
        call    gencom_tpa_read
        and     07fh
        ld      d,a
        ld      a,b
        and     1
        rrca
        or      d
        inc     hl                    ; R0 at FCB+33
        call    gencom_tpa_write
        ld      a,b
        srl     a
        ld      d,a
        ld      a,c
        rlca
        rlca
        rlca
        rlca
        and     0f0h
        or      d
        inc     hl
        call    gencom_tpa_write      ; R1
        ld      a,c
        srl     a
        srl     a
        srl     a
        srl     a
        inc     hl
        call    gencom_tpa_write      ; R2
        xor     a
        ret

; BDOS 35 computes the virtual size from directory metadata, including sparse
; files. The drive byte is read from the caller's bank-one FCB; a zero drive
; uses the standard drive/user byte at logical address 0004h.
native_compute_file_size:
        call    native_fcb_drive
        cp      12
        jp      z,native_compute_m_size
        or      a
        jp      z,native_compute_a_size
        ld      a,0ffh
        ret

native_fcb_drive:
        ld      hl,(m_fcb)
        call    gencom_tpa_read
        or      a
        jr      z,.default_drive
        cp      1
        jr      z,.drive_a
        cp      13
        jr      z,.drive_m
        and     05fh
        cp      'A'
        jr      z,.drive_a
        cp      'M'
        jr      z,.drive_m
        ld      a,4
        ld      (native_physical_error_code),a
        ld      a,0ffh
        ret
.default_drive:
        ld      a,(OPENPCW_COMMON_CURRENT_DISK)
        and     00fh
        ret
.drive_a:
        xor     a
        ret
.drive_m:
        ld      a,12
        ret

; The M: directory proves that even an empty file exists. Its private sparse
; map stores absolute record numbers, so the virtual size is max(record)+1.
native_compute_m_size:
        call    m_find
        jr      c,.missing
        call    sparse_compute_slot_size
        ld      a,(native_size_found)
        or      a
        jp      z,native_size_write
        ld      hl,(native_size)
        inc     hl
        ld      (native_size),hl
        ld      a,h
        or      l
        jp      nz,native_size_write
        ld      a,(native_size+2)
        inc     a
        ld      (native_size+2),a
        jp      native_size_write
.missing:
        ld      a,0ffh
        ret

; Scan block-allocation keys for m_slot and derive the greatest valid logical
; record. native_size remains the record number (not yet max+1).
sparse_compute_slot_size:
        xor     a
        ld      (native_size),a
        ld      (native_size+1),a
        ld      (native_size+2),a
        ld      (native_size_found),a
        ld      a,SPARSE_METADATA_PAGE
        out     (0f1h),a
        ld      ix,SPARSE_ALLOCATION_BASE
        ld      a,(native_m_data_blocks)
        ld      b,a
        ld      c,0
.sparse_size_next_block:
        ld      a,(m_slot)
        cp      (ix+0)
        jr      nz,.advance_block
        push    bc
        ld      a,c
        call    sparse_highest_valid_record
        jr      c,.size_block_done
        ld      c,a
        ld      l,(ix+1)
        ld      h,(ix+2)
        ld      a,(ix+3)
        ld      b,4
.size_key_shift:
        add     hl,hl
        rla
        djnz    .size_key_shift
        ld      e,c
        ld      d,0
        add     hl,de
        jr      nc,.size_candidate_ready
        inc     a
.size_candidate_ready:
        ld      (native_size_candidate),hl
        ld      (native_size_candidate+2),a
        call    native_size_consider_candidate
.size_block_done:
        pop     bc
.advance_block:
        ld      de,4
        add     ix,de
        inc     c
        djnz    .sparse_size_next_block
        ret

; A=allocation index. Return A=highest valid record within its 2 KiB block,
; carry set if no record in the block has been materialised.
sparse_highest_valid_record:
        call    sparse_valid_address
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      a,d
        or      e
        jr      z,.no_valid_record
        ld      c,0
.valid_record_shift:
        srl     d
        rr      e
        inc     c
        ld      a,d
        or      e
        jr      nz,.valid_record_shift
        ld      a,c
        dec     a
        or      a
        ret
.no_valid_record:
        scf
        ret

; A: uses ordinary CP/M directory entries. For every matching extent the
; endpoint is (S2:EX * 128) + RC; the greatest endpoint is the virtual size.
native_compute_a_size:
        call    disk_login
        jp      c,.disk_error
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        ld      (native_size_user),a
        xor     a
        ld      (native_size),a
        ld      (native_size+1),a
        ld      (native_size+2),a
        ld      (native_size_found),a
        ld      (directory_sector),a
.size_next_sector:
        ld      a,(directory_sector)
        ld      c,a
        ld      a,(disk_dir_sectors)
        cp      c
        jp      z,.scan_done
        ld      l,c
        ld      h,0
        ld      de,(disk_data_start)
        add     hl,de
        call    read_logical_sector
        jp      c,.disk_error
        ld      ix,sector_buffer
        ld      b,16
.size_next_entry:
        ld      a,(native_size_user)
        cp      (ix+0)
        jr      nz,.advance_entry
        push    bc
        push    ix
        pop     hl
        inc     hl
        ld      de,m_name
        ld      b,11
.compare_name:
        ld      a,(hl)
        and     07fh
        ld      c,a
        ld      a,(de)
        cp      c
        jr      nz,.name_compared
        inc     hl
        inc     de
        djnz    .compare_name
.name_compared:
        pop     bc
        jr      nz,.advance_entry
        push    bc
        ld      a,(ix+14)
        and     03fh
        ld      l,a
        ld      h,0
        ld      c,5
.size_extent_shift:
        add     hl,hl
        dec     c
        jr      nz,.size_extent_shift
        ld      a,(ix+12)
        and     01fh
        or      l
        ld      l,a
        ld      a,l
        and     1
        rrca
        ld      c,a
        ld      a,(ix+15)
        add     a,c
        ld      (native_size_candidate),a
        ld      c,0
        jr      nc,.record_count_ready
        inc     c
.record_count_ready:
        srl     h
        rr      l
        ld      a,l
        add     a,c
        ld      (native_size_candidate+1),a
        ld      a,h
        adc     a,0
        ld      (native_size_candidate+2),a
        call    native_size_consider_candidate
        pop     bc
.advance_entry:
        ld      de,32
        add     ix,de
        djnz    .size_next_entry
        ld      a,(directory_sector)
        inc     a
        ld      (directory_sector),a
        jp      .size_next_sector
.scan_done:
        ld      a,(native_size_found)
        or      a
        jp      nz,native_size_write
.disk_error:
        ld      a,0ffh
        ret

; Keep the greatest unsigned 24-bit candidate in native_size.
native_size_consider_candidate:
        ld      a,(native_size_found)
        or      a
        jr      z,.size_store
        ld      a,(native_size_candidate+2)
        ld      c,a
        ld      a,(native_size+2)
        cp      c
        jr      c,.size_store
        ret     nz
        ld      a,(native_size_candidate+1)
        ld      c,a
        ld      a,(native_size+1)
        cp      c
        jr      c,.size_store
        ret     nz
        ld      a,(native_size_candidate)
        ld      c,a
        ld      a,(native_size)
        cp      c
        ret     nc
.size_store:
        ld      a,(native_size_candidate)
        ld      (native_size),a
        ld      a,(native_size_candidate+1)
        ld      (native_size+1),a
        ld      a,(native_size_candidate+2)
        ld      (native_size+2),a
        ld      a,1
        ld      (native_size_found),a
        ret

native_size_write:
        ld      hl,(m_fcb)
        ld      de,33
        add     hl,de
        ld      a,(native_size)
        call    gencom_tpa_write
        inc     hl
        ld      a,(native_size+1)
        call    gencom_tpa_write
        inc     hl
        ld      a,(native_size+2)
        call    gencom_tpa_write
        xor     a
        ret

; BDOS 152 parses one documented CP/M file specification into a 36-byte FCB.
; All accesses go through the transient-bank helpers so the same routine runs
; with the native module mapped over logical 0000h-BFFFh. Input is capped at
; 128 bytes and only the public A:..P: drive range is accepted.
native_parse_filename:
        ld      hl,(m_fcb)
        call    gencom_read_word
        ld      (native_parse_input),de
        call    gencom_read_word
        ld      (native_parse_fcb),de
        ld      a,128
        ld      (native_parse_left),a
.parse_leading:
        call    native_parse_get
        jp      c,.parse_error
        cp      ' '
        jr      z,.parse_consume_leading
        cp      9
        jr      nz,.parse_nonempty
.parse_consume_leading:
        call    native_parse_advance
        jr      .parse_leading
.parse_nonempty:
        or      a
        jp      z,.parse_end
        cp      13
        jp      z,.parse_end

        ld      hl,(native_parse_fcb)
        ld      b,36
        xor     a
        call    native_parse_fill
        ld      hl,(native_parse_fcb)
        inc     hl
        ld      b,11
        ld      a,' '
        call    native_parse_fill
        ld      hl,(native_parse_fcb)
        ld      de,16
        add     hl,de
        ld      b,8
        ld      a,' '
        call    native_parse_fill

        call    native_parse_get
        call    uppercase_a
        cp      'A'
        jr      c,.parse_no_drive
        cp      'P'+1
        jr      nc,.parse_no_drive
        ld      (native_parse_character),a
        ld      a,(native_parse_left)
        cp      2
        jr      c,.parse_no_drive
        ld      hl,(native_parse_input)
        inc     hl
        call    gencom_tpa_read
        cp      ':'
        jr      nz,.parse_no_drive
        ld      a,(native_parse_character)
        sub     'A'-1
        ld      hl,(native_parse_fcb)
        call    gencom_tpa_write
        call    native_parse_advance
        call    native_parse_advance
.parse_no_drive:
        call    native_parse_get
        jp      c,.parse_error
        call    native_parse_is_delimiter
        jr      z,.parse_name_done
        ld      hl,(native_parse_fcb)
        inc     hl
        ld      b,8
        ld      c,1
        call    native_parse_field
        jr      c,.parse_error
.parse_name_done:
        call    native_parse_get
        jr      c,.parse_error
        cp      '.'
        jr      nz,.parse_type_done
        call    native_parse_advance
        ld      hl,(native_parse_fcb)
        ld      de,9
        add     hl,de
        ld      b,3
        ld      c,1
        call    native_parse_field
        jr      c,.parse_error
.parse_type_done:
        call    native_parse_get
        jr      c,.parse_error
        cp      ';'
        jr      nz,.parse_password_done
        call    native_parse_advance
        ld      hl,(native_parse_fcb)
        ld      de,16
        add     hl,de
        ld      b,8
        ld      c,0
        call    native_parse_field
        jr      c,.parse_error
.parse_password_done:
        call    native_parse_get
        jr      c,.parse_error
        call    native_parse_is_delimiter
        jr      nz,.parse_error
        ld      hl,(native_parse_input)
        ld      (native_parse_separator),hl
.parse_trailing:
        call    native_parse_get
        jr      c,.parse_error
        cp      ' '
        jr      z,.parse_consume_trailing
        cp      9
        jr      nz,.parse_after_blanks
.parse_consume_trailing:
        call    native_parse_advance
        jr      .parse_trailing
.parse_after_blanks:
        or      a
        jr      z,.parse_end
        cp      13
        jr      z,.parse_end
        call    native_parse_is_delimiter
        jr      nz,.parse_return_separator
        ld      hl,(native_parse_input)
        xor     a
        ret
.parse_return_separator:
        ld      hl,(native_parse_separator)
        xor     a
        ret
.parse_end:
        ld      hl,0
        xor     a
        ret
.parse_error:
        ld      hl,0ffffh
        ld      a,0ffh
        ret

; Return the current input byte with carry clear, or carry set once the
; 128-byte parser window has been exhausted.
native_parse_get:
        ld      a,(native_parse_left)
        or      a
        jr      z,.parse_get_exhausted
        ld      hl,(native_parse_input)
        call    gencom_tpa_read
        or      a
        ret
.parse_get_exhausted:
        scf
        ret

native_parse_advance:
        ld      hl,(native_parse_input)
        inc     hl
        ld      (native_parse_input),hl
        ld      a,(native_parse_left)
        dec     a
        ld      (native_parse_left),a
        ret

; A remains unchanged; Z says the byte is one of CP/M's parser delimiters.
native_parse_is_delimiter:
        ld      hl,native_parse_delimiters
        ld      b,native_parse_delimiters_end-native_parse_delimiters
.parse_delimiter_next:
        cp      (hl)
        ret     z
        inc     hl
        djnz    .parse_delimiter_next
        ret

; HL=destination, B=capacity, C=wildcard enabled. The destination has already
; been blank-filled. Carry reports a control byte, overlong field or exhausted
; input; '*' fills the remainder of name/type with question marks.
native_parse_field:
        ld      (native_parse_output),hl
        ld      a,b
        ld      (native_parse_capacity),a
        ld      a,c
        ld      (native_parse_wildcard),a
        xor     a
        ld      (native_parse_used),a
.parse_field_next:
        call    native_parse_get
        jr      c,.parse_field_bad
        ld      (native_parse_character),a
        call    native_parse_is_delimiter
        jr      z,.parse_field_good
        cp      32
        jr      c,.parse_field_bad
        cp      127
        jr      nc,.parse_field_bad
        ld      a,(native_parse_used)
        ld      c,a
        ld      a,(native_parse_capacity)
        cp      c
        jr      z,.parse_field_bad
        call    native_parse_advance
        ld      a,(native_parse_character)
        cp      '*'
        jr      nz,.parse_field_store
        ld      a,(native_parse_wildcard)
        or      a
        jr      nz,.parse_field_fill
.parse_field_store:
        ld      hl,(native_parse_output)
        ld      a,(native_parse_used)
        ld      e,a
        ld      d,0
        add     hl,de
        ld      a,(native_parse_character)
        call    uppercase_a
        call    gencom_tpa_write
        ld      a,(native_parse_used)
        inc     a
        ld      (native_parse_used),a
        jr      .parse_field_next
.parse_field_fill:
        ld      a,(native_parse_used)
        ld      c,a
        ld      a,(native_parse_capacity)
        cp      c
        jr      z,.parse_field_good
        ld      hl,(native_parse_output)
        ld      e,c
        ld      d,0
        add     hl,de
        ld      a,'?'
        call    gencom_tpa_write
        ld      a,(native_parse_used)
        inc     a
        ld      (native_parse_used),a
        jr      .parse_field_fill
.parse_field_good:
        or      a
        ret
.parse_field_bad:
        scf
        ret

native_parse_fill:
.parse_fill_next:
        call    gencom_tpa_write
        inc     hl
        djnz    .parse_fill_next
        ret

native_parse_delimiters:
        db      0,' ',9,13,';','=','<','>','.',':',',','|','[',']'
native_parse_delimiters_end:

; Copy and normalise the FCB's 8.3 name before mapping the directory into the
; same 4000h window. CP/M uses the high bits of name/type bytes for attributes;
; those bits are not part of filename identity.
m_copy_name:
        ld      hl,(m_fcb)
        inc     hl
        ld      de,m_name
        ld      b,11
.m_copy_name_byte:
        call    gencom_tpa_read
        and     07fh
        ld      (de),a
        inc     hl
        inc     de
        djnz    .m_copy_name_byte
        ret

; Physical A: filesystem mutation ---------------------------------------
;
; This is an independent implementation of the public CP/M directory and
; allocation format.  It operates through the same geometry/FDC primitives as
; the read-only loader, using the identical uPD765 path in MAME, Joyce and on a
; real PCW.
a_copy_wanted_name:
        ld      hl,m_name
        ld      de,wanted_name
        ld      bc,11
        ldir
        ret

a_prepare:
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        ld      (a_find_user),a
        ld      hl,(OPENPCW_COMMON_RO_VECTOR)
        bit     0,l
        jr      z,.a_prepare_login
        ld      a,2
        ld      (native_physical_error_code),a
        jr      .a_prepare_bad
.a_prepare_login:
        call    disk_login
        ret     nc
.a_prepare_bad:
        ld      a,0ffh
        scf
        ret

; Return carry for an empty or ambiguous 8.3 name.
a_name_is_exact:
        ld      a,(m_name)
        cp      ' '
        jr      z,.a_name_bad
        ld      hl,m_name
        ld      b,11
.a_name_byte:
        ld      a,(hl)
        cp      '?'
        jr      z,.a_name_bad
        inc     hl
        djnz    .a_name_byte
        or      a
        ret
.a_name_bad:
        scf
        ret

; Compare IX's directory name with m_name.  High attribute bits are ignored.
a_entry_name_exact:
        push    ix
        pop     hl
        inc     hl
        ld      de,m_name
        ld      b,11
.a_exact_byte:
        ld      a,(hl)
        and     07fh
        ld      c,a
        ld      a,(de)
        cp      c
        ret     nz
        inc     hl
        inc     de
        djnz    .a_exact_byte
        xor     a
        ret

; The delete call accepts '?' in the filename and type fields.
a_entry_name_pattern:
        push    ix
        pop     hl
        inc     hl
        ld      de,m_name
        ld      b,11
.a_pattern_byte:
        ld      a,(de)
        cp      '?'
        jr      z,.a_pattern_next
        ld      c,a
        ld      a,(hl)
        and     07fh
        cp      c
        ret     nz
.a_pattern_next:
        inc     hl
        inc     de
        djnz    .a_pattern_byte
        xor     a
        ret

a_directory_sector_address:
        ld      a,(a_dir_sector)
        ld      l,a
        ld      h,0
        ld      de,(disk_data_start)
        add     hl,de
        ret

a_index_to_ix:
        ld      ix,sector_buffer
        ld      a,(a_dir_index)
        or      a
        ret     z
        ld      de,32
.a_index_advance:
        add     ix,de
        dec     a
        jr      nz,.a_index_advance
        ret

; Find the current user's exact name and normalized extent.  On success the
; directory location is retained and IX addresses its entry.  Carry with A=0
; means absent; carry with A=FFh means a physical read failure.
a_find_extent:
        xor     a
        ld      (a_dir_sector),a
.a_find_extent_sector:
        ld      a,(a_dir_sector)
        ld      c,a
        ld      a,(disk_dir_sectors)
        cp      c
        jr      z,.a_find_extent_missing
        call    a_directory_sector_address
        call    read_logical_sector
        jr      c,.a_find_extent_io
        ld      ix,sector_buffer
        ld      b,16
        ld      c,0
.a_find_extent_entry:
        ld      a,(a_find_user)
        cp      (ix+0)
        jr      nz,.a_find_extent_advance
        push    bc
        call    entry_matches
        pop     bc
        jr      nz,.a_find_extent_advance
        ld      a,c
        ld      (a_dir_index),a
        xor     a
        ret
.a_find_extent_advance:
        ld      de,32
        add     ix,de
        inc     c
        djnz    .a_find_extent_entry
        ld      a,(a_dir_sector)
        inc     a
        ld      (a_dir_sector),a
        jr      .a_find_extent_sector
.a_find_extent_missing:
        xor     a
        scf
        ret
.a_find_extent_io:
        ld      a,0ffh
        scf
        ret

; Find one erased (E5h) directory slot.
a_find_free_entry:
        xor     a
        ld      (a_dir_sector),a
.a_find_free_sector:
        ld      a,(a_dir_sector)
        ld      c,a
        ld      a,(disk_dir_sectors)
        cp      c
        jr      z,.a_find_free_missing
        call    a_directory_sector_address
        call    read_logical_sector
        jr      c,.a_find_free_io
        ld      ix,sector_buffer
        ld      b,16
        ld      c,0
.a_find_free_slot:
        ld      a,(ix+0)
        cp      0e5h
        jr      z,.a_find_free_found
        ld      de,32
        add     ix,de
        inc     c
        djnz    .a_find_free_slot
        ld      a,(a_dir_sector)
        inc     a
        ld      (a_dir_sector),a
        jr      .a_find_free_sector
.a_find_free_found:
        ld      a,c
        ld      (a_dir_index),a
        xor     a
        ret
.a_find_free_missing:
        xor     a
        scf
        ret
.a_find_free_io:
        ld      a,0ffh
        scf
        ret

; Find any extent of the current exact-case file.
a_file_exists_exact:
        xor     a
        ld      (a_dir_sector),a
.a_exists_sector:
        ld      a,(a_dir_sector)
        ld      c,a
        ld      a,(disk_dir_sectors)
        cp      c
        jr      z,.a_exists_missing
        call    a_directory_sector_address
        call    read_logical_sector
        jr      c,.a_exists_io
        ld      ix,sector_buffer
        ld      b,16
        ld      c,0
.a_exists_entry:
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        cp      (ix+0)
        jr      nz,.a_exists_advance
        push    bc
        call    a_entry_name_exact
        pop     bc
        jr      z,.a_exists_found
.a_exists_advance:
        ld      de,32
        add     ix,de
        inc     c
        djnz    .a_exists_entry
        ld      a,(a_dir_sector)
        inc     a
        ld      (a_dir_sector),a
        jr      .a_exists_sector
.a_exists_found:
        ld      a,c
        ld      (a_dir_index),a
        xor     a
        ret
.a_exists_missing:
        xor     a
        scf
        ret
.a_exists_io:
        ld      a,0ffh
        scf
        ret

a_init_current_entry:
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        ld      (ix+0),a
        push    ix
        pop     hl
        inc     hl
        ld      de,m_name
        ld      b,11
.a_init_name:
        ld      a,(de)
        ld      (hl),a
        inc     de
        inc     hl
        djnz    .a_init_name
        xor     a
        ld      b,20
.a_init_metadata:
        ld      (hl),a
        inc     hl
        djnz    .a_init_metadata
        ret

a_reload_entry:
        call    a_directory_sector_address
        call    read_logical_sector
        ret     c
        call    a_index_to_ix
        ld      a,(a_entry_new)
        or      a
        call    nz,a_init_current_entry
        xor     a
        ret

a_write_current_directory:
        call    a_directory_sector_address
        jp      write_logical_sector

; Build a bitmap of every allocated block.  A 256-byte map covers 2048 blocks,
; comfortably beyond the standard PCW 720K geometries while keeping allocation
; to one directory pass per new block.
a_scan_used_blocks:
        ld      a,(disk_dsm+1)
        cp      8
        jr      nc,.a_scan_used_too_large
        xor     a
        ld      hl,overlay_used_blocks
        ld      de,overlay_used_blocks+1
        ld      (hl),a
        ld      bc,255
        ldir
        ld      (a_dir_sector),a
.a_scan_used_sector:
        ld      a,(a_dir_sector)
        ld      c,a
        ld      a,(disk_dir_sectors)
        cp      c
        jr      z,.a_scan_used_done
        call    a_directory_sector_address
        call    read_logical_sector
        jr      c,.a_scan_used_io
        ld      ix,sector_buffer
        ld      b,16
.a_scan_used_entry:
        ld      a,(ix+0)
        cp      16
        jr      nc,.a_scan_used_advance
        push    bc
        call    overlay_mark_entry_blocks
        pop     bc
.a_scan_used_advance:
        ld      de,32
        add     ix,de
        djnz    .a_scan_used_entry
        ld      a,(a_dir_sector)
        inc     a
        ld      (a_dir_sector),a
        jr      .a_scan_used_sector
.a_scan_used_done:
        xor     a
        ret
.a_scan_used_too_large:
        ld      a,2
        scf
        ret
.a_scan_used_io:
        ld      a,0ffh
        scf
        ret

a_allocate_block:
        call    a_scan_used_blocks
        ret     c
        call    overlay_find_free_block
        jr      c,.a_allocate_full
        ld      hl,(overlay_free_block)
        ld      (a_block),hl
        xor     a
        ret
.a_allocate_full:
        ld      a,2
        scf
        ret

; Write filesystem sector HL from sector_buffer through a synchronous uPD765
; WRITE DATA command.
write_logical_sector:
        ld      (sector_requested),hl
        ld      d,0
.a_write_divide_track:
        ld      a,(disk_sectors)
        ld      c,a
        ld      b,0
        ld      a,h
        or      a
        jr      nz,.a_write_subtract_track
        ld      a,l
        cp      c
        jr      c,.a_write_track_ready
.a_write_subtract_track:
        or      a
        sbc     hl,bc
        inc     d
        jr      .a_write_divide_track
.a_write_track_ready:
        ld      e,l
        call    native_map_physical_sector
        jr      c,.a_write_map_error
        ld      hl,sector_buffer
        call    fdc_write_sector
        ret     nc
        ld      a,(last_fdc_st1)
        and     2
        ld      a,1
        jr      z,.a_write_error_store
        inc     a                       ; physical error 2: read-only disk
.a_write_error_store:
        ld      (native_physical_error_code),a
        scf
        ret
.a_write_map_error:
        ld      a,1                     ; physical error 1: permanent I/O
        ld      (native_physical_error_code),a
        scf
        ret

a_save_entry_location:
        ld      a,(a_dir_sector)
        ld      (a_entry_sector),a
        ld      a,(a_dir_index)
        ld      (a_entry_index),a
        ret

a_restore_entry_location:
        ld      a,(a_entry_sector)
        ld      (a_dir_sector),a
        ld      a,(a_entry_index)
        ld      (a_dir_index),a
        ret

; Return the allocation block in a_block and Z when the requested slot is
; unallocated.  CP/M uses sixteen byte pointers below DSM 256 and eight word
; pointers otherwise.
a_get_entry_block:
        ld      a,(a_block_slot)
        ld      l,a
        ld      h,0
        ld      a,(disk_dsm+1)
        or      a
        jr      z,.a_get_slot_ready
        add     hl,hl
.a_get_slot_ready:
        ld      de,16
        add     hl,de
        push    ix
        pop     de
        add     hl,de
        ld      e,(hl)
        inc     hl
        ld      a,(disk_dsm+1)
        or      a
        ld      d,0
        jr      z,.a_get_block_ready
        ld      d,(hl)
.a_get_block_ready:
        ld      (a_block),de
        ld      a,d
        or      e
        ret

a_set_entry_block:
        ld      a,(a_block_slot)
        ld      l,a
        ld      h,0
        ld      a,(disk_dsm+1)
        or      a
        jr      z,.a_set_slot_ready
        add     hl,hl
.a_set_slot_ready:
        ld      de,16
        add     hl,de
        push    ix
        pop     de
        add     hl,de
        ld      de,(a_block)
        ld      (hl),e
        inc     hl
        ld      a,(disk_dsm+1)
        or      a
        ret     z
        ld      (hl),d
        ret

; Derive the normalized directory extent, record within that entry, allocation
; slot and record within its allocation block from m_record.
a_record_geometry:
        ld      hl,(m_record)
        ld      a,(m_record+2)
        ld      c,a
        ld      a,(disk_extent_shift)
        add     a,7
        ld      b,a
        ld      a,c
.a_geometry_extent_shift:
        srl     a
        rr      h
        rr      l
        djnz    .a_geometry_extent_shift
        ld      (a_extent),hl
        ld      (wanted_extent),hl

        ld      hl,(m_record)
        ld      a,(disk_extent_shift)
        or      a
        jr      nz,.a_geometry_wide_within
        ld      a,l
        and     07fh
        ld      l,a
        ld      h,0
        jr      .a_geometry_within_ready
.a_geometry_wide_within:
        dec     a
        ld      b,a
        ld      a,1
        jr      z,.a_geometry_high_mask_ready
.a_geometry_high_mask:
        add     a,a
        djnz    .a_geometry_high_mask
.a_geometry_high_mask_ready:
        dec     a
        and     h
        ld      h,a
.a_geometry_within_ready:
        ld      (a_record_within),hl

        ld      a,(disk_block_shift)
        ld      b,a
        ld      a,1
.a_geometry_block_mask:
        add     a,a
        djnz    .a_geometry_block_mask
        dec     a
        ld      c,a
        ld      a,(m_record)
        and     c
        ld      (a_record_in_block),a

        ld      hl,(a_record_within)
        ld      a,(disk_block_shift)
        ld      b,a
.a_geometry_slot_shift:
        srl     h
        rr      l
        djnz    .a_geometry_slot_shift
        ld      a,l
        ld      (a_block_slot),a
        ret

; Find or reserve the directory slot for a_record's normalized extent.
a_ensure_entry:
        call    a_find_extent
        jr      c,.a_ensure_missing
        xor     a
        ld      (a_entry_new),a
        call    a_save_entry_location
        ret
.a_ensure_missing:
        or      a
        ret     nz
        call    a_find_free_entry
        ret     c
        ld      a,1
        ld      (a_entry_new),a
        call    a_save_entry_location
        xor     a
        ret

; Convert a_block to its first 512-byte filesystem sector.
a_block_first_sector:
        ld      hl,(a_block)
        ld      a,(disk_block_shift)
        sub     2
        ld      b,a
        jr      z,.a_block_scaled
.a_block_scale:
        add     hl,hl
        djnz    .a_block_scale
.a_block_scaled:
        ld      de,(disk_data_start)
        add     hl,de
        ret

a_zero_new_block:
        call    a_block_first_sector
        ld      (a_data_sector),hl
        ld      a,(disk_block_sectors)
        ld      (a_sectors_left),a
.a_zero_block_sector:
        xor     a
        ld      hl,sector_buffer
        ld      de,sector_buffer+1
        ld      (hl),a
        ld      bc,511
        ldir
        ld      hl,(a_data_sector)
        call    write_logical_sector
        jr      c,.a_zero_block_io
        ld      hl,(a_data_sector)
        inc     hl
        ld      (a_data_sector),hl
        ld      a,(a_sectors_left)
        dec     a
        ld      (a_sectors_left),a
        jr      nz,.a_zero_block_sector
        xor     a
        ret
.a_zero_block_io:
        ld      a,0ffh
        scf
        ret

; Overlay one 128-byte DMA record in its physical sector and write it through
; the controller.  The other three records retain their prior contents unless
; Function 40 explicitly zeroed a newly allocated block first.
a_write_record_payload:
        call    a_block_first_sector
        ld      a,(a_record_in_block)
        srl     a
        srl     a
        ld      e,a
        ld      d,0
        add     hl,de
        ld      (a_data_sector),hl
        call    read_logical_sector
        jr      c,.a_payload_io
        ld      a,(a_record_in_block)
        and     3
        ld      l,a
        ld      h,0
        ld      b,7
.a_payload_offset:
        add     hl,hl
        djnz    .a_payload_offset
        ld      de,sector_buffer
        add     hl,de
        ex      de,hl
        ld      hl,(m_dma)
        ld      b,128
.a_payload_copy:
        call    gencom_tpa_read
        ld      (de),a
        inc     hl
        inc     de
        djnz    .a_payload_copy
        ld      hl,(a_data_sector)
        call    write_logical_sector
        jr      c,.a_payload_io
        xor     a
        ret
.a_payload_io:
        ld      a,0ffh
        scf
        ret

; Persist the block pointer and extend RC/EX/S2 only when this write grows the
; directory entry.  Rewriting an earlier record must never truncate the file.
a_update_current_entry:
        call    a_restore_entry_location
        call    a_reload_entry
        jr      c,.a_update_io
        call    a_set_entry_block
        call    entry_record_count
        ld      de,(a_record_within)
        inc     de
        push    hl
        or      a
        sbc     hl,de
        pop     hl
        jr      nc,.a_update_count_done

        ld      hl,(m_record)
        ld      a,(m_record+2)
        ld      b,7
.a_update_extent_shift:
        srl     a
        rr      h
        rr      l
        djnz    .a_update_extent_shift
        ld      a,l
        and     01fh
        ld      (ix+12),a
        ld      b,5
.a_update_s2_shift:
        srl     h
        rr      l
        djnz    .a_update_s2_shift
        ld      a,l
        and     03fh
        ld      (ix+14),a
        ld      a,(m_record)
        and     07fh
        inc     a
        ld      (ix+15),a
.a_update_count_done:
        call    a_copy_entry_metadata_to_fcb
        call    a_write_current_directory
        jr      c,.a_update_io
        xor     a
        ld      (a_entry_new),a
        ld      (cached_entry_valid),a
        ret
.a_update_io:
        ld      a,0ffh
        scf
        ret

a_write_one_record:
        call    a_record_geometry
        call    a_ensure_entry
        jr      c,.a_write_one_no_entry
        call    a_restore_entry_location
        call    a_reload_entry
        jr      c,.a_write_one_io
        call    a_get_entry_block
        jr      nz,.a_write_one_block_ready
        call    a_allocate_block
        ret     c
        ld      a,1
        ld      (a_new_block),a
        call    a_restore_entry_location
        call    a_reload_entry
        jr      c,.a_write_one_io
        call    a_set_entry_block
        jr      .a_write_one_maybe_zero
.a_write_one_block_ready:
        xor     a
        ld      (a_new_block),a
.a_write_one_maybe_zero:
        ld      a,(a_zero_fill)
        or      a
        jr      z,.a_write_one_payload
        ld      a,(a_new_block)
        or      a
        jr      z,.a_write_one_payload
        call    a_zero_new_block
        ret     c
.a_write_one_payload:
        call    a_write_record_payload
        ret     c
        jp      a_update_current_entry
.a_write_one_no_entry:
        or      a
        ret     nz
        ld      a,(a_no_directory_code)
        scf
        ret
.a_write_one_io:
        ld      a,0ffh
        scf
        ret

a_transfer_write:
.a_transfer_write_next:
        call    a_write_one_record
        ret     c
        ld      a,(m_is_sequential)
        or      a
        call    z,a_write_fcb_position
        call    m_transfer_advance
        ld      a,(m_left)
        dec     a
        ld      (m_left),a
        jr      nz,.a_transfer_write_next
        xor     a
        ret

a_write_sequential:
        call    a_prepare
        ret     c
        call    a_name_is_exact
        jr      c,.a_write_sequential_bad
        call    m_load_sequential_record
        ld      a,1
        ld      (m_is_sequential),a
        ld      (a_no_directory_code),a
        xor     a
        ld      (a_zero_fill),a
        jp      a_transfer_write
.a_write_sequential_bad:
        ld      a,0ffh
        scf
        ret

a_write_random:
        call    a_prepare
        ret     c
        call    a_name_is_exact
        jr      c,.a_write_random_bad
        call    m_load_random_record
        ld      a,(m_record+2)
        cp      4
        jr      nc,.a_write_random_range
        call    m_write_random_cr
        xor     a
        ld      (m_is_sequential),a
        ld      a,5
        ld      (a_no_directory_code),a
        call    a_transfer_write
        ret     c
        xor     a
        ret
.a_write_random_range:
        ld      a,6
        scf
        ret
.a_write_random_bad:
        ld      a,0ffh
        scf
        ret

; Set EX/S2/CR to the absolute record in m_record; random fields are untouched.
a_write_fcb_position:
        ld      hl,(m_record)
        ld      a,(m_record+2)
        ld      b,7
.a_fcb_position_shift:
        srl     a
        rr      h
        rr      l
        djnz    .a_fcb_position_shift
        ld      a,l
        and     01fh
        ld      c,a
        ld      hl,(m_fcb)
        ld      de,12
        add     hl,de
        ld      a,c
        call    gencom_tpa_write
        inc     hl
        inc     hl
        ld      de,(m_record)
        ld      a,(m_record+2)
        ld      b,12
.a_fcb_s2_shift:
        srl     a
        rr      d
        rr      e
        djnz    .a_fcb_s2_shift
        ld      a,e
        and     03fh
        call    a_write_fcb_s2
        ; m_write_random_cr committed the requested CR before I/O so errors
        ; preserve CP/M Plus's public cursor contract. Mark the successful
        ; first transfer; later records in the same multisector call must not
        ; replace EX/S2 with their internal continuation position.
        ld      a,2
        ld      (m_is_sequential),a
        ret

a_make:
        call    a_prepare
        ret     c
        call    a_name_is_exact
        jp      c,native_directory_error_9
        call    a_file_exists_exact
        jp      nc,native_directory_error_8
        or      a
        jr      nz,.a_make_io
        call    a_find_free_entry
        jr      c,.a_make_failed
        call    a_init_current_entry
        call    a_write_current_directory
        jr      c,.a_make_io
        ld      hl,(m_fcb)
        ld      de,12
        add     hl,de
        xor     a
        ld      b,21
.a_make_clear_fcb:
        call    gencom_tpa_write
        inc     hl
        djnz    .a_make_clear_fcb
        ld      (cached_entry_valid),a
        ret
.a_make_failed:
        or      a
        ret     nz
.a_make_bad:
        ld      a,0ffh
        scf
        ret
.a_make_io:
        ld      a,0ffh
        scf
        ret

; Preflight an ambiguous delete: CP/M requires that a read-only match prevents
; the entire operation, rather than deleting the writable subset first.
a_delete_preflight:
        xor     a
        ld      (a_found),a
        ld      (a_dir_sector),a
.a_delete_check_sector:
        ld      a,(a_dir_sector)
        ld      c,a
        ld      a,(disk_dir_sectors)
        cp      c
        jr      z,.a_delete_check_done
        call    a_directory_sector_address
        call    read_logical_sector
        jr      c,.a_delete_check_io
        ld      ix,sector_buffer
        ld      b,16
.a_delete_check_entry:
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        cp      (ix+0)
        jr      nz,.a_delete_check_advance
        push    bc
        call    a_entry_name_pattern
        pop     bc
        jr      nz,.a_delete_check_advance
        ld      a,1
        ld      (a_found),a
        bit     7,(ix+9)
        jr      nz,.a_delete_check_read_only
.a_delete_check_advance:
        ld      de,32
        add     ix,de
        djnz    .a_delete_check_entry
        ld      a,(a_dir_sector)
        inc     a
        ld      (a_dir_sector),a
        jr      .a_delete_check_sector
.a_delete_check_done:
        ld      a,(a_found)
        or      a
        jr      z,.a_delete_check_missing
        xor     a
        ret
.a_delete_check_missing:
        ld      a,0ffh
        scf
        ret
.a_delete_check_read_only:
        ld      a,0ffh
        scf
        ret
.a_delete_check_io:
        ld      a,0ffh
        scf
        ret

a_delete_apply:
        xor     a
        ld      (a_dir_sector),a
.a_delete_apply_sector:
        ld      a,(a_dir_sector)
        ld      c,a
        ld      a,(disk_dir_sectors)
        cp      c
        jr      z,.a_delete_apply_done
        call    a_directory_sector_address
        call    read_logical_sector
        jr      c,.a_delete_apply_io
        xor     a
        ld      (a_sector_changed),a
        ld      ix,sector_buffer
        ld      b,16
.a_delete_apply_entry:
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        cp      (ix+0)
        jr      nz,.a_delete_apply_advance
        push    bc
        call    a_entry_name_pattern
        pop     bc
        jr      nz,.a_delete_apply_advance
        ld      (ix+0),0e5h
        ld      a,1
        ld      (a_sector_changed),a
.a_delete_apply_advance:
        ld      de,32
        add     ix,de
        djnz    .a_delete_apply_entry
        ld      a,(a_sector_changed)
        or      a
        jr      z,.a_delete_apply_next
        call    a_write_current_directory
        jr      c,.a_delete_apply_io
.a_delete_apply_next:
        ld      a,(a_dir_sector)
        inc     a
        ld      (a_dir_sector),a
        jr      .a_delete_apply_sector
.a_delete_apply_done:
        xor     a
        ld      (cached_entry_valid),a
        ret
.a_delete_apply_io:
        ld      a,0ffh
        scf
        ret

a_delete:
        call    a_prepare
        ret     c
        ; Interface attribute f5' requests XFCB-only deletion.  This native,
        ; non-password filesystem has no XFCBs, for which CP/M specifies a
        ; successful no-op.
        ld      hl,(m_fcb)
        ld      de,5
        add     hl,de
        call    gencom_tpa_read
        and     080h
        jr      nz,.a_delete_xfcb_noop
        call    a_delete_preflight
        ret     c
        jp      a_delete_apply
.a_delete_xfcb_noop:
        xor     a
        ret

a_copy_new_name:
        ld      hl,(m_fcb)
        ld      de,17
        add     hl,de
        ld      de,a_new_name
        ld      b,11
.a_copy_new_byte:
        call    gencom_tpa_read
        and     07fh
        ld      (de),a
        inc     hl
        inc     de
        djnz    .a_copy_new_byte
        ret

a_new_name_is_exact:
        ld      a,(a_new_name)
        cp      ' '
        jr      z,.a_new_name_bad
        ld      hl,a_new_name
        ld      b,11
.a_new_name_byte:
        ld      a,(hl)
        cp      '?'
        jr      z,.a_new_name_bad
        inc     hl
        djnz    .a_new_name_byte
        or      a
        ret
.a_new_name_bad:
        scf
        ret

a_entry_name_new:
        push    ix
        pop     hl
        inc     hl
        ld      de,a_new_name
        ld      b,11
.a_new_exact_byte:
        ld      a,(hl)
        and     07fh
        ld      c,a
        ld      a,(de)
        cp      c
        ret     nz
        inc     hl
        inc     de
        djnz    .a_new_exact_byte
        xor     a
        ret

a_new_file_exists:
        xor     a
        ld      (a_dir_sector),a
.a_new_exists_sector:
        ld      a,(a_dir_sector)
        ld      c,a
        ld      a,(disk_dir_sectors)
        cp      c
        jr      z,.a_new_exists_missing
        call    a_directory_sector_address
        call    read_logical_sector
        jr      c,.a_new_exists_io
        ld      ix,sector_buffer
        ld      b,16
.a_new_exists_entry:
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        cp      (ix+0)
        jr      nz,.a_new_exists_advance
        push    bc
        call    a_entry_name_new
        pop     bc
        jr      z,.a_new_exists_found
.a_new_exists_advance:
        ld      de,32
        add     ix,de
        djnz    .a_new_exists_entry
        ld      a,(a_dir_sector)
        inc     a
        ld      (a_dir_sector),a
        jr      .a_new_exists_sector
.a_new_exists_found:
        xor     a
        ret
.a_new_exists_missing:
        xor     a
        scf
        ret
.a_new_exists_io:
        ld      a,0ffh
        scf
        ret

; Verify that the old exact name exists and is not read-only.
a_rename_preflight:
        xor     a
        ld      (a_found),a
        ld      (a_dir_sector),a
.a_rename_check_sector:
        ld      a,(a_dir_sector)
        ld      c,a
        ld      a,(disk_dir_sectors)
        cp      c
        jr      z,.a_rename_check_done
        call    a_directory_sector_address
        call    read_logical_sector
        jr      c,.a_rename_check_io
        ld      ix,sector_buffer
        ld      b,16
.a_rename_check_entry:
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        cp      (ix+0)
        jr      nz,.a_rename_check_advance
        push    bc
        call    a_entry_name_exact
        pop     bc
        jr      nz,.a_rename_check_advance
        ld      a,1
        ld      (a_found),a
        bit     7,(ix+9)
        jr      nz,.a_rename_check_bad
.a_rename_check_advance:
        ld      de,32
        add     ix,de
        djnz    .a_rename_check_entry
        ld      a,(a_dir_sector)
        inc     a
        ld      (a_dir_sector),a
        jr      .a_rename_check_sector
.a_rename_check_done:
        ld      a,(a_found)
        or      a
        jr      z,.a_rename_check_bad
        xor     a
        ret
.a_rename_check_bad:
        ld      a,0ffh
        scf
        ret
.a_rename_check_io:
        ld      a,0ffh
        scf
        ret

a_rename_apply:
        xor     a
        ld      (a_dir_sector),a
.a_rename_apply_sector:
        ld      a,(a_dir_sector)
        ld      c,a
        ld      a,(disk_dir_sectors)
        cp      c
        jr      z,.a_rename_apply_done
        call    a_directory_sector_address
        call    read_logical_sector
        jr      c,.a_rename_apply_io
        xor     a
        ld      (a_sector_changed),a
        ld      ix,sector_buffer
        ld      b,16
.a_rename_apply_entry:
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        cp      (ix+0)
        jr      nz,.a_rename_apply_advance
        push    bc
        call    a_entry_name_exact
        pop     bc
        jr      nz,.a_rename_apply_advance
        push    ix
        pop     hl
        inc     hl
        ld      de,a_new_name
        push    bc
        ld      b,11
.a_rename_name_byte:
        ld      a,(hl)
        and     080h
        ld      c,a
        ld      a,(de)
        or      c
        ld      (hl),a
        inc     hl
        inc     de
        djnz    .a_rename_name_byte
        pop     bc
        ld      a,1
        ld      (a_sector_changed),a
.a_rename_apply_advance:
        ld      de,32
        add     ix,de
        djnz    .a_rename_apply_entry
        ld      a,(a_sector_changed)
        or      a
        jr      z,.a_rename_apply_next
        call    a_write_current_directory
        jr      c,.a_rename_apply_io
.a_rename_apply_next:
        ld      a,(a_dir_sector)
        inc     a
        ld      (a_dir_sector),a
        jr      .a_rename_apply_sector
.a_rename_apply_done:
        xor     a
        ld      (cached_entry_valid),a
        ret
.a_rename_apply_io:
        ld      a,0ffh
        scf
        ret

a_rename:
        call    a_prepare
        ret     c
        call    a_name_is_exact
        jp      c,native_directory_error_9
        call    a_copy_new_name
        call    a_new_name_is_exact
        jp      c,native_directory_error_9
        call    a_new_file_exists
        jp      nc,native_directory_error_8
        or      a
        jr      nz,.a_rename_bad
        call    a_rename_preflight
        ret     c
        jp      a_rename_apply
.a_rename_bad:
        ld      a,0ffh
        scf
        ret

a_copy_attribute_request:
        ld      hl,(m_fcb)
        inc     hl
        ld      de,a_attribute_bytes
        ld      b,11
.a_copy_attribute_byte:
        call    gencom_tpa_read
        ld      (de),a
        inc     hl
        inc     de
        djnz    .a_copy_attribute_byte
        ld      hl,(m_fcb)
        ld      de,32
        add     hl,de
        call    gencom_tpa_read
        ld      (a_byte_count),a
        ret

a_apply_attributes_to_entry:
        push    ix
        pop     de
        inc     de
        ld      hl,a_attribute_bytes
        ld      b,11
        ld      c,0
.a_attribute_byte:
        ld      a,c
        cp      4
        jr      c,.a_attribute_update
        cp      8
        jr      c,.a_attribute_next
.a_attribute_update:
        ld      a,(de)
        and     07fh
        ld      (a_attribute_lower),a
        ld      a,(hl)
        and     080h
        push    hl
        ld      hl,a_attribute_lower
        or      (hl)
        pop     hl
        ld      (de),a
.a_attribute_next:
        inc     hl
        inc     de
        inc     c
        djnz    .a_attribute_byte
        ld      a,(a_attribute_bytes+5)
        and     080h
        ret     z
        ld      a,(a_byte_count)
        ld      (ix+13),a
        ret

a_set_attributes:
        call    a_prepare
        ret     c
        call    a_name_is_exact
        jr      c,.a_set_attributes_bad
        call    a_copy_attribute_request
        xor     a
        ld      (a_found),a
        ld      (a_dir_sector),a
.a_attributes_sector:
        ld      a,(a_dir_sector)
        ld      c,a
        ld      a,(disk_dir_sectors)
        cp      c
        jr      z,.a_attributes_done
        call    a_directory_sector_address
        call    read_logical_sector
        jr      c,.a_set_attributes_bad
        xor     a
        ld      (a_sector_changed),a
        ld      ix,sector_buffer
        ld      b,16
.a_attributes_entry:
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        cp      (ix+0)
        jr      nz,.a_attributes_advance
        push    bc
        call    a_entry_name_exact
        pop     bc
        jr      nz,.a_attributes_advance
        push    bc
        call    a_apply_attributes_to_entry
        pop     bc
        ld      a,1
        ld      (a_found),a
        ld      (a_sector_changed),a
.a_attributes_advance:
        ld      de,32
        add     ix,de
        djnz    .a_attributes_entry
        ld      a,(a_sector_changed)
        or      a
        jr      z,.a_attributes_next
        call    a_write_current_directory
        jr      c,.a_set_attributes_bad
.a_attributes_next:
        ld      a,(a_dir_sector)
        inc     a
        ld      (a_dir_sector),a
        jr      .a_attributes_sector
.a_attributes_done:
        ld      a,(a_found)
        or      a
        jr      z,.a_set_attributes_bad
        xor     a
        ld      (cached_entry_valid),a
        ret
.a_set_attributes_bad:
        ld      a,0ffh
        scf
        ret

; BDOS 99 keeps records 0 through the requested random record inclusive and
; releases every later allocation. The target must be below the old EOF and
; itself reside in an allocated region.
a_truncate:
        call    a_prepare
        jp      c,.a_truncate_bad
        call    a_name_is_exact
        jp      c,.a_truncate_bad
        call    m_load_random_record
        call    native_compute_a_size
        or      a
        jp      nz,.a_truncate_bad
        call    m_target_below_native_size
        jp      c,.a_truncate_bad
        call    a_record_geometry
        call    a_find_extent
        jp      c,.a_truncate_bad
        bit     7,(ix+9)
        jp      nz,.a_truncate_bad
        call    a_get_entry_block
        jp      z,.a_truncate_bad

        xor     a
        ld      (a_dir_sector),a
.a_truncate_sector:
        ld      a,(a_dir_sector)
        ld      c,a
        ld      a,(disk_dir_sectors)
        cp      c
        jp      z,.a_truncate_done
        call    a_directory_sector_address
        call    read_logical_sector
        jp      c,.a_truncate_bad
        xor     a
        ld      (a_sector_changed),a
        ld      ix,sector_buffer
        ld      b,16
.a_truncate_entry:
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        cp      (ix+0)
        jr      nz,.a_truncate_advance
        push    bc
        call    a_entry_name_exact
        jr      nz,.a_truncate_entry_done
        call    entry_matches
        jr      c,.a_truncate_entry_done  ; earlier normalized extent
        jr      z,.a_truncate_target
        ld      (ix+0),0e5h               ; later extent
        ld      a,1
        ld      (a_sector_changed),a
        jr      .a_truncate_entry_done
.a_truncate_target:
        ld      a,(a_block_slot)
        inc     a
        ld      c,a
        ld      a,(disk_dsm+1)
        or      a
        ld      b,16
        jr      z,.a_truncate_clear_test
        ld      b,8
.a_truncate_clear_test:
        ld      a,c
        cp      b
        jr      nc,.a_truncate_set_count
        ld      (a_block_slot),a
        ld      hl,0
        ld      (a_block),hl
        call    a_set_entry_block
        inc     c
        jr      .a_truncate_clear_test
.a_truncate_set_count:
        ld      hl,(m_record)
        ld      a,(m_record+2)
        ld      b,7
.a_truncate_extent_shift:
        srl     a
        rr      h
        rr      l
        djnz    .a_truncate_extent_shift
        ld      a,l
        and     01fh
        ld      (ix+12),a
        ld      b,5
.a_truncate_s2_shift:
        srl     h
        rr      l
        djnz    .a_truncate_s2_shift
        ld      a,l
        and     03fh
        ld      (ix+14),a
        ld      a,(m_record)
        and     07fh
        inc     a
        ld      (ix+15),a
        ld      a,1
        ld      (a_sector_changed),a
.a_truncate_entry_done:
        pop     bc
.a_truncate_advance:
        ld      de,32
        add     ix,de
        djnz    .a_truncate_entry
        ld      a,(a_sector_changed)
        or      a
        jr      z,.a_truncate_next_sector
        call    a_write_current_directory
        jp      c,.a_truncate_bad
.a_truncate_next_sector:
        ld      a,(a_dir_sector)
        inc     a
        ld      (a_dir_sector),a
        jp      .a_truncate_sector
.a_truncate_done:
        xor     a
        ld      (cached_entry_valid),a
        ret
.a_truncate_bad:
        ld      a,0ffh
        ret

; Carry means target >= current size; carry clear means a legal truncation.
m_target_below_native_size:
        ld      a,(m_record+2)
        ld      c,a
        ld      a,(native_size+2)
        cp      c
        jr      c,.target_not_below
        jr      nz,.target_below
        ld      a,(m_record+1)
        ld      c,a
        ld      a,(native_size+1)
        cp      c
        jr      c,.target_not_below
        jr      nz,.target_below
        ld      a,(m_record)
        ld      c,a
        ld      a,(native_size)
        cp      c
        jr      c,.target_not_below
        jr      z,.target_not_below
.target_below:
        or      a
        ret
.target_not_below:
        scf
        ret

; Search the 128 exact-name directory slots in private block-three metadata.
m_find:
        ld      a,SPARSE_METADATA_PAGE
        out     (0f1h),a
        ld      hl,SPARSE_DIRECTORY_BASE
        ld      c,0
.m_find_next:
        ld      a,(m_match_user)
        cp      (hl)
        jr      nz,.m_find_advance
        push    hl
        inc     hl
        ld      de,m_name
        ld      b,11
.m_find_compare:
        ld      a,(de)
        cp      '?'
        jr      nz,.m_find_compare_byte
        ld      a,(m_function)
        cp      19
        jr      z,.m_find_match_byte
        ld      a,'?'
.m_find_compare_byte:
        cp      (hl)
        jr      nz,.m_find_bad
.m_find_match_byte:
        inc     de
        inc     hl
        djnz    .m_find_compare
        ; The XFCB-only Function 19 loop marks processed records by clearing
        ; private byte 15. Skip those records without hiding their files.
        ld      a,(a_found)
        add     a,a
        jr      nc,.m_find_store
        inc     hl
        inc     hl
        inc     hl
        ld      a,(hl)
        or      a
        jr      z,.m_find_bad
.m_find_store:
        pop     hl
        ld      a,c
        ld      (m_slot),a
        or      a
        ret
.m_find_bad:
        pop     hl
.m_find_advance:
        ld      de,16
        add     hl,de
        inc     c
        ld      a,c
        cp      128
        jr      c,.m_find_next
        scf
        ret

m_find_free:
        ld      a,SPARSE_METADATA_PAGE
        out     (0f1h),a
        ld      hl,SPARSE_DIRECTORY_BASE
        ld      de,16
        ld      c,0
.m_find_free_next:
        ld      a,(hl)
        or      a
        jr      z,.m_find_free_good
        add     hl,de
        inc     c
        ld      a,c
        cp      128
        jr      c,.m_find_free_next
        scf
        ret
.m_find_free_good:
        ld      a,c
        ld      (m_slot),a
        or      a
        ret

m_open:
        jp      native_open_m_bridge

m_create:
        call    a_name_is_exact
        jp      c,native_directory_error_9
        call    m_find
        jp      nc,native_directory_error_8
        call    m_create_entry
        jr      c,.m_create_bad
        call    m_reset_fcb
        xor     a
        ret
.m_create_bad:
        ld      a,0ffh
        ret

; Allocate the current exact-case name without changing the caller's FCB.
; Protected loaders legitimately manufacture a second, lower-case RAM file
; through random writes after creating an upper-case bootstrap file.
m_create_entry:
        call    m_find_free
        ret     c
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        inc     a
        ld      (hl),a
        inc     hl
        ld      de,m_name
        ld      b,11
.m_create_name:
        ld      a,(de)
        ld      (hl),a
        inc     de
        inc     hl
        djnz    .m_create_name
        xor     a
        ld      b,4
.m_create_clear_metadata:
        ld      (hl),a
        inc     hl
        djnz    .m_create_clear_metadata
        or      a
        ret

m_delete:
        ; Function 19 accepts an ambiguous FCB. The shared read-only/password
        ; preflights run before this routine, so removing every match cannot
        ; leave a partially deleted set after a protection error.
        xor     a
        ld      (a_found),a
m_delete_next:
        call    m_find
        jr      c,.m_delete_done
        ld      a,(a_found)
        or      1
        ld      (a_found),a
        rlca
        jr      nc,.m_delete_file
        ld      de,14
        add     hl,de
        xor     a
        ld      (hl),a
        inc     hl
        ld      (hl),a
        jr      m_delete_next
.m_delete_file:
        xor     a
        ld      (hl),a
        call    m_purge_slot
        jr      m_delete_next
.m_delete_done:
        ld      a,(a_found)
        or      a
        jr      z,.m_delete_bad
        xor     a
        ret
.m_delete_bad:
        ld      a,0ffh
        ret

; Rename keeps the private file slot, so every sparse record stays attached.
m_rename:
        call    a_name_is_exact
        jp      c,native_directory_error_9
        call    m_find
        jr      c,.m_rename_bad
        push    hl
        pop     ix
        bit     4,(ix+12)
        jr      nz,.m_rename_bad
        call    a_copy_new_name
        call    a_new_name_is_exact
        jp      c,native_directory_error_9
        ld      a,SPARSE_METADATA_PAGE
        out     (0f1h),a
        ld      hl,SPARSE_DIRECTORY_BASE
        ld      b,128
.m_rename_check_slot:
        ld      a,(hl)
        ld      e,a
        ld      a,(m_match_user)
        cp      e
        jr      nz,.m_rename_check_next
        push    hl
        inc     hl
        ld      de,a_new_name
        ld      c,11
.m_rename_compare:
        ld      a,(de)
        cp      (hl)
        jr      nz,.m_rename_not_equal
        inc     de
        inc     hl
        dec     c
        jr      nz,.m_rename_compare
        pop     hl
        jp      native_directory_error_8
.m_rename_not_equal:
        pop     hl
.m_rename_check_next:
        ld      de,16
        add     hl,de
        djnz    .m_rename_check_slot
        push    ix
        pop     hl
        inc     hl
        ld      de,a_new_name
        ld      b,11
.m_rename_store:
        ld      a,(de)
        ld      (hl),a
        inc     de
        inc     hl
        djnz    .m_rename_store
        xor     a
        ret
.m_rename_bad:
        ld      a,0ffh
        ret

; Pack f1'..f4' and t1'..t3' into private byte 12. f6' is the
; non-persistent interface flag requesting a last-byte-count update.
m_set_attributes:
        call    m_find
        jr      c,.m_set_attributes_bad
        push    hl
        pop     ix
        xor     a
        ld      (m_attribute_mask),a
        ld      hl,(m_fcb)
        inc     hl
        ld      c,1
        ld      b,4
.m_attribute_name:
        call    gencom_tpa_read
        and     080h
        jr      z,.m_attribute_name_next
        ld      a,(m_attribute_mask)
        or      c
        ld      (m_attribute_mask),a
.m_attribute_name_next:
        inc     hl
        sla     c
        djnz    .m_attribute_name
        ld      de,4
        add     hl,de                    ; t1 at FCB+9
        ld      b,3
.m_attribute_type:
        call    gencom_tpa_read
        and     080h
        jr      z,.m_attribute_type_next
        ld      a,(m_attribute_mask)
        or      c
        ld      (m_attribute_mask),a
.m_attribute_type_next:
        inc     hl
        sla     c
        djnz    .m_attribute_type
        ld      a,SPARSE_METADATA_PAGE
        out     (0f1h),a
        ld      a,(m_attribute_mask)
        ld      (ix+12),a
        ld      hl,(m_fcb)
        ld      de,6
        add     hl,de
        call    gencom_tpa_read
        and     080h
        jr      z,.m_set_attributes_done
        ld      hl,(m_fcb)
        ld      de,32
        add     hl,de
        call    gencom_tpa_read
        ld      (a_byte_count),a
        ld      a,SPARSE_METADATA_PAGE
        out     (0f1h),a
        ld      a,(a_byte_count)
        ld      (ix+13),a
.m_set_attributes_done:
        xor     a
        ret
.m_set_attributes_bad:
        ld      a,0ffh
        ret

m_truncate:
        call    m_find
        jr      c,.m_truncate_bad
        push    hl
        pop     ix
        bit     4,(ix+12)
        jr      nz,.m_truncate_bad
        call    m_load_random_record
        call    native_compute_m_size
        or      a
        jr      nz,.m_truncate_bad
        call    m_target_below_native_size
        jr      c,.m_truncate_bad
        ; The exact target record proves that the requested sparse region is
        ; allocated. Files created through Function 40 materialise this byte.
        ld      bc,(m_record)
        ld      a,(m_record+2)
        ld      e,a
        ld      a,(m_slot)
        call    sparse_find
        jr      c,.m_truncate_bad
        call    sparse_truncate_allocations
        xor     a
        ret
.m_truncate_bad:
        ld      a,0ffh
        ret

; Reusing a directory slot must not expose sparse records belonging to its
; previous filename. Mark every map entry for the deleted slot free.
m_purge_slot:
        jp      sparse_purge_allocations

sparse_purge_allocations:
        ld      ix,SPARSE_ALLOCATION_BASE
        ld      a,(native_m_data_blocks)
        ld      b,a
.sparse_purge_allocation_next:
        ld      a,(m_slot)
        cp      (ix+0)
        jr      nz,.sparse_purge_allocation_keep
        ld      (ix+0),0feh
.sparse_purge_allocation_keep:
        ld      de,4
        add     ix,de
        djnz    .sparse_purge_allocation_next
        ret

sparse_truncate_allocations:
        call    sparse_make_block_key
        ld      a,SPARSE_METADATA_PAGE
        out     (0f1h),a
        ld      ix,SPARSE_ALLOCATION_BASE
        ld      a,(native_m_data_blocks)
        ld      b,a
.sparse_truncate_allocation_next:
        ld      a,(m_slot)
        cp      (ix+0)
        jr      nz,.sparse_truncate_allocation_keep
        ld      a,(sparse_block_key+2)
        cp      (ix+3)
        jr      c,.sparse_truncate_allocation_remove
        jr      nz,.sparse_truncate_allocation_keep
        ld      a,(sparse_block_key+1)
        cp      (ix+2)
        jr      c,.sparse_truncate_allocation_remove
        jr      nz,.sparse_truncate_allocation_keep
        ld      a,(sparse_block_key)
        cp      (ix+1)
        jr      nc,.sparse_truncate_allocation_keep
.sparse_truncate_allocation_remove:
        ld      (ix+0),0feh
.sparse_truncate_allocation_keep:
        ld      de,4
        add     ix,de
        djnz    .sparse_truncate_allocation_next
        ; Retain target record and every earlier validity bit in its block.
        ld      a,(sparse_record)
        and     00fh
        inc     a
        ld      b,a
        ld      hl,1
.sparse_truncate_mask:
        add     hl,hl
        djnz    .sparse_truncate_mask
        dec     hl
        push    hl
        ld      a,(sparse_allocation_index)
        call    sparse_valid_address
        pop     de
        ld      a,(hl)
        and     e
        ld      (hl),a
        inc     hl
        ld      a,(hl)
        and     d
        ld      (hl),a
        ret

; OPEN/MAKE reset the sequential extent cursor without disturbing the random
; record fields. Allocation bytes are private to the OS and need not describe
; the sparse physical representation.
m_reset_fcb:
        ld      hl,(m_fcb)
        ld      de,12
        add     hl,de
        xor     a
        ld      b,4
.m_reset_extent:
        call    gencom_tpa_write
        inc     hl
        djnz    .m_reset_extent
        ld      hl,(m_fcb)
        ld      de,32
        add     hl,de
        xor     a
        call    gencom_tpa_write
        ret

m_read_sequential:
        call    m_find
        jr      c,.m_read_missing
        call    m_load_sequential_record
        ld      a,1
        ld      (m_is_sequential),a
        jp      m_transfer_read
.m_read_missing:
        ld      a,1
        ret

m_write_sequential:
        call    m_find
        jr      nc,.m_write_sequential_found
        call    m_create_entry
        jr      c,.m_write_missing
.m_write_sequential_found:
        call    m_load_sequential_record
        ld      a,1
        ld      (m_is_sequential),a
        jp      m_transfer_write
.m_write_missing:
        ld      a,1
        ret

m_read_random:
        call    m_find
        jr      c,.m_read_random_missing
        call    m_prepare_random_record
        ret     c
        xor     a
        ld      (m_is_sequential),a
        jp      m_transfer_read
.m_read_random_missing:
        ld      a,1
        ret

m_write_random:
        call    m_find
        jr      nc,.m_write_random_found
        call    m_create_entry
        jr      c,.m_write_random_missing
.m_write_random_found:
        call    m_prepare_random_record
        ret     c
        xor     a
        ld      (m_is_sequential),a
        jp      m_transfer_write
.m_write_random_missing:
        ld      a,1
        ret

; Function 40 zero-initialises a newly allocated 2 KiB M: data block before
; installing the requested random record. Materialise only through the new
; logical EOF; later records remain inaccessible until the file grows.
m_write_random_zero:
        call    m_find
        jr      nc,.m_write_random_zero_found
        call    m_create_entry
        jr      c,.m_write_random_missing
.m_write_random_zero_found:
        call    m_prepare_random_record
        ret     c
        call    m_zero_new_block
        or      a
        ret     nz
        xor     a
        ld      (m_is_sequential),a
        jp      m_transfer_write

m_zero_new_block:
        ; Any existing allocation for this logical 2 KiB block means Function
        ; 40 degenerates to an ordinary write. A new block is materialised as
        ; zero records only through the requested logical EOF.
        call    sparse_ensure_allocation
        or      a
        ret     nz
        ld      a,(sparse_allocation_new)
        or      a
        jp      z,.m_zero_already_allocated

        ; Preserve the caller's DMA while using it as a portable source of
        ; zero bytes for the existing sparse-record writer.
        ld      hl,(m_dma)
        ld      de,m_saved_dma
        ld      b,128
.m_zero_save_dma:
        call    gencom_tpa_read
        ld      (de),a
        inc     hl
        inc     de
        djnz    .m_zero_save_dma
        ld      hl,(m_dma)
        ld      b,128
        xor     a
.m_zero_clear_dma:
        call    gencom_tpa_write
        inc     hl
        djnz    .m_zero_clear_dma
        ld      a,(m_record)
        and     0f0h
        ld      (m_zero_record),a
        ld      a,(m_record+1)
        ld      (m_zero_record+1),a
        ld      a,(m_record+2)
        ld      (m_zero_record+2),a
        ld      a,(m_record)
        and     00fh
        inc     a
        ld      (m_zero_left),a
        xor     a
        ld      (m_zero_status),a
.m_zero_write_record:
        ld      bc,(m_zero_record)
        ld      a,(m_zero_record+2)
        ld      e,a
        ld      hl,(m_dma)
        ld      a,(m_slot)
        call    native_sparse_write
        or      a
        jr      z,.m_zero_write_next
        ld      (m_zero_status),a
        jr      .m_zero_restore_dma
.m_zero_write_next:
        ld      hl,(m_zero_record)
        inc     hl
        ld      (m_zero_record),hl
        ld      a,h
        or      l
        jr      nz,.m_zero_no_carry
        ld      a,(m_zero_record+2)
        inc     a
        ld      (m_zero_record+2),a
.m_zero_no_carry:
        ld      a,(m_zero_left)
        dec     a
        ld      (m_zero_left),a
        jr      nz,.m_zero_write_record
.m_zero_restore_dma:
        ld      hl,(m_dma)
        ld      de,m_saved_dma
        ld      b,128
.m_zero_restore_byte:
        ld      a,(de)
        call    gencom_tpa_write
        inc     hl
        inc     de
        djnz    .m_zero_restore_byte
        ld      a,(m_zero_status)
        ret
.m_zero_already_allocated:
        xor     a
        ret

; Translate CP/M's EX/S2/CR sequential cursor into one absolute 24-bit record:
; CR + 128*EX + 4096*S2. Only the documented low five/six extent bits count.
m_load_sequential_record:
        ld      hl,(m_fcb)
        ld      de,32
        add     hl,de
        call    gencom_tpa_read
        ld      (m_cr),a
        ld      hl,(m_fcb)
        ld      de,12
        add     hl,de
        call    gencom_tpa_read
        and     01fh
        ld      (m_ex),a
        ld      hl,(m_fcb)
        ld      de,14
        add     hl,de
        call    gencom_tpa_read
        and     03fh
        ld      (m_s2),a

        ; CR=80h is CP/M Plus's deferred extent boundary. Interpret it as
        ; record zero of the following extent without changing the public FCB;
        ; only a successful transfer commits the EX/S2 transition.
        call    m_normalize_deferred_cursor

        ld      a,(m_ex)
        and     1
        rrca
        ld      b,a
        ld      a,(m_cr)
        or      b
        ld      (m_record),a
        ld      a,(m_ex)
        and     01eh
        rrca
        ld      b,a
        ld      a,(m_s2)
        and     0fh
        rlca
        rlca
        rlca
        rlca
        or      b
        ld      (m_record+1),a
        ld      a,(m_s2)
        and     030h
        rrca
        rrca
        rrca
        rrca
        ld      (m_record+2),a
        ret

m_load_random_record:
        ld      hl,(m_fcb)
        ld      de,33
        add     hl,de
        ld      de,m_record
        ld      b,3
.m_load_random_byte:
        call    gencom_tpa_read
        ld      (de),a
        inc     hl
        inc     de
        djnz    .m_load_random_byte
        ret

m_prepare_random_record:
        call    m_load_random_record
        ld      a,(m_record+2)
        cp      4
        jp      nc,.a_write_random_range
        call    m_write_random_cr
        ret

m_transfer_read:
m_transfer_write:
.m_transfer_next:
        ld      bc,(m_record)
        ld      a,(m_record+2)
        ld      e,a
        ld      hl,(m_dma)
        ld      a,(m_slot)
        push    af
        ld      a,(m_function)
        cp      20
        jr      z,.m_transfer_do_read
        cp      33
        jr      nz,.m_transfer_do_write
.m_transfer_do_read:
        pop     af
        call    native_sparse_read
        jr      .m_transfer_result
.m_transfer_do_write:
        pop     af
        call    native_sparse_write
.m_transfer_result:
        or      a
        jp      nz,native_m_read_failure
        ld      a,(m_is_sequential)
        or      a
        call    z,a_write_fcb_position
        call    m_transfer_advance
        ld      a,(m_left)
        dec     a
        ld      (m_left),a
        jr      nz,.m_transfer_next
        xor     a
        ret

m_transfer_advance:
        ld      a,(m_is_sequential)
        dec     a
        call    z,m_advance_sequential_fcb
        ld      hl,(m_record)
        inc     hl
        ld      (m_record),hl
        ; INC HL does not update Z on the Z80.  Derive the 16-bit carry
        ; condition explicitly; otherwise a random transfer inherits Z=1
        ; from m_is_sequential and incorrectly advances the high byte after
        ; every record rather than only after FFFFh -> 0000h.
        ld      a,h
        or      l
        jr      nz,.m_record_advanced
        ld      a,(m_record+2)
        inc     a
        ld      (m_record+2),a
.m_record_advanced:
        ld      hl,(m_dma)
        ld      de,128
        add     hl,de
        ld      (m_dma),hl
        ret

m_advance_sequential_fcb:
        ld      hl,m_advance_sequential_fcb_overlay
        jp      native_cursor_overlay_call

; BDOS 59 first loads ordinary sparse RAM files in allocation order. If the
; RAM file starts at a very high record and an exact-case A: file starts at a
; nonzero extent, it represents the standard sparse-overlay construction used
; by PCW resident loaders: seed one RAM block, replace its first record with
; the sparse marker, then append the physical overlay after the remaining
; records of that 2 KiB RAM block.
m_load_overlay:
        ld      hl,m_load_overlay_entry
        jp      native_cursor_overlay_call

native_prune_rsx_call:
        ld      hl,native_prune_rsx_overlay
        jp      native_cursor_overlay_call

; Load an already opened absolute overlay from physical A:. The directory
; walk deliberately begins at the file's lowest real extent, matching the
; public LOADER behaviour for protected/sparse overlay files. PRL relocation
; is handled separately below; this path is the absolute-file contract.
a_load_overlay:
        call    disk_login
        jr      c,.a_overlay_bad
        call    overlay_scan_directory
        jr      c,.a_overlay_bad
        call    m_overlay_read_address
        ld      hl,(m_overlay_load)
        ld      a,h
        or      a
        jr      z,.a_overlay_address_bad
        ld      de,(gencom_rsx_low)
        ld      a,d
        or      e
        jr      z,.a_overlay_address_bad
        push    hl
        or      a
        sbc     hl,de
        pop     hl
        jr      nc,.a_overlay_address_bad
        ld      (load_address),hl
        xor     a
        ld      (overlay_skip_records),a
        call    overlay_load_physical_extents
        jr      c,.a_overlay_bad
        call    a_overlay_relocate_prl
        ret
.a_overlay_address_bad:
        ld      a,0feh
        ret
.a_overlay_bad:
        ld      a,1
        ret

; Absolute overlays are already complete after the physical extent walk. A
; PRL carries a 256-byte header, relocatable bytes, an MSB-first bitmap and a
; requested zero-filled work area. Relocate it in place according to the
; published CP/M Plus file contract in REF-CPM3-PG.
a_overlay_relocate_prl:
        ld      a,(wanted_name+8)
        cp      'P'
        jp      nz,.prl_not_required
        ld      a,(wanted_name+9)
        cp      'R'
        jp      nz,.prl_not_required
        ld      a,(wanted_name+10)
        cp      'L'
        jp      nz,.prl_not_required

        ld      hl,(m_overlay_load)
        ld      a,l
        or      a
        jp      nz,.prl_invalid
        inc     hl
        call    gencom_read_word          ; DE=program size
        ld      a,d
        or      e
        jp      z,.prl_invalid
        ld      (gencom_remaining),de
        ld      hl,(m_overlay_load)
        ld      de,4
        add     hl,de
        call    gencom_read_word          ; DE=zero-fill buffer size
        ld      (gencom_bitmap_size),de

        ld      hl,(m_overlay_load)
        inc     h                         ; raw PRL program follows 256 bytes
        ld      (gencom_source),hl
        ld      de,(gencom_remaining)
        add     hl,de
        jp      c,.prl_invalid
        ld      (gencom_bitmap),hl
        ld      hl,(gencom_remaining)
        ld      de,7
        add     hl,de
        jp      c,.prl_invalid
        srl     h
        rr      l
        srl     h
        rr      l
        srl     h
        rr      l
        ex      de,hl                     ; DE=relocation bitmap bytes
        ld      hl,(gencom_bitmap)
        add     hl,de
        jp      c,.prl_invalid
        ld      de,(load_address)         ; end of raw records loaded from A:
        or      a
        sbc     hl,de
        jr      c,.prl_raw_fits
        jp      nz,.prl_invalid
.prl_raw_fits:
        ld      hl,(m_overlay_load)
        ld      de,(gencom_remaining)
        add     hl,de
        jp      c,.prl_invalid
        ld      de,(gencom_bitmap_size)
        add     hl,de
        jp      c,.prl_invalid
        ld      de,(gencom_rsx_low)
        or      a
        sbc     hl,de
        jr      c,.prl_destination_fits
        jp      nz,.prl_invalid
.prl_destination_fits:
        ld      hl,(m_overlay_load)
        ld      (gencom_destination),hl
        ld      a,h
        dec     a                         ; PRLs are assembled at page 1
        ld      (gencom_reloc_delta),a
        xor     a
        ld      (gencom_reloc_mask),a
        call    gencom_relocate_bytes

        ld      de,(gencom_bitmap_size)
.prl_zero_buffer:
        ld      a,d
        or      e
        jr      z,.prl_not_required
        ld      hl,(gencom_destination)
        xor     a
        call    gencom_tpa_write
        inc     hl
        ld      (gencom_destination),hl
        dec     de
        jr      .prl_zero_buffer
.prl_not_required:
        xor     a
        ret
.prl_invalid:
        ld      a,0feh
        ret

m_overlay_read_address:
        ld      hl,(m_fcb)
        ld      de,33
        add     hl,de
        call    gencom_tpa_read
        ld      e,a
        inc     hl
        call    gencom_tpa_read
        ld      d,a
        ld      (m_overlay_load),de
        ret

; Return the lexicographically lowest 24-bit sparse record for the selected
; exact-case file. The map entry itself is independent of write order.
m_find_lowest_record:
        ld      a,0ffh
        ld      (m_lowest),a
        ld      (m_lowest+1),a
        ld      (m_lowest+2),a
        xor     a
        ld      (m_overlay_found),a
        ld      a,SPARSE_METADATA_PAGE
        out     (0f1h),a
        ld      ix,SPARSE_ALLOCATION_BASE
        ld      a,(native_m_data_blocks)
        ld      b,a
        ld      c,0
.m_lowest_next:
        ld      a,(m_slot)
        cp      (ix+0)
        jr      nz,.m_lowest_advance
        push    bc
        ld      a,c
        call    sparse_lowest_valid_record
        jr      c,.m_lowest_restore
        ld      c,a
        ld      l,(ix+1)
        ld      h,(ix+2)
        ld      a,(ix+3)
        ld      b,4
.m_lowest_key_shift:
        add     hl,hl
        rla
        djnz    .m_lowest_key_shift
        ld      e,c
        ld      d,0
        add     hl,de
        jr      nc,.m_lowest_candidate_ready
        inc     a
.m_lowest_candidate_ready:
        ld      (native_size_candidate),hl
        ld      (native_size_candidate+2),a
        ld      b,a
        ld      a,(m_lowest+2)
        cp      b
        jr      c,.m_lowest_restore
        jr      nz,.m_lowest_store
        ld      a,(native_size_candidate+1)
        ld      b,a
        ld      a,(m_lowest+1)
        cp      b
        jr      c,.m_lowest_restore
        jr      nz,.m_lowest_store
        ld      a,(native_size_candidate)
        ld      b,a
        ld      a,(m_lowest)
        cp      b
        jr      c,.m_lowest_restore
.m_lowest_store:
        ld      a,(native_size_candidate)
        ld      (m_lowest),a
        ld      a,(native_size_candidate+1)
        ld      (m_lowest+1),a
        ld      a,(native_size_candidate+2)
        ld      (m_lowest+2),a
        ld      a,1
        ld      (m_overlay_found),a
.m_lowest_restore:
        pop     bc
.m_lowest_advance:
        ld      de,4
        add     ix,de
        inc     c
        djnz    .m_lowest_next
        ld      a,(m_overlay_found)
        or      a
        jr      z,.m_lowest_missing
        or      a
        ret
.m_lowest_missing:
        scf
        ret

; A=allocation index. Return the lowest valid record bit or carry if empty.
sparse_lowest_valid_record:
        ld      c,a
        ld      hl,sparse_lowest_valid_record_overlay
        jp      native_cursor_overlay_call

; Pack every allocated sparse record for this file into the requested load
; address. This is the ordinary overlay behaviour for the upper-case bootstrap
; file and for simple RAM-resident overlays.
m_overlay_generic:
        ld      hl,0
        ld      (m_scan_index),hl
        ld      a,(native_m_data_blocks)
        ld      l,a
        ld      h,0
        ld      (m_scan_left),hl
        xor     a
        ld      (m_overlay_found),a
.m_overlay_generic_next:
        ld      a,SPARSE_METADATA_PAGE
        out     (0f1h),a
        ld      hl,(m_scan_index)
        add     hl,hl
        add     hl,hl
        ld      de,SPARSE_ALLOCATION_BASE
        add     hl,de
        push    hl
        pop     ix
        ld      a,(m_slot)
        cp      (ix+0)
        jr      nz,.m_overlay_generic_advance
        ld      a,(m_scan_index)
        call    sparse_valid_address
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      (sparse_valid_word),de
        xor     a
        ld      (sparse_record_within),a
.m_overlay_record_next:
        ld      hl,(sparse_valid_word)
        bit     0,l
        jr      z,.m_overlay_record_advance
        ld      hl,(m_scan_index)
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      a,(sparse_record_within)
        ld      e,a
        ld      d,0
        add     hl,de
        call    sparse_map_data
        ld      de,sparse_io_buffer
        ld      bc,128
        ldir
        ld      hl,(m_overlay_load)
        ld      de,sparse_io_buffer
        ld      b,128
.m_overlay_generic_copy:
        ld      a,(de)
        call    gencom_tpa_write
        inc     hl
        inc     de
        djnz    .m_overlay_generic_copy
        ld      (m_overlay_load),hl
        ld      a,1
        ld      (m_overlay_found),a
.m_overlay_record_advance:
        ld      hl,(sparse_valid_word)
        srl     h
        rr      l
        ld      (sparse_valid_word),hl
        ld      a,(sparse_record_within)
        inc     a
        ld      (sparse_record_within),a
        cp      16
        jr      c,.m_overlay_record_next
.m_overlay_generic_advance:
        ld      hl,(m_scan_index)
        inc     hl
        ld      (m_scan_index),hl
        ld      hl,(m_scan_left)
        dec     hl
        ld      (m_scan_left),hl
        ld      a,h
        or      l
        jp      nz,.m_overlay_generic_next
        ld      a,(m_overlay_found)
        or      a
        jr      z,.m_overlay_generic_bad
        xor     a
        ret
.m_overlay_generic_bad:
        ld      a,1
        ret

m_overlay_sparse_bridge:
        ld      hl,m_name
        ld      de,wanted_name
        ld      bc,11
        ldir
        call    disk_login
        ret     c
        call    overlay_scan_directory
        ret     c
        ld      hl,(overlay_min_extent)
        ld      a,h
        or      l
        scf
        ret     z
        call    overlay_find_free_block
        ret     c

        ld      hl,(m_overlay_load)
        ld      (load_address),hl
        call    overlay_copy_free_block
        ret     c
        ld      a,(m_slot)
        ld      bc,(m_lowest)
        ld      a,(m_lowest+2)
        ld      e,a
        ld      hl,(m_overlay_load)
        ld      a,(m_slot)
        call    native_sparse_read
        or      a
        scf
        ret     nz

        ld      a,15              ; remaining records in the first 2 KiB block
        ld      (overlay_skip_records),a
        ; Fall through: the sparse bridge now needs the common extent walk.

; Load all real extents of the selected physical A: file in ascending logical
; order. Both direct A: overlays and sparse M:+A: loader bridges use exactly
; the same extent contract; overlay_skip_records selects their only difference.
; Carry means that no physical extent could be loaded.
overlay_load_physical_extents:
        ld      hl,(overlay_min_extent)
        ld      (wanted_extent),hl
        xor     a
        ld      (overlay_loaded_any),a
        ld      a,3
        ld      (record_mode),a
.overlay_extent:
        call    load_extent
        jr      c,.overlay_extent_done
        ld      a,1
        ld      (overlay_loaded_any),a
        ld      hl,(wanted_extent)
        inc     hl
        ld      (wanted_extent),hl
        jr      .overlay_extent
.overlay_extent_done:
        xor     a
        ld      (record_mode),a
        ld      a,(overlay_loaded_any)
        or      a
        scf
        ret     z
        xor     a
        ret

; Scan the physical directory once. At the same time collect the exact-case
; file's lowest logical extent and a bitmap of every allocated disk block.
overlay_scan_directory:
        xor     a
        ld      hl,overlay_used_blocks
        ld      de,overlay_used_blocks+1
        ld      (hl),a
        ld      bc,255
        ldir
        ld      hl,0ffffh
        ld      (overlay_min_extent),hl
        xor     a
        ld      (directory_sector),a
.overlay_directory_sector:
        ld      a,(directory_sector)
        ld      c,a
        ld      a,(disk_dir_sectors)
        cp      c
        jr      z,.overlay_directory_done
        ld      l,c
        ld      h,0
        ld      de,(disk_data_start)
        add     hl,de
        call    read_logical_sector
        ret     c
        ld      ix,sector_buffer
        ld      b,16
.overlay_directory_entry:
        ld      a,(ix+0)
        cp      16
        jr      nc,.overlay_directory_advance
        push    bc
        call    overlay_mark_entry_blocks
        ld      a,(ix+0)
        or      a
        jr      nz,.overlay_directory_entry_done
        call    overlay_entry_name_matches
        jr      nz,.overlay_directory_entry_done
        call    overlay_consider_extent
.overlay_directory_entry_done:
        pop     bc
.overlay_directory_advance:
        ld      de,32
        add     ix,de
        djnz    .overlay_directory_entry
        ld      a,(directory_sector)
        inc     a
        ld      (directory_sector),a
        jr      .overlay_directory_sector
.overlay_directory_done:
        ld      hl,(overlay_min_extent)
        ld      a,h
        and     l
        inc     a
        jr      z,.overlay_directory_missing
        or      a
        ret
.overlay_directory_missing:
        scf
        ret

overlay_entry_name_matches:
        push    ix
        pop     de
        inc     de
        ld      hl,wanted_name
        ld      b,11
.overlay_name_byte:
        ld      a,(de)
        and     07fh
        cp      (hl)
        ret     nz
        inc     de
        inc     hl
        djnz    .overlay_name_byte
        ret

overlay_consider_extent:
        ld      a,(ix+14)
        and     03fh
        ld      l,a
        ld      h,0
        ld      b,5
.overlay_s2_shift:
        add     hl,hl
        djnz    .overlay_s2_shift
        ld      a,(ix+12)
        and     01fh
        or      l
        ld      l,a
        ld      a,(disk_extent_shift)
        ld      b,a
        or      a
        jr      z,.overlay_extent_ready
.overlay_extent_shift:
        srl     h
        rr      l
        djnz    .overlay_extent_shift
.overlay_extent_ready:
        ld      de,(overlay_min_extent)
        push    hl
        or      a
        sbc     hl,de
        pop     hl
        ret     nc
        ld      (overlay_min_extent),hl
        ret

overlay_mark_entry_blocks:
        push    ix
        pop     hl
        ld      de,16
        add     hl,de
        ld      a,(disk_dsm+1)
        or      a
        jr      nz,.overlay_mark_words
        ld      b,16
.overlay_mark_bytes:
        ld      e,(hl)
        ld      d,0
        push    hl
        push    bc
        call    overlay_mark_block
        pop     bc
        pop     hl
        inc     hl
        djnz    .overlay_mark_bytes
        ret
.overlay_mark_words:
        ld      b,8
.overlay_mark_word:
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        push    hl
        push    bc
        call    overlay_mark_block
        pop     bc
        pop     hl
        djnz    .overlay_mark_word
        ret

overlay_mark_block:
        ld      a,d
        or      e
        ret     z
        push    de
        ld      hl,(disk_dsm)
        or      a
        sbc     hl,de
        pop     de
        ret     c
        push    de
        srl     d
        rr      e
        srl     d
        rr      e
        srl     d
        rr      e
        ld      hl,overlay_used_blocks
        add     hl,de
        pop     de
        ld      a,e
        and     7
        push    hl
        ld      l,a
        ld      h,0
        ld      a,OPENPCW_RUNTIME_PAGE
        out     (0f1h),a
        ld      de,overlay_bit_masks
        add     hl,de
        ld      a,(hl)
        pop     hl
        or      (hl)
        ld      (hl),a
        ret

overlay_find_free_block:
        ld      a,(disk_dir_blocks)
        ld      e,a
        ld      d,0
.overlay_free_candidate:
        push    de
        ld      hl,(disk_dsm)
        or      a
        sbc     hl,de
        pop     de
        jr      c,.overlay_no_free_block
        push    de
        call    overlay_block_used
        pop     de
        jr      z,.overlay_free_found
        inc     de
        jr      .overlay_free_candidate
.overlay_free_found:
        ld      (overlay_free_block),de
        or      a
        ret
.overlay_no_free_block:
        scf
        ret

overlay_block_used:
        push    de
        srl     d
        rr      e
        srl     d
        rr      e
        srl     d
        rr      e
        ld      hl,overlay_used_blocks
        add     hl,de
        pop     de
        ld      a,e
        and     7
        push    hl
        ld      l,a
        ld      h,0
        ld      de,overlay_bit_masks
        add     hl,de
        ld      a,(hl)
        pop     hl
        and     (hl)
        ret

overlay_copy_free_block:
        ld      hl,(overlay_free_block)
        ld      a,(disk_block_shift)
        sub     2
        ld      b,a
        jr      z,.overlay_free_scaled
.overlay_free_scale:
        add     hl,hl
        djnz    .overlay_free_scale
.overlay_free_scaled:
        ld      de,(disk_data_start)
        add     hl,de
        ld      (block_sector),hl
        ld      a,(disk_block_sectors)
        ld      (sectors_in_block),a
.overlay_free_sector:
        ld      a,(sectors_in_block)
        or      a
        ret     z
        dec     a
        ld      (sectors_in_block),a
        ld      hl,(block_sector)
        inc     hl
        ld      (block_sector),hl
        dec     hl
        call    read_logical_sector
        ret     c
        ld      hl,sector_buffer
        ld      (copy_source),hl
        ld      bc,512
        call    copy_to_tpa
        ret     c
        jr      .overlay_free_sector

m_function:              db 0
m_fcb:                   dw 0
m_dma:                   dw 0
m_count:                 db 1
native_physical_error_code: db 0
native_block_address:    dw 0
native_block_count:      dw 0
native_size:             db 0,0,0
native_size_candidate:   db 0,0,0
native_size_found:       db 0
native_size_user:        db 0
native_default_password: defs 8,0
native_parse_input:       dw 0
native_parse_fcb:         dw 0
native_parse_separator:   dw 0
native_parse_output:      dw 0
native_parse_left:        db 0
native_parse_capacity:    db 0
native_parse_used:        db 0
native_parse_wildcard:    db 0
native_parse_character:   db 0
native_search_cursor:     dw 0
native_search_pattern:    defs 12,0
native_search_drive:      db 0
native_search_raw:        db 0
native_search_user:       db 0
native_search_valid:      db 0
native_search_entry:      db 0
m_left:                  db 0
m_slot:                  db 0
m_match_user:            db 1
m_is_sequential:         db 0
m_cr:                    db 0
m_ex:                    db 0
m_s2:                    db 0
m_record:                db 0,0,0
m_name:                  defs 11,' '
m_label_data:            db 0
a_extent:                dw 0
a_record_within:         dw 0
a_block:                 dw 0
a_data_sector:           dw 0
a_dir_sector:            db 0
a_dir_index:             db 0
a_entry_sector:          db 0
a_entry_index:           db 0
a_entry_new:             db 0
a_block_slot:            db 0
a_record_in_block:       db 0
a_sectors_left:          db 0
a_new_block:             db 0
a_zero_fill:             db 0
a_no_directory_code:     db 1
a_found:                 db 0
a_find_user:             db 0
a_sector_changed:        db 0
a_new_name:              defs 11,' '
a_attribute_bytes:       defs 11,0
a_attribute_lower:       db 0
a_byte_count:            db 0
m_lowest:                db 0,0,0
m_overlay_load:           dw 0
m_overlay_found:          db 0
m_scan_index:             dw 0
m_scan_left:              dw 0
m_attribute_mask:         db 0
m_zero_record:            db 0,0,0
m_zero_left:              db 0
m_zero_status:            db 0
m_saved_dma:              defs 128,0
overlay_min_extent:       dw 0
overlay_free_block:       dw 0
overlay_skip_records:     db 0
overlay_loaded_any:       db 0
overlay_records_this:     db 0
overlay_used_blocks:      defs 256,0

; Compatibility entry retained for the private jump table. It enters the same
; A:/M: dispatcher as resident Function 15, with the conventional default DMA
; and a single-record count.
native_open:
        ld      a,15
        ld      hl,0080h
        ld      b,1
        jp      native_m_bdos

; A:HL=absolute 24-bit 128-byte record used by BDOS random-read wrappers.
native_seek_record:
        cp      4
        jp      nc,.a_write_random_range
        ld      (next_record),hl
        ld      (next_record+2),a
        xor     a
        ret

; Read the A: request already captured by native_m_bdos. Return CP/M status
; 0=all requested records read, 1=logical end/error, or FFh=physical error.
native_read:
        xor     a
        ld      (native_physical_error_code),a
        ld      a,(m_left)
        ld      b,a
        ld      a,(m_function)
        cp      33
        jr      nz,.read_sequential_position
        ; The resident bridge leaves B as its remaining multisector count.
        ; Random I/O loads R0..R2 only for the first transfer; later records
        ; in the same BDOS call continue from next_record while the public
        ; random field remains unchanged.
        ld      a,(OPENPCW_COMMON_MULTISECTOR)
        cp      b
        jr      nz,.read_position_ready
.read_random_position:
        call    m_load_random_record
        ld      a,(m_record+2)
        cp      4
        jp      nc,.a_write_random_range
        call    m_write_random_cr
        jr      .read_position_store
.read_sequential_position:
        call    m_load_sequential_record
.read_position_store:
        ld      hl,(m_record)
        ld      (next_record),hl
        ld      a,(m_record+2)
        ld      (next_record+2),a
.read_position_ready:
        ; Keep the low-word cursor on the record about to be read. The high
        ; byte remains the caller's initial 24-bit range marker throughout a
        ; CP/M multisector operation; its completion count is published by
        ; native_io_status_result rather than exposed as an internal cursor.
        ld      hl,(next_record)
        ld      (m_record),hl
        call    native_select_file_user
        ld      de,(m_fcb)
        ld      hl,(m_dma)
        ; Random I/O is permitted on a caller-prepared FCB without a preceding
        ; OPEN. Resolve the supplied name for every transfer; this also avoids
        ; leaking the single sequential cursor from a previously opened file.
        ld      (load_address),hl
        call    fcb_copy_name
        jp      c,.eof
        ld      hl,(next_record)
        ld      a,(next_record+2)
        push    af
        push    hl
        call    disk_login
        jp      c,.disk_login_preserved_bad
        pop     hl
        pop     af
        ld      (next_record),hl
        ld      (next_record+2),a
; CP/M record spans are powers of two: 128 records times (EXM+1). Derive the
; 11-bit logical extent by shifting the complete 24-bit random-record value,
; retaining the low seven/eight bits as the record inside that extent.
        ld      a,(next_record)
        ld      l,a
        ld      h,0
        ld      a,(disk_extent_shift)
        or      a
        jr      nz,.record_within_ready
        ld      a,l
        and     07fh
        ld      l,a
.record_within_ready:
        ld      (record_within),hl
        ld      hl,(next_record)
        ld      a,(next_record+2)
        ld      b,7
        ld      c,a
        ld      a,(disk_extent_shift)
        add     a,b
        ld      b,a
        ld      a,c
.extent_shift_record:
        srl     a
        rr      h
        rr      l
        djnz    .extent_shift_record
        ld      (wanted_extent),hl
        ld      a,1
        ld      (record_mode),a
        call    cached_record_entry
        jr      c,.record_not_cached
        call    load_record_entry
        jr      .record_loaded
.record_not_cached:
        ; A stale entry cannot tell Function 33 whether this normalized extent
        ; exists. load_extent sets the flag before trying its record, so on a
        ; failed scan the flag cleanly separates error 1 from error 4.
        xor     a
        ld      (cached_entry_valid),a
        call    load_extent
        jp      c,native_read_extent_failure
.record_loaded:
        push    af
        xor     a
        ld      (record_mode),a
        pop     af
        jr      c,.eof
        ld      a,(m_function)
        cp      33
        call    z,a_write_fcb_position
.read_position_committed:
        ld      hl,(next_record)
        inc     hl
        ld      (next_record),hl
        ld      a,h
        or      l
        jr      nz,.next_record_ready
        ld      a,(next_record+2)
        inc     a
        ld      (next_record+2),a
.next_record_ready:
        ld      a,(m_function)
        cp      20
        call    z,m_advance_sequential_fcb
        ld      a,(m_left)
        dec     a
        ld      (m_left),a
        jr      z,.read_complete
        ld      hl,(m_dma)
        ld      de,128
        add     hl,de
        ld      (m_dma),hl
        ld      b,a
        jp      .read_position_ready
.read_complete:
        xor     a
        ret
.disk_login_preserved_bad:
        pop     hl
        pop     af
.eof:
        ld      a,(native_physical_error_code)
        or      a
        jr      z,.logical_eof
        ld      a,0ffh
        ret
.logical_eof:
        ld      a,1
        ret

fcb_copy_name:
        ld      a,d
        and     0c0h
        rlca
        rlca
        add     a,084h
        out     (0f1h),a
        ex      de,hl
        ld      a,h
        and     03fh
        or      040h
        ld      h,a
        ld      a,(hl)
        or      a
        jr      z,.fcb_drive_ok
        cp      'A'               ; some PCW programs use an ASCII drive tag
        jr      z,.fcb_drive_ok
        cp      1                 ; only physical drive A is exposed
        jr      nz,.fcb_bad_drive
.fcb_drive_ok:
        inc     hl
        ld      de,wanted_name
        ld      b,11
.fcb_name_byte:
        ld      a,(hl)
        and     07fh
        ld      (de),a
        inc     hl
        inc     de
        djnz    .fcb_name_byte
        or      a
        ret
.fcb_bad_drive:
        scf
        ret

; Convert the first command token to an upper-case 8.3 name. A missing suffix
; means COM, matching an ordinary CP/M command processor.
command_name:
        push    de
        ld      hl,wanted_name
        ld      (hl),' '
        ld      de,wanted_name+1
        ld      bc,10
        ldir
        pop     de
.skip_space:
        call    command_read
        cp      ' '
        jr      nz,.start
        inc     de
        jr      .skip_space
.start:
        or      a
        scf
        ret     z
        ld      hl,wanted_name
        ld      b,8
.copy_stem:
        call    command_read
        or      a
        jr      z,.default_extension
        cp      ' '
        jr      z,.default_extension
        cp      '.'
        jr      z,.extension
        call    uppercase_a
        ld      (hl),a
        inc     hl
        inc     de
        djnz    .copy_stem
.skip_stem:
        call    command_read
        or      a
        jr      z,.default_extension
        cp      ' '
        jr      z,.default_extension
        inc     de
        cp      '.'
        jr      nz,.skip_stem
.extension:
        inc     de
        ld      hl,wanted_name+8
        ld      b,3
.copy_extension:
        call    command_read
        or      a
        jr      z,.done
        cp      ' '
        jr      z,.done
        call    uppercase_a
        ld      (hl),a
        inc     hl
        inc     de
        djnz    .copy_extension
.done:
        ld      a,(wanted_name)
        cp      ' '
        jr      z,.invalid
        or      a
        ret
.default_extension:
        ld      hl,wanted_name+8
        ld      (hl),'C'
        inc     hl
        ld      (hl),'O'
        inc     hl
        ld      (hl),'M'
        jr      .done
.invalid:
        scf
        ret

; Shell input lives in resident common memory, while BDOS 47's command is in
; the caller's current DMA in transient bank 1. Read either address space
; without changing DE or HL so one parser serves both paths.
command_read:
        ld      a,d
        cp      0c0h
        jr      nc,.common
        push    hl
        push    de
        pop     hl
        call    gencom_tpa_read
        pop     hl
        ret
.common:
        ld      a,(de)
        ret

uppercase_a:
        cp      'a'
        ret     c
        cp      'z'+1
        ret     nc
        and     05fh
        ret

; Discover the inserted medium using READ ID, read its Amstrad disk
; specification, and derive the few CP/M allocation values needed by the COM
; loader. This first native revision accepts the ubiquitous 512-byte formats.
disk_login:
        ld      a,(disk_logged_in)
        or      a
        ret     nz
        call    native_disk_reset
        ld      a,OPENPCW_RUNTIME_PAGE
        out     (0f1h),a           ; motor helper resides in native page one
        call    native_disk_motor_on
        call    fdc_recalibrate
        ret     c
        ld      a,0ffh
        ld      (disk_sector_base),a
        ld      b,12
.ids:
        push    bc
        call    fdc_read_id
        pop     bc
        ret     c
        ld      c,a
        ld      a,(disk_sector_base)
        cp      c
        jr      c,.keep_id
        ld      a,c
        ld      (disk_sector_base),a
.keep_id:
        djnz    .ids
        ld      a,(disk_sector_n)
        cp      2
        jp      nz,.bad
        xor     a
        ld      d,a
        ld      c,a
        ld      a,(disk_sector_base)
        ld      e,a
        ld      hl,sector_buffer
        call    fdc_read_sector
        ret     c

        ; DD L XDPB copies a caller-supplied disk specification into the live
        ; XDPB. Use it when present; the inactive path preserves the sector
        ; buffer pointer established by the physical read above.
        call    native_xbios_active_spec
        jr      c,.read_spec
.detect_spec:
        ld      a,(disk_sector_base)
        cp      041h
        jr      z,.cpc_system
        cp      0c1h
        jr      z,.cpc_data
        ld      hl,sector_buffer
        ld      a,(hl)
        cp      0e9h
        jr      z,.offset_80
        cp      0eah
        jr      nz,.check_erased
.offset_80:
        ld      de,128
        add     hl,de
        jr      .read_spec
.check_erased:
        ld      b,10
.erased_loop:
        ld      a,(hl)
        cp      0e5h
        jr      nz,.read_spec_start
        inc     hl
        djnz    .erased_loop
        ld      hl,spec_pcw_180k
        jr      .read_spec
.read_spec_start:
        ld      hl,sector_buffer
        jr      .read_spec
.cpc_system:
        ld      hl,spec_cpc_system
        jr      .read_spec
.cpc_data:
        ld      hl,spec_cpc_data
.read_spec:
        ld      a,OPENPCW_RUNTIME_PAGE
        out     (0f1h),a           ; immutable disk specs live in native page 1
        ld      a,(hl)             ; format byte: 0 or 3
        or      a
        jr      z,.format_ok
        cp      3
        jp      nz,.bad
.format_ok:
        inc     hl
        ld      a,(hl)
        and     3
        cp      3
        jp      z,.bad
        ld      (disk_side_mode),a
        inc     hl
        ld      a,(hl)
        or      a
        jp      z,.bad
        ld      (disk_tracks),a
        inc     hl
        ld      a,(hl)
        or      a
        jp      z,.bad
        ld      (disk_sectors),a
        inc     hl
        ld      a,(hl)
        cp      2
        jp      nz,.bad
        inc     hl
        ld      a,(hl)
        ld      (disk_reserved),a
        inc     hl
        ld      a,(hl)
        cp      2
        jp      c,.bad
        cp      8
        jp      nc,.bad
        ld      (disk_block_shift),a
        inc     hl
        ld      a,(hl)
        or      a
        jp      z,.bad
        ld      (disk_dir_blocks),a

; block_sectors = 2^(block_shift-2), directory sectors = that * dir blocks.
        ld      a,(disk_block_shift)
        sub     2
        ld      b,a
        ld      a,1
.block_shift_loop:
        jr      z,.block_shift_done
        add     a,a
        djnz    .block_shift_loop
.block_shift_done:
        ld      (disk_block_sectors),a
        ld      e,a
        ld      a,(disk_dir_blocks)
        call    multiply_8
        ld      a,h
        or      a
        jp      nz,.bad
        ld      a,l
        ld      (disk_dir_sectors),a

; First filesystem sector and DSM.
        ld      a,(disk_sectors)
        ld      e,a
        ld      a,(disk_reserved)
        call    multiply_8
        ld      (disk_data_start),hl
        ld      a,(disk_tracks)
        ld      e,a
        ld      a,(disk_side_mode)
        or      a
        ld      a,e
        jr      z,.one_side
        add     a,a
.one_side:
        ld      c,a
        ld      a,(disk_reserved)
        ld      e,a
        ld      a,c
        sub     e
        jp      c,.bad
        ld      c,a
        ld      a,(disk_sectors)
        ld      e,a
        ld      a,c
        call    multiply_8
        ld      a,(disk_block_shift)
        sub     2
        ld      b,a
.divide_blocks:
        jr      z,.blocks_ready
        srl     h
        rr      l
        djnz    .divide_blocks
.blocks_ready:
        dec     hl
        ld      (disk_dsm),hl
        ld      a,h
        or      a
        ld      a,(disk_block_shift)
        jr      nz,.large_disk
        sub     3
        jr      .extent_power
.large_disk:
        sub     4
.extent_power:
        jp      c,.bad
        ld      (disk_extent_shift),a
        ld      a,1
        ld      (disk_logged_in),a
        or      a
        ret
.bad:
        xor     a
        ld      (disk_logged_in),a
        scf
        ret

; HL = A * E (both unsigned bytes).
multiply_8:
        ld      hl,0
        or      a
        ret     z
        ld      b,a
        ld      d,h                       ; HL was cleared above
.loop:
        add     hl,de
        djnz    .loop
        ret

fdc_recalibrate:
        ld      a,7
        call    fdc_write
        xor     a
        call    fdc_write
        call    fdc_wait_irq
        ret     c
        ld      a,8
        call    fdc_write
        call    fdc_read
        and     0c0h
        ld      b,a
        call    fdc_read
        or      b
        jr      nz,.recal_error
        ld      (current_track),a
        ret
.recal_error:
        scf
        ret

; READ ID returns its R byte in A and remembers N for format validation.
fdc_read_id:
        ld      a,04ah
        call    fdc_write
        xor     a
        call    fdc_write
        call    fdc_read
        and     0c0h
        ld      b,a
        call    fdc_read
        or      b
        ld      b,a
        call    fdc_read
        or      b
        ld      b,a
        call    fdc_read           ; C
        call    fdc_read           ; H
        call    fdc_read           ; R
        ld      c,a
        call    fdc_read           ; N
        ld      (disk_sector_n),a
        ld      a,b
        or      a
        jr      nz,.id_error
        ld      a,c
        ret
.id_error:
        scf
        ret

; A=desired cylinder. The drive/head field is zero because seeking the shared
; cylinder is independent of which side the following READ DATA selects. The
; command is issued even when PCN already matches: the public disk calls rely
; on the controller's ordinary SEEK-completion lifecycle.
fdc_seek:
        ld      b,a
        ld      a,00fh
        call    fdc_write
        xor     a
        call    fdc_write
        ld      a,b
        call    fdc_write
        call    fdc_wait_irq
        ret     c
        ld      a,8
        call    fdc_write
        call    fdc_read
        and     0c0h
        ld      c,a
        call    fdc_read
        sub     b                         ; PCN must equal requested cylinder
        or      c                         ; and ST0 must report normal status
        jr      nz,.seek_error
        ld      a,b
        ld      (current_track),a
        ret
.seek_error:
        scf
        ret

fdc_wait_irq:
.irq_wait:
        in      a,(0f8h)
        and     020h
        jr      z,.irq_wait
        ret

; D=cylinder, C=side, E=sector ID, HL=512-byte destination.  The complete
; transfer engine lives in native page one: these small page-zero bridges make
; that page explicit even when a preceding banked TPA access changed F1.
fdc_read_sector:
        ld      a,OPENPCW_RUNTIME_PAGE
        out     (0f1h),a
        jp      fdc_read_sector_page_one

; D=cylinder, C=side, E=sector ID, HL=512-byte source.  WRITE DATA is issued
; synchronously and the three status bytes are retained so the public BIOS can
; distinguish a write-protected medium from a generic I/O failure.
fdc_write_sector:
        ld      a,OPENPCW_RUNTIME_PAGE
        out     (0f1h),a
        jp      fdc_write_sector_page_one

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

; A failed READ DATA may enter result phase before delivering even one byte.
; Keep this phase discriminator in page zero because DD L READ temporarily
; maps the caller's bank over F1 while streaming a raw sector.
fdc_read_data_or_result:
.read_phase_wait:
        in      a,(0)
        and     0e0h                   ; RQM, DIO and execution-mode bits
        cp      0e0h                   ; controller -> CPU data phase
        jr      z,.read_data_ready
        cp      0c0h                   ; controller -> CPU result phase
        jr      nz,.read_phase_wait
        in      a,(1)                  ; consume ST0 for the shared parser
        scf
        ret
.read_data_ready:
        in      a,(1)
        ; CP E0h on the path above already cleared carry; IN preserves flags.
        ret

; Read filesystem sector HL (zero-based across logical tracks) to the buffer.
; The buffer shares the documented low Screen/BIOS bank which native programs
; may freely reuse between BDOS calls.  Refill it for every operation instead
; of trusting a logical-sector tag whose bytes an application may have changed.
read_logical_sector:
        ld      (sector_requested),hl
        ld      d,0
.divide_track:
        ld      a,(disk_sectors)
        ld      c,a
        ld      b,0
        ld      a,h
        or      a
        jr      nz,.subtract_track
        ld      a,l
        cp      c
        jr      c,.track_ready
.subtract_track:
        or      a
        sbc     hl,bc
        inc     d
        jr      .divide_track
.track_ready:
        ld      a,l
        ld      (sector_in_track),a
        ld      a,(disk_side_mode)
        or      a
        jr      z,.single_side
        cp      1
        jr      z,.alternating_sides
; Successive-sides format: side 0 ascends, then side 1 descends.
        ld      a,(disk_tracks)
        cp      d
        jr      nc,.side_zero
        add     a,a
        dec     a
        sub     d
        ld      d,a
        ld      c,1
        jr      .mapped
.alternating_sides:
        ld      a,d
        and     1
        ld      c,a
        srl     d
        jr      .mapped
.single_side:
.side_zero:
        ld      c,0
.mapped:
        ld      a,d
        call    fdc_seek
        jr      c,.logical_io_error
        ld      a,(sector_in_track)
        ld      e,a
        ld      a,(disk_sector_base)
        add     a,e
        ld      e,a
        ld      hl,sector_buffer
        call    fdc_read_sector
        jr      c,.logical_io_error
        ld      hl,(sector_requested)
        ld      (sector_cache_logical),hl
        ld      a,1
        ld      (sector_cache_valid),a
        or      a
        ret
.logical_io_error:
        ld      a,1                     ; CP/M Plus permanent disk I/O error
        ld      (native_physical_error_code),a
        scf
        ret

; Find and load the requested normalized CP/M extent. Carry means no matching
; directory entry (or an I/O error), which terminates the caller's extent walk.
load_extent:
        xor     a
        ld      (directory_sector),a
.next_sector:
        ld      a,(directory_sector)
        ld      c,a
        ld      a,(disk_dir_sectors)
        cp      c
        jr      z,.not_found
        ld      l,c
        ld      h,0
        ld      de,(disk_data_start)
        add     hl,de
        call    read_logical_sector
        jr      c,.not_found
        ld      ix,sector_buffer
        ld      b,16
.next_entry:
        ld      a,(native_file_user)
        cp      (ix+0)
        jr      nz,.advance
        push    bc
        call    entry_matches
        pop     bc
        jr      nz,.advance
        push    bc
        ld      a,(record_mode)
        cp      1
        jr      z,.read_record
        cp      2
        jr      z,.found_only
        cp      3
        jr      z,.overlay_entry
        call    load_entry
        pop     bc
        ret
.read_record:
        call    cache_record_entry
        call    load_record_entry
        pop     bc
        ret
.found_only:
        pop     bc
        or      a
        ret
.overlay_entry:
        call    load_overlay_entry
        pop     bc
        ret
.advance:
        ld      de,32
        add     ix,de
        djnz    .next_entry
        ld      a,(directory_sector)
        inc     a
        ld      (directory_sector),a
        jr      .next_sector
.not_found:
        scf
        ret

entry_matches:
        push    ix
        pop     de
        inc     de
        ld      hl,wanted_name
        ld      b,11
.name:
        ld      a,(de)
        and     07fh
        cp      (hl)
        ret     nz
        inc     de
        inc     hl
        djnz    .name
; Normalize EX/S2 by the EXM power stored at login.
        ld      a,(ix+14)
        and     03fh
        ld      l,a
        ld      h,0
        ld      b,5
.s2_shift:
        add     hl,hl
        djnz    .s2_shift
        ld      a,(ix+12)
        and     01fh
        or      l
        ld      l,a
        ld      a,(disk_extent_shift)
        ld      b,a
        or      a
        jr      z,.extent_ready
.extent_shift:
        srl     h
        rr      l
        djnz    .extent_shift
.extent_ready:
        ld      de,(wanted_extent)
        or      a
        sbc     hl,de
        ret

; Retain the directory entry selected for a record read. Sequential and random
; BDOS reads commonly revisit it dozens of times; keeping this independently
; owned 32-byte copy avoids rescanning physical directory sectors. Activating
; a new extent also replaces EX/S1/S2/RC and its allocation map in the caller's
; FCB, matching CP/M Plus instead of leaving metadata from the first extent.
; Exact case and normalized extent matching remain delegated to entry_matches.
cache_record_entry:
        push    ix
        pop     hl
        ld      de,cached_entry
        ld      bc,32
        ldir
        ld      a,1
        ld      (cached_entry_valid),a

; Copy the on-disk extent/allocation portion back to the caller's active FCB.
; cache_record_entry deliberately falls through here; write paths call it
; directly after updating their directory entry.
a_copy_entry_metadata_to_fcb:
        push    ix
        pop     de
        ld      hl,12
        add     hl,de
        ex      de,hl
        ld      hl,(m_fcb)
        ld      bc,12
        add     hl,bc
        ld      b,20
.a_copy_metadata_byte:
        ld      a,(de)
        call    gencom_tpa_write
        inc     de
        inc     hl
        djnz    .a_copy_metadata_byte
        ; S1 is the observable module stamp used by the PCW physical-disc
        ; module. S2 retains the copied extent module and sets CP/M's
        ; unmodified-file flag whenever an extent is activated for reading.
        ld      de,0ffedh
        add     hl,de
        ld      a,4
        call    gencom_tpa_write
        inc     hl
        ld      a,(ix+14)
        or      080h
        jp      gencom_tpa_write

; Return IX=cached entry with carry clear when it still describes the current
; exact-case name and extent; carry set requests the ordinary directory walk.
cached_record_entry:
        ld      a,(cached_entry_valid)
        or      a
        jr      z,.miss
        ld      ix,cached_entry
        ld      a,(native_file_user)
        cp      (ix+0)
        jr      nz,.miss
        call    entry_matches
        jr      nz,.miss
        xor     a
        ret
.miss:
        scf
        ret

; Return the number of 128-byte records described by IX in HL.
entry_record_count:
        ld      a,(disk_extent_shift)
        or      a
        jr      z,.zero_mask
        ld      c,a
        ld      a,1
.mask_loop:
        add     a,a
        dec     c
        jr      nz,.mask_loop
        dec     a
        jr      .mask_ready
.zero_mask:
        xor     a
.mask_ready:
        and     (ix+12)
        ld      h,0
        ld      l,a
        ld      b,7
.records_shift:
        add     hl,hl
        djnz    .records_shift
        ld      a,(ix+15)
        ld      e,a
        ld      d,0
        add     hl,de
        ret

load_entry:
        call    entry_record_count
        ld      (remaining_records),hl
        push    ix
        pop     hl
        ld      de,16
        add     hl,de
        ld      de,allocation_map
        ld      bc,16
        ldir
        ld      hl,allocation_map
        ld      (block_pointer),hl
        ld      a,(disk_dsm+1)
        or      a
        ld      a,16
        jr      z,.slots_ready
        ld      a,8
.slots_ready:
        ld      (block_slots),a
.next_block:
        ld      hl,(remaining_records)
        ld      a,h
        or      l
        ret     z
        ld      a,(block_slots)
        or      a
        jp      z,.load_error
        dec     a
        ld      (block_slots),a
        ld      hl,(block_pointer)
        ld      e,(hl)
        inc     hl
        ld      a,(disk_dsm+1)
        or      a
        ld      d,0
        jr      z,.pointer_ready
        ld      d,(hl)
        inc     hl
.pointer_ready:
        ld      (block_pointer),hl
        ld      a,d
        or      e
        jr      z,.load_error
; sector = data_start + block * block_sectors.
        ex      de,hl
        ld      a,(disk_block_shift)
        sub     2
        ld      b,a
        jr      z,.block_scaled
.scale_block:
        add     hl,hl
        djnz    .scale_block
.block_scaled:
        ld      de,(disk_data_start)
        add     hl,de
        ld      (block_sector),hl
        ld      a,(disk_block_sectors)
        ld      (sectors_in_block),a
.next_block_sector:
        ld      hl,(remaining_records)
        ld      a,h
        or      l
        jr      z,.next_block
        ld      a,(sectors_in_block)
        or      a
        jr      z,.next_block
        dec     a
        ld      (sectors_in_block),a
        ld      hl,(block_sector)
        inc     hl
        ld      (block_sector),hl
        dec     hl
        call    read_logical_sector
        jr      c,.load_error
        ld      hl,(remaining_records)
        ld      a,h
        or      a
        jr      nz,.four_records
        ld      a,l
        cp      4
        jr      nc,.four_records
        ld      b,a
        ld      c,0
        srl     b
        rr      c                 ; records * 128
        ld      hl,0
        ld      (remaining_records),hl
        jr      .copy_payload
.four_records:
        ld      bc,512
        ld      de,(remaining_records)
        ld      hl,4
        ex      de,hl
        or      a
        sbc     hl,de
        ld      (remaining_records),hl
.copy_payload:
        call    copy_to_tpa
        jr      c,.load_error
        jr      .next_block_sector
.load_error:
        scf
        ret

; LOAD OVERLAY uses the same allocation semantics as load_entry, but may
; discard a small number of leading records while packing the remaining
; extents contiguously. It still reads each 512-byte sector only once, which
; matters on a physical floppy drive.
load_overlay_entry:
        call    entry_record_count
        ld      (remaining_records),hl
        push    ix
        pop     hl
        ld      de,16
        add     hl,de
        ld      de,allocation_map
        ld      bc,16
        ldir
        ld      hl,allocation_map
        ld      (block_pointer),hl
        ld      a,(disk_dsm+1)
        or      a
        ld      a,16
        jr      z,.overlay_slots_ready
        ld      a,8
.overlay_slots_ready:
        ld      (block_slots),a
.overlay_next_block:
        ld      hl,(remaining_records)
        ld      a,h
        or      l
        ret     z
        ld      a,(block_slots)
        or      a
        jp      z,.overlay_load_error
        dec     a
        ld      (block_slots),a
        ld      hl,(block_pointer)
        ld      e,(hl)
        inc     hl
        ld      a,(disk_dsm+1)
        or      a
        ld      d,0
        jr      z,.overlay_pointer_ready
        ld      d,(hl)
        inc     hl
.overlay_pointer_ready:
        ld      (block_pointer),hl
        ld      a,d
        or      e
        jr      nz,.overlay_pointer_allocated
        ; Sparse CP/M extents may leave allocation slots zero. LOAD OVERLAY
        ; packs only allocated blocks, so consume their logical record span
        ; without consuming either output bytes or bridge-skip records.
        ld      a,(disk_block_shift)
        ld      b,a
        ld      a,1
.overlay_empty_block_scale:
        add     a,a
        djnz    .overlay_empty_block_scale
        ld      e,a
        ld      d,0
        ld      hl,(remaining_records)
        ld      a,h
        or      a
        jr      nz,.overlay_empty_block_subtract
        ld      a,l
        cp      e
        jr      nc,.overlay_empty_block_subtract
        ld      hl,0
        ld      (remaining_records),hl
        jp      .overlay_next_block
.overlay_empty_block_subtract:
        or      a
        sbc     hl,de
        ld      (remaining_records),hl
        jp      .overlay_next_block
.overlay_pointer_allocated:
        ex      de,hl
        ld      a,(disk_block_shift)
        sub     2
        ld      b,a
        jr      z,.overlay_block_scaled
.overlay_block_scale:
        add     hl,hl
        djnz    .overlay_block_scale
.overlay_block_scaled:
        ld      de,(disk_data_start)
        add     hl,de
        ld      (block_sector),hl
        ld      a,(disk_block_sectors)
        ld      (sectors_in_block),a
.overlay_next_sector:
        ld      hl,(remaining_records)
        ld      a,h
        or      l
        jr      z,.overlay_next_block
        ld      a,(sectors_in_block)
        or      a
        jr      z,.overlay_next_block
        dec     a
        ld      (sectors_in_block),a
        ld      hl,(block_sector)
        inc     hl
        ld      (block_sector),hl
        dec     hl
        call    read_logical_sector
        jr      c,.overlay_load_error

        ld      hl,(remaining_records)
        ld      a,h
        or      a
        ld      a,4
        jr      nz,.overlay_records_ready
        ld      a,l
        cp      4
        jr      c,.overlay_records_ready
        ld      a,4
.overlay_records_ready:
        ld      (overlay_records_this),a
        ld      e,a
        ld      d,0
        or      a
        sbc     hl,de
        ld      (remaining_records),hl

        ld      a,(overlay_skip_records)
        or      a
        jr      z,.overlay_copy_full_sector
        ld      c,a
        ld      a,(overlay_records_this)
        cp      c
        jr      z,.overlay_skip_whole_sector
        jr      c,.overlay_skip_whole_sector
        ; C is the 1..3 leading records to discard from this sector.
        ld      a,(overlay_records_this)
        sub     c
        ld      b,a
        ld      a,c
        ld      l,a
        ld      h,0
        ld      a,7
.overlay_skip_byte_shift:
        add     hl,hl
        dec     a
        jr      nz,.overlay_skip_byte_shift
        ld      de,sector_buffer
        add     hl,de
        ld      (copy_source),hl
        ld      c,0
        srl     b
        rr      c
        xor     a
        ld      (overlay_skip_records),a
        call    copy_to_tpa
        jr      c,.overlay_load_error
        jp      .overlay_next_sector
.overlay_skip_whole_sector:
        ld      a,c
        ld      c,a
        ld      a,(overlay_records_this)
        ld      b,a
        ld      a,c
        sub     b
        ld      (overlay_skip_records),a
        jp      .overlay_next_sector
.overlay_copy_full_sector:
        ld      hl,sector_buffer
        ld      (copy_source),hl
        ld      a,(overlay_records_this)
        ld      b,a
        ld      c,0
        srl     b
        rr      c
        call    copy_to_tpa
        jr      c,.overlay_load_error
        jp      .overlay_next_sector
.overlay_load_error:
        scf
        ret

load_record_entry:
        call    entry_record_count
        ex      de,hl              ; DE=records in this directory entry
        ld      hl,(record_within)
        or      a
        sbc     hl,de
        jr      nc,.record_error

; Preserve the record's offset inside its allocation block.
        ld      a,(disk_block_shift)
        ld      b,a
        ld      a,1
.record_mask_loop:
        add     a,a
        djnz    .record_mask_loop
        dec     a
        ld      hl,(record_within)
        and     l
        ld      (record_in_block),a

; Select the byte/word block pointer indexed by record >> block_shift.
        ld      hl,(record_within)
        ld      a,(disk_block_shift)
        ld      b,a
.record_slot_shift:
        srl     h
        rr      l
        djnz    .record_slot_shift
        ld      a,(disk_dsm+1)
        or      a
        jr      z,.record_slot_ready
        add     hl,hl
.record_slot_ready:
        ld      de,16
        add     hl,de
        push    ix
        pop     de
        add     hl,de
        ld      e,(hl)
        inc     hl
        ld      a,(disk_dsm+1)
        or      a
        ld      d,0
        jr      z,.record_pointer_ready
        ld      d,(hl)
.record_pointer_ready:
        ld      a,d
        or      e
        jr      z,.record_error
        ex      de,hl
        ld      a,(disk_block_shift)
        sub     2
        ld      b,a
        jr      z,.record_block_scaled
.record_block_scale:
        add     hl,hl
        djnz    .record_block_scale
.record_block_scaled:
        ld      de,(disk_data_start)
        add     hl,de
        ld      a,(record_in_block)
        srl     a
        srl     a
        ld      e,a
        ld      d,0
        add     hl,de
        call    read_logical_sector
        jr      c,.record_error

        ld      a,(record_in_block)
        and     3
        ld      l,a
        ld      h,0
        ld      b,7
.record_byte_shift:
        add     hl,hl
        djnz    .record_byte_shift
        ld      de,sector_buffer
        add     hl,de
        ld      (copy_source),hl
        ld      bc,128
        call    copy_to_tpa
        ret
.record_error:
        scf
        ret

; Copy BC bytes from the sector buffer to the logical transient load address.
; F1 is the paging window, so the native code in F0 remains executable.
copy_to_tpa:
        ld      hl,(copy_source)
.byte:
        ld      a,b
        or      c
        ret     z
        ld      de,(load_address)
        ld      a,(record_mode)
        cp      3
        jr      nz,.fixed_ceiling
        push    hl
        ld      hl,(gencom_rsx_low)
        or      a
        sbc     hl,de
        pop     hl
        jr      c,.overflow
        jr      z,.overflow
        jr      .address_ready
.fixed_ceiling:
        ld      a,d
        cp      0f2h
        jr      nc,.overflow
.address_ready:
        ld      a,d
        and     0c0h
        rlca
        rlca
        add     a,084h
        ld      (target_page),a
        out     (0f1h),a
        ld      a,d
        and     03fh
        or      040h
        ld      d,a
        ld      a,(hl)
        ld      (de),a
        inc     hl
        ld      de,(load_address)
        inc     de
        ld      (load_address),de
        dec     bc
        jr      .byte
.overflow:
        scf
        ret

; The physical-page-zero service area is full.  Its stable internal symbol is
; a three-byte bridge to the scanner in native page one, which is always
; mapped by every resident keyboard trampoline.
keyboard_scan:
        jp      keyboard_scan_page_one

cursor_x:       db      0
cursor_y:       db      0
escape_state:   db      0
escape_position_row: db 0
terminal_view_top: db 0
terminal_view_left: db 0
terminal_bottom_row: db 30
terminal_view_right: db 89
terminal_pending_top: db 0
terminal_pending_left: db 0
terminal_pending_height: db 31
terminal_character: db 0

; These two extensions deliberately occupy only the existing padding before
; the fixed keyboard ABI. Repointing same-size CALL/JP instructions above
; leaves every established native address unchanged.
native_init_finish:
        out     (0f8h),a
        call    native_boot_banner
        ret

native_boot_banner:
        ld      hl,OPENPCW_COMMON_BANNER_PREFIX
        call    native_print_string
        ld      hl,native_banner_continuation
        call    native_print_string
        ld      a,(native_ram_pages)
        cp      16
        jr      nz,.banner_capacity_ready
        ld      hl,native_banner_capacity
        ld      (hl),'1'
        inc     hl
        ld      (hl),'1'
        inc     hl
        ld      (hl),'2'
.banner_capacity_ready:
        ld      hl,native_banner_capacity
        jr      native_print_string

native_print_string:
        ld      a,(hl)
        or      a
        ret     z
        push    hl
        call    native_putc
        pop     hl
        inc     hl
        jr      native_print_string

native_banner_continuation:
        db      'ive, ',0
native_banner_capacity:
        db      '368K drive M:',13,10,13,10,0

; Parse normally for A:. For M:, complete the whole load here and discard the
; helper return address so native_execute returns directly to its resident
; caller instead of entering the physical-floppy path below it.
native_execute_dispatch:
        call    command_name
        ret     c
        ld      a,(OPENPCW_COMMON_CURRENT_DISK)
        cp      12
        jr      z,.execute_m
        or      a                       ; A: continues with carry clear
        ret
.execute_m:
        ld      hl,native_prepare_command_page_zero_overlay
        call    native_cursor_overlay_call
        ld      hl,0050h
        ld      a,13
        call    gencom_tpa_write
        ld      hl,wanted_name
        ld      de,m_name
        ld      bc,11
        ldir
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        inc     a
        ld      (m_match_user),a
        call    m_find
        jr      c,.execute_m_failed
        ld      hl,0100h
        ld      (m_overlay_load),hl
        call    m_overlay_generic
        jr      nz,.execute_m_failed
        ld      hl,(m_overlay_load)
        ld      (load_address),hl
        pop     hl
        ld      a,1
        ret
.execute_m_failed:
        pop     hl
        xor     a
        ret

; Physical A: uses the same completion-count ABI as the M: back end. Keeping
; the conversion beside the resident/private padding makes both dispatch
; veneers identical without moving a fixed native entry point.
native_physical_read_result:
        call    native_read
        jp      native_io_status_result

        ; Keep the resident/native private keyboard ABI independent of small
        ; filesystem-dispatch size changes above.
        defs    03b23h-$,0
key_pending:    db      0
key_pending_valid: db   0
keyboard_last_code: db  0ffh
keyboard_repeat_started: db 0
keyboard_repeat_initial: db 30
keyboard_repeat_delay: db 2
keyboard_repeat_remaining: dw 0
keyboard_previous_tick: dw 300
keyboard_injected_key: db 0ffh
keyboard_injected_shifts: db 0
keyboard_shift_lock_key_down: db 0
keyboard_shift_lock: db 0
keyboard_caps_lock: db 0
keyboard_num_lock: db 0
native_disk_defaults: db 10,50,175,30,12,15,3
native_ram_pages: db    32
native_m_blocks: db     184
native_m_data_blocks: db 182
native_m_records: dw    2912
native_ram_probe_page9: db 0
native_ram_probe_page25: db 0
native_free_records: db 0,0,0
disk_logged_in: db      0
cached_entry_valid: db   0
sector_cache_valid: db   0
sector_cache_logical: dw 0
sector_requested: dw     0
low_bank:       db       0
low_address:    dw       0
low_cursor:     dw       0
low_remaining:  dw       0
low_sector_bytes: dw     0
low_transfer:   dw       0
low_target_page: db      0
low_cylinder:   db       0
low_side:       db       0
low_sector:     db       0
low_end_sector: db       0
low_command:    db       046h
low_unit:       db       0
low_head:       db       0
low_n:          db       2
low_gpl:        db       02ah
low_dtl:        db       0ffh
current_track:  db      0
disk_sector_base: db    1
disk_sector_n:  db      2
disk_side_mode: db      0
disk_tracks:    db      40
disk_sectors:   db      9
disk_reserved:  db      1
disk_block_shift: db    3
disk_dir_blocks: db     2
disk_block_sectors: db  2
disk_dir_sectors: db    4
disk_extent_shift: db   0
disk_data_start: dw     9
disk_dsm:       dw      0
sector_in_track: db     0
directory_sector: db    0
last_fdc_st0:  db       0
last_fdc_st1:  db       0
last_fdc_st2:  db       0
wanted_extent: dw       0
record_mode:   db       0
record_in_block: db     0
block_slots:   db       0
sectors_in_block: db    0
target_page:   db       084h
remaining_records: dw   0
block_pointer: dw       0
block_sector: dw        0
xbios_destination: dw   0
xbios_bank:     db      1
xbios_track:    db      0
xbios_sector:   db      0
xbios_check_mode: db    0
bios_drive:     db      0
bios_track:     dw      0
bios_sector:    dw      0
bios_dma:       dw      0080h
bios_dma_bank:  db      1
bios_multisector: db    1
bios_work_track: dw     0
bios_work_sector: dw    0
bios_work_dma:  dw      0080h
bios_remaining: db      1
bios_xmove_pending: db  0
bios_move_source_bank: db 1
bios_move_destination_bank: db 1
bios_move_return_de: dw 0
bios_move_return_hl: dw 0
direct_bios_function: db 0
direct_bios_a:  db      0
direct_bios_bc: dw      0
direct_bios_de: dw      0
direct_bios_hl: dw      0
load_address: dw        0100h
copy_source:  dw        sector_buffer
next_record:  db        0,0,0
record_within: dw       0
wanted_name:  defs      11,' '
allocation_map: defs    16,0

; These compact resident stubs map the independently authored block-three
; cursor overlay. The overlay tail-jumps through the existing page-two restore
; bridge, so CALLers resume with the ordinary TPA mapping intact.
m_normalize_deferred_cursor:
        ld      hl,m_normalize_deferred_cursor_overlay
        jp      native_cursor_overlay_call
a_write_fcb_s2:
        ld      c,a
        ld      hl,a_write_fcb_s2_overlay
        jp      native_cursor_overlay_call
m_write_random_cr:
        ld      hl,m_write_random_cr_overlay
        jp      native_cursor_overlay_call
native_cursor_overlay_call:
        ld      a,083h
        out     (0f2h),a
        jp      (hl)

sector_buffer:
        defs    512,0

; A takeover program may legitimately replace the whole common block 7 while
; continuing to call BDOS. Keep the screen paging bridge in protected physical
; block 0 instead of common RAM: native_begin already maps that block at F0,
; so this routine remains executable while F1 temporarily exposes the upper
; half of the bitmap. Carry selects copy; clear carry selects zero fill.
native_screen_copy_private:
        scf
native_screen_transfer_private:
        ld      a,081h
        out     (0f1h),a
        jr      c,.copy
        xor     a
        ld      (hl),a
.copy:
        ldir
        ld      a,OPENPCW_RUNTIME_PAGE
        out     (0f1h),a
        xor     a
        ret

; TE STATUS OFF can be requested after a takeover has reused common block 7.
; Start its register-preserving clear in the last bytes of protected block 0
; and finish it in the other protected hole immediately below 4000h.
native_status_disable_private:
        push    bc
        push    de
        push    hl
        xor     a
        ld      hl,0b060h               ; first byte of physical text row 31
        jp      native_status_disable_finish

; Everything before this label must remain in physical block zero because it
; is executable or used while the transient bank occupies 4000h-BFFFh.  The
; assembler's fixed padding rejects an overflow before a corrupt image can be
; emitted.  The display font is needed only by native_init, while block one
; is mapped, and therefore lives safely on the other side of the boundary.
        defs    03e00h-$,0
native_a_alv:
        ; A normal PCW medium needs only a few dozen ALV bytes. Keep the first
        ; 128 bytes contiguous (enough for DSM 1023) and use the formerly
        ; over-reserved tail for the USERF services that must remain callable
        ; after a program has replaced the screen pages with its own data.
        defs    128,0

native_userf_safe_dispatch:
        ; Prefer the complete page-one implementation while its entry remains
        ; resident. A raw screen loader may subsequently overwrite that page;
        ; the protected fallbacks below keep its essential disk path alive.
        push    hl
        ld      hl,native_userf_misc
        ld      a,(hl)
        cp      03ah                    ; LD A,(OPENPCW_COMMON_ARGUMENT_A)
        jr      nz,.userf_safe_fallback
        inc     hl
        ld      a,(hl)
        cp      016h
        jr      nz,.userf_safe_fallback
        inc     hl
        ld      a,(hl)
        cp      0f8h
        jr      z,.userf_safe_complete
.userf_safe_fallback:
        pop     hl
        ld      a,(OPENPCW_COMMON_ARGUMENT_A)
        cp      080h                    ; DD INIT
        jr      z,.userf_safe_disk_init
        cp      0a4h                    ; DD L ON MOTOR
        jr      z,.userf_safe_motor_on
        cp      0a7h                    ; DD L T OFF MOTOR
        jr      z,.userf_safe_motor_delay
        cp      0aah                    ; DD L OFF MOTOR
        jr      z,.userf_safe_motor_off
        cp      0adh                    ; DD L READ
        jr      z,.userf_safe_low_read
        cp      0b3h                    ; DD L SEEK
        jp      nz,native_userf_misc
        ld      a,9
        out     (0f8h),a
        ld      a,4
        out     (0f8h),a
        ld      a,c
        and     3
        jr      nz,.userf_safe_seek_bad
        ld      a,d
        call    fdc_seek
        jr      c,.userf_safe_seek_bad
        xor     a
        scf
        ret
.userf_safe_seek_bad:
        ld      a,2
        or      a
        ret
.userf_safe_disk_init:
        xor     a
        out     (0f8h),a
        call    native_disk_reset
        xor     a
        ret
.userf_safe_motor_on:
        ld      a,9
        out     (0f8h),a
        ld      a,4
        out     (0f8h),a
        ret
.userf_safe_motor_delay:
        ret
.userf_safe_motor_off:
        xor     a
        out     (0f8h),a
        ret
.userf_safe_low_read:
        jp      native_userf_low_read_bridge
.userf_safe_complete:
        pop     hl
        jp      native_userf_misc

; DIR executes from protected page one, so every helper which can expose a
; transient or sparse-M page through F1 restores the native runtime mapping
; before returning. The three entries share one AF-preserving tail and fit in
; the existing pre-3F00h padding, leaving the public allocation-vector ABI
; untouched.
native_dir_search_first_bridge:
        call    native_search_first
        jr      native_dir_restore_page_one
native_dir_search_next_bridge:
        call    native_search_next
        jr      native_dir_restore_page_one
native_tpa_read_restore_page_one_bridge:
native_dir_tpa_read_bridge:
        call    gencom_tpa_read
native_dir_restore_page_one:
        push    af
        ld      a,OPENPCW_RUNTIME_PAGE
        out     (0f1h),a
        pop     af
        ret

        defs    03f00h-$,0
native_m_alv:
        ; DSM is at most 183 on a 512 KiB PCW, so its public allocation
        ; vector contains exactly ceil(184/8) bytes. Keep both published ALV
        ; addresses unchanged and use the formerly over-reserved tail for
        ; bank-zero helpers which must survive transient paging.
        defs    9,0

native_directory_error_9:
        ld      a,9
        jr      native_directory_error_store
native_directory_error_8:
        ld      a,8
native_directory_error_store:
        ld      (native_physical_error_code),a
        ld      a,0ffh
        scf
        ret

m_open_result:
        call    m_open
        jp      native_m_status_result
m_create_result:
        call    m_create
        or      a
        jr      nz,.m_create_done
        call    native_open_m_bridge
.m_create_done:
        jp      native_m_status_result
a_make_result:
        call    a_make
        or      a
        jr      nz,.a_make_done
        call    native_open_a_bridge
.a_make_done:
        jp      native_m_status_result
a_close_result:
        call    a_close
        jp      native_m_status_result
m_close_result:
        call    m_close
        jp      native_m_status_result

; All writes are synchronous, but Function 16 must still reject an absent
; FCB. f5' partial close uses the same existence test and remains activated.
a_close:
        call    disk_login
        jr      c,.a_close_bad
        call    a_name_is_exact
        jr      c,.a_close_bad
        call    a_file_exists_exact
        jr      c,.a_close_bad
        xor     a
        ret
.a_close_bad:
        ld      a,0ffh
        ret

m_close:
        ld      hl,m_close_overlay
        jp      native_cursor_overlay_call

; Native USERF dispatch lives in page one, while sector operations may map F1
; to either CP/M bank. These page-zero bridges restore native page one and the
; returned AF before control can resume there. They occupy the deliberately
; available tail after the two public allocation vectors.
native_userf_read_bridge:
        push    bc
        push    de
        push    hl
        call    native_xbios_read_sector
        pop     hl
        pop     de
        pop     bc
        jr      native_userf_restore_page_one
native_userf_login_bridge:
        call    native_xbios_login
        jr      native_userf_restore_page_one
native_userf_low_read_bridge:
        call    native_xbios_low_read
native_userf_restore_page_one:
        push    af
        ld      a,OPENPCW_RUNTIME_PAGE
        out     (0f1h),a
        pop     af
        ret

; Block-zero bridges are the only routines which change F2 while Function 15
; is active. The result AF is retained while physical page two is restored.
native_open_prepare_bridge:
        ld      a,083h
        out     (0f2h),a
        call    native_open_prepare_overlay
        jr      native_open_restore_page_two
native_open_m_bridge:
        ld      a,083h
        out     (0f2h),a
        call    native_m_overlay_dispatch
        jr      native_open_restore_page_two
native_open_a_bridge:
        ld      a,083h
        out     (0f2h),a
        call    native_a_overlay_dispatch
native_open_restore_page_two:
        push    af
        ; The operand is an owned page shadow as well as the ordinary block-2
        ; default. BDOS 59 temporarily publishes block 3 here so nested cursor
        ; helpers return to their overlay caller; its final path restores 82h.
        db      03eh                    ; LD A,n
native_open_restore_page_value:
        db      082h
        out     (0f2h),a
        pop     af
        ret

; Select the physical A: directory user for an activated FCB. A normal Open
; and caller-prepared FCB use the current user; f8' records the read-only
; USER-0 SYS fallback established by Function 15.
native_select_file_user:
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        ld      (native_file_user),a
        ld      hl,(m_fcb)
        ld      de,8
        add     hl,de
        call    gencom_tpa_read
        and     080h
        ret     z
        xor     a
        ld      (native_file_user),a
        ret

native_file_user: db     0
cached_entry:     defs   32,0

; Compact post-ALV helpers keep the fixed 3E00h/3F00h allocation-vector ABI
; intact. Both execute from resident physical block zero while record and
; directory services temporarily page the transient through F1/F2.
native_read_extent_failure:
        ld      a,083h
        out     (0f2h),a
        call    native_read_extent_status_overlay
        jr      native_extent_restore_page_two

; A sparse M: record can be absent inside a directory extent already
; materialised by the file's virtual size (error 1), or beyond its final
; normalized EXM=1 extent (error 4). Extent zero exists even for an empty file.
native_m_read_failure:
        ld      a,(m_function)
        cp      33
        ld      a,1
        ret     nz
        ld      a,083h
        out     (0f2h),a
        call    native_m_extent_status_overlay
native_extent_restore_page_two:
        push    af
        ld      a,082h
        out     (0f2h),a
        pop     af
        ret

native_status_disable_finish:
        ld      de,0b061h
        ld      bc,719
        call    native_screen_transfer_private
        pop     hl
        pop     de
        pop     bc
        jp      native_userf_restore_af
native_executable_end:
        defs    04000h-$,0

; The 1K region at 4000h is executable after boot. The keyboard runtime is
; assembled into it below; the MIT-licensed font source instead travels at the
; end of the boot payload and is copied to the PCW character RAM before the
; terminal clears the screen (and therefore before that transient source may
; be overwritten).
        defs    04400h-$,0
        ; Keep the separately pinned page-one entry points stable after the
        ; compact direct-alias publisher reclaimed two executable bytes.
        defs    2,0

; Independently authored default US/UK-compatible translations. Each record
; is public PCW key number, normal byte, SHIFT byte. Unlisted function/edit
; keys begin as the documented dead token 9Fh and remain redefinable through
; KM SET KEY in all five translation states.
key_defaults:
        db 18,13,13, 78,13,13, 47,' ',' ', 68,9,9
        db 72,8,8, 16,127,127, 8,27,27, 66,3,3
        db 69,'a','A', 54,'b','B', 62,'c','C', 61,'d','D'
        db 58,'e','E', 53,'f','F', 52,'g','G', 44,'h','H'
        db 35,'i','I', 45,'j','J', 37,'k','K', 36,'l','L'
        db 38,'m','M', 46,'n','N', 34,'o','O', 27,'p','P'
        db 67,'q','Q', 50,'r','R', 60,'s','S', 51,'t','T'
        db 42,'u','U', 55,'v','V', 59,'w','W', 63,'x','X'
        db 43,'y','Y', 71,'z','Z'
        db 32,'0',')', 64,'1','!', 65,'2','"', 57,'3','#'
        db 56,'4','$', 49,'5','%', 48,'6','&', 41,'7',27h
        db 40,'8','(', 33,'9',')', 24,'=','+', 25,'-','_'
        db 17,']','}', 26,'[','{', 39,',','<', 31,'.','>'
        db 30,'/','?', 29,';',':'
        db 0ffh

; Immutable fallback format descriptors are used only while disk_login owns
; F1, so they share native page 1 with the font and keyboard table.
spec_pcw_180k: db       0,0,40,9,2,1,3,2,02ah,052h
spec_cpc_system: db     0,0,40,9,2,2,3,2,02ah,052h
spec_cpc_data: db       0,0,40,9,2,0,3,2,02ah,052h
overlay_bit_masks: db   1,2,4,8,16,32,64,128

keyboard_runtime_continuation equ $
macro keyboard_runtime_blob
keyboard_init_page_one:
        xor     a
        ld      (keyboard_repeat_started),a
        ld      (keyboard_injected_shifts),a
        ld      (keyboard_shift_lock_key_down),a
        ld      (keyboard_shift_lock),a
        ld      (keyboard_caps_lock),a
        ld      (keyboard_num_lock),a
        ld      a,0ffh
        ld      (keyboard_last_code),a
        ld      (keyboard_injected_key),a
        ld      (keyboard_expansion_active),a
        ld      (keyboard_long_expansion_index),a
        ld      a,30
        ld      (keyboard_repeat_initial),a
        ld      a,2
        ld      (keyboard_repeat_delay),a
        ld      hl,(OPENPCW_COMMON_CLOCK_TICKS)
        ld      (keyboard_previous_tick),hl
        ld      hl,keyboard_override_valid
        ld      de,keyboard_override_valid+1
        ld      bc,80
        xor     a
        ld      (hl),a
        ldir
        ld      hl,keyboard_expansion_lengths
        ld      de,keyboard_expansion_lengths+1
        ld      bc,30
        ld      (hl),a
        ldir
        ret

; Return one translated character in A/carry. This central event stream is
; shared by BIOS console input and the public keyboard XBIOS calls.
keyboard_scan_page_one:
keyboard_next_character:
        ld      a,(keyboard_expansion_active)
        cp      0ffh
        jr      z,keyboard_next_raw_character
        ld      (keyboard_set_index),a
        ld      e,a
        call    keyboard_expansion_address
        ld      a,(keyboard_expansion_position)
        ld      c,a
        ld      b,0
        add     hl,bc
        ld      a,(hl)
        push    af
        inc     c
        ld      a,c
        ld      (keyboard_expansion_position),a
        ld      hl,keyboard_expansion_lengths
        ld      a,(keyboard_set_index)
        ld      e,a
        ld      d,0
        add     hl,de
        ld      a,(hl)
        cp      c
        jr      nz,keyboard_expansion_character_ready
        ld      a,0ffh
        ld      (keyboard_expansion_active),a
keyboard_expansion_character_ready:
        pop     af
        scf
        ret

keyboard_next_raw_character:
        call    keyboard_raw_event
        ret     nc
        call    keyboard_translate_event
        cp      09fh
        jr      z,keyboard_no_character
        cp      080h
        jr      c,keyboard_direct_character
        cp      09fh
        jr      nc,keyboard_direct_character
        sub     080h
        ld      e,a
        ld      d,0
        ld      hl,keyboard_expansion_lengths
        add     hl,de
        ld      a,(hl)
        or      a
        jr      z,keyboard_no_character
        ld      a,e
        ld      (keyboard_expansion_active),a
        ld      a,1
        ld      (keyboard_expansion_position),a
        ld      a,e
        call    keyboard_expansion_address
        ld      a,(hl)
keyboard_direct_character:
        scf
        ret
keyboard_no_character:
        or      a
        ret

; A=index 0..30. Normal strings have independent 128-byte slots. One string
; may occupy the full 255-byte long slot, matching the public API's finite
; buffer/failure contract without imposing the old 64-byte ceiling.
keyboard_expansion_address:
        ld      e,a
        ld      a,(keyboard_long_expansion_index)
        cp      e
        ld      a,e
        jr      nz,keyboard_expansion_short_address
        ld      hl,keyboard_long_expansion
        ret
keyboard_expansion_short_address:
        ld      l,0
        ld      h,a
        srl     h
        rr      l                        ; index*128
        ld      de,keyboard_expansion_slots
        add     hl,de
        ret

; Produce a raw key event in C and shift bitmap in B. Injected KM KT PUT
; events take priority; physical held keys use 50Hz delays derived solely
; from the PCW's 300Hz common ticker.
keyboard_raw_event:
        ld      a,(keyboard_injected_key)
        cp      0ffh
        jr      z,keyboard_raw_physical
        ld      c,a
        ld      a,0ffh
        ld      (keyboard_injected_key),a
        ld      a,(keyboard_injected_shifts)
        ld      b,a
        scf
        ret
keyboard_raw_physical:
        call    keyboard_scan_raw
        cp      0ffh
        jr      nz,keyboard_raw_pressed
        ld      (keyboard_last_code),a
        xor     a
        ld      (keyboard_repeat_started),a
        or      a
        ret
keyboard_raw_pressed:
        ld      c,a
        ld      a,(keyboard_last_code)
        cp      c
        jr      z,keyboard_raw_held
        ld      a,c
        ld      (keyboard_last_code),a
        xor     a
        ld      (keyboard_repeat_started),a
        ld      a,(keyboard_repeat_initial)
        call    keyboard_set_repeat_countdown
        scf
        ret
keyboard_raw_held:
        push    bc
        call    keyboard_repeat_elapsed
        ld      de,(keyboard_repeat_remaining)
        ex      de,hl                    ; HL=remaining, DE=elapsed
        or      a
        sbc     hl,de
        jr      z,keyboard_raw_repeat_due
        jr      c,keyboard_raw_repeat_due
        ld      (keyboard_repeat_remaining),hl
        pop     bc
        or      a
        ret
keyboard_raw_repeat_due:
        pop     bc
        ld      a,b
        or      008h                    ; generated by repeat
        ld      b,a
        ld      a,1
        ld      (keyboard_repeat_started),a
        ld      a,(keyboard_repeat_delay)
        call    keyboard_set_repeat_countdown
        scf
        ret

; A=delay in 50ths; zero is the documented value 256.
keyboard_set_repeat_countdown:
        ld      l,a
        ld      h,0
        or      a
        jr      nz,keyboard_repeat_count_nonzero
        inc     h
keyboard_repeat_count_nonzero:
        ld      d,h
        ld      e,l
        add     hl,hl                    ; 2x
        add     hl,de                    ; 3x
        add     hl,hl                    ; six 300Hz ticks per 50th
        ld      (keyboard_repeat_remaining),hl
        ld      hl,(OPENPCW_COMMON_CLOCK_TICKS)
        ld      (keyboard_previous_tick),hl
        ret

; Return in HL the elapsed 300Hz ticks. The common counter counts down from
; 300; keyboard polling is frequent enough that at most one wrap occurs.
keyboard_repeat_elapsed:
        ld      de,(keyboard_previous_tick)
        ld      hl,(OPENPCW_COMMON_CLOCK_TICKS)
        ld      (keyboard_previous_tick),hl
        ex      de,hl                    ; HL=previous, DE=current
        or      a
        sbc     hl,de
        ret     nc
        ld      de,300
        add     hl,de
        ret

; Scan active-high PCW matrix bytes 0..A in physical block 3. Public keys are
; 0..71, byte-9 bit 7 is 72, and byte-A bits 0..7 are 73..80.
keyboard_scan_raw:
        ld      a,083h
        out     (0f2h),a
        ld      b,0
        ld      a,(0bffah)
        and     002h
        jr      z,keyboard_scan_no_extra
        set     1,b
keyboard_scan_no_extra:
        ld      a,(keyboard_caps_lock)
        or      a
        jr      z,keyboard_scan_no_caps
        set     2,b
keyboard_scan_no_caps:
        ld      a,(keyboard_num_lock)
        or      a
        jr      z,keyboard_scan_no_num
        set     4,b
keyboard_scan_no_num:
        ld      a,(0bff2h)
        and     020h
        jr      z,keyboard_scan_no_shift
        set     5,b
keyboard_scan_no_shift:
        ld      a,(0bffah)
        and     080h
        jr      z,keyboard_scan_no_alt
        set     7,b
keyboard_scan_no_alt:
        ; In emulators key 70 is a momentary matrix bit, so reproduce the
        ; keyboard controller's latch. Real hardware also reports its state
        ; through byte D bit 6; ORing both sources keeps the result portable.
        ld      a,(0bff8h)
        and     040h
        ld      c,a
        ld      a,(keyboard_shift_lock_key_down)
        xor     c
        and     c
        jr      z,keyboard_scan_lock_edge_done
        ld      a,(keyboard_shift_lock)
        xor     1
        ld      (keyboard_shift_lock),a
keyboard_scan_lock_edge_done:
        ld      a,c
        ld      (keyboard_shift_lock_key_down),a
        ld      a,(0bffdh)
        and     040h
        jr      nz,keyboard_scan_lock_on
        ld      a,(keyboard_shift_lock)
        or      a
        jr      z,keyboard_scan_lock_done
keyboard_scan_lock_on:
        set     6,b
keyboard_scan_lock_done:
        ld      a,b
        ld      (keyboard_scan_shifts),a

        ld      hl,0bff0h
        ld      c,0
        ld      d,9
keyboard_scan_row:
        ld      e,(hl)
        ld      b,8
keyboard_scan_bit:
        rr      e
        jr      c,keyboard_scan_candidate
keyboard_scan_next_bit:
        inc     c
        djnz    keyboard_scan_bit
        inc     hl
        dec     d
        jr      nz,keyboard_scan_row
        ; Only byte-9 bit 7 is public key 72.
        ld      a,(0bff9h)
        and     080h
        jr      nz,keyboard_scan_found_72
        ld      a,(0bffah)
        ld      e,a
        res     1,e                     ; EXTRA is a modifier
        res     7,e                     ; ALT is a modifier
        ld      c,73
        ld      b,8
keyboard_scan_last_byte:
        rr      e
        jr      c,keyboard_scan_candidate
        inc     c
        djnz    keyboard_scan_last_byte
        jr      keyboard_scan_none
keyboard_scan_found_72:
        ld      c,72
        jr      keyboard_scan_found
keyboard_scan_candidate:
        ld      a,c
        cp      21                      ; SHIFT
        jr      z,keyboard_scan_next_bit
        cp      70                      ; SHIFT LOCK
        jr      z,keyboard_scan_next_bit
        cp      74                      ; EXTRA
        jr      z,keyboard_scan_next_bit
        cp      80                      ; ALT
        jr      z,keyboard_scan_next_bit
keyboard_scan_found:
        ld      a,082h
        out     (0f2h),a
        ld      a,(keyboard_scan_shifts)
        ld      b,a
        ld      a,c
        ret
keyboard_scan_none:
        ld      a,082h
        out     (0f2h),a
        ld      a,(keyboard_scan_shifts)
        ld      b,a
        ld      a,0ffh
        ret

; Input C=public key and B=shift bitmap. Return translated byte in A.
keyboard_translate_event:
        ld      a,b
        and     002h
        jr      nz,keyboard_translate_extra
        ld      a,b
        and     060h
        ld      e,0
        cp      020h
        jr      z,keyboard_translate_shifted
        cp      040h
        jr      nz,keyboard_translate_shift_ready
keyboard_translate_shifted:
        inc     e
keyboard_translate_shift_ready:
        bit     7,b
        jr      z,keyboard_translate_caps
        inc     e
        inc     e
        jr      keyboard_translate_state_ready
keyboard_translate_extra:
        ld      e,4
        jr      keyboard_translate_state_ready
keyboard_translate_caps:
        bit     2,b
        jr      z,keyboard_translate_state_ready
        push    de
        call    keyboard_default_lookup
        ld      a,d
        pop     de
        jr      nc,keyboard_translate_state_ready
        cp      'a'
        jr      c,keyboard_translate_state_ready
        cp      'z'+1
        jr      nc,keyboard_translate_state_ready
        ld      a,e
        xor     1
        ld      e,a
keyboard_translate_state_ready:
        ld      a,e
        ld      (keyboard_translation_state),a
        ld      l,c
        ld      h,0
        ld      de,keyboard_override_valid
        add     hl,de
        ld      a,(keyboard_translation_state)
        ld      e,a
        ld      d,0
        push    hl
        ld      hl,overlay_bit_masks
        add     hl,de
        ld      a,(hl)
        pop     hl
        and     (hl)
        jr      z,keyboard_translate_default
        ld      l,c
        ld      h,0
        ld      d,h
        ld      e,l
        add     hl,hl
        add     hl,hl
        add     hl,de                    ; key*5
        ld      a,(keyboard_translation_state)
        ld      e,a
        ld      d,0
        add     hl,de
        ld      de,keyboard_override_values
        add     hl,de
        ld      a,(hl)
        ret
keyboard_translate_default:
        ld      a,(keyboard_translation_state)
        cp      2
        jr      c,keyboard_translate_default_lookup
        cp      4
        jr      z,keyboard_translate_default_lookup
        ld      a,09fh
        ret
keyboard_translate_default_lookup:
        call    keyboard_default_lookup
        jr      nc,keyboard_translate_dead
        ld      a,(keyboard_translation_state)
        or      a
        jr      z,keyboard_translate_plain
        cp      1
        jr      z,keyboard_translate_shift
        ld      a,d                      ; EXTRA controls alphabetic keys
        cp      'a'
        jr      c,keyboard_translate_plain
        cp      'z'+1
        jr      nc,keyboard_translate_plain
        and     01fh
        ret
keyboard_translate_plain:
        ld      a,d
        ret
keyboard_translate_shift:
        ld      a,e
        ret
keyboard_translate_dead:
        ld      a,09fh
        ret

; Input C=key. Carry set with D=normal and E=SHIFT defaults.
keyboard_default_lookup:
        ld      hl,key_defaults
keyboard_default_lookup_next:
        ld      a,(hl)
        cp      0ffh
        jr      z,keyboard_default_lookup_missing
        cp      c
        jr      z,keyboard_default_lookup_found
        inc     hl
        inc     hl
        inc     hl
        jr      keyboard_default_lookup_next
keyboard_default_lookup_found:
        inc     hl
        ld      d,(hl)
        inc     hl
        ld      e,(hl)
        scf
        ret
keyboard_default_lookup_missing:
        or      a
        ret

; Read one caller byte through IX while the hidden native module owns the low
; 48K. TPA physical pages 4..6 are temporarily exposed through F2; common
; addresses C000h..FFFFh remain directly visible.
keyboard_read_caller_byte:
        push    ix
        pop     hl
        ld      a,h
        cp      0c0h
        jr      nc,keyboard_read_caller_direct
        ld      b,a
        and     0c0h
        rlca
        rlca
        add     a,084h
        out     (0f2h),a
        ld      a,b
        and     03fh
        or      080h
        ld      h,a
keyboard_read_caller_direct:
        ld      a,(hl)
        inc     ix
        ret

; Public XBIOS keyboard handlers. Register preservation follows the published
; service contracts, and every exit leaves native physical page 2 in F2.
keyboard_userf_set_expand:
        push    ix
        ld      a,b
        cp      080h
        jr      c,keyboard_set_expand_bad
        cp      09fh
        jr      nc,keyboard_set_expand_bad
        sub     080h
        ld      (keyboard_set_index),a
        push    hl
        pop     ix
        ld      e,a
        ld      d,0
        ld      a,c
        cp      129
        jr      c,keyboard_set_expand_short
        ld      a,(keyboard_long_expansion_index)
        cp      0ffh
        jr      z,keyboard_set_expand_take_long
        cp      e
        jr      nz,keyboard_set_expand_bad
keyboard_set_expand_take_long:
        ld      a,e
        ld      (keyboard_long_expansion_index),a
        jr      keyboard_set_expand_capacity_ok
keyboard_set_expand_short:
        ld      a,(keyboard_long_expansion_index)
        cp      e
        jr      nz,keyboard_set_expand_capacity_ok
        ld      a,0ffh
        ld      (keyboard_long_expansion_index),a
keyboard_set_expand_capacity_ok:
        ld      hl,keyboard_expansion_lengths
        add     hl,de
        ld      (hl),c
        ld      a,(keyboard_expansion_active)
        cp      e
        jr      nz,keyboard_set_expand_active_ok
        ld      a,0ffh
        ld      (keyboard_expansion_active),a
keyboard_set_expand_active_ok:
        ld      a,e
        call    keyboard_expansion_address
        ex      de,hl
        ld      b,c
        ld      a,b
        or      a
        jr      z,keyboard_set_expand_done
keyboard_set_expand_copy:
        push    bc
        call    keyboard_read_caller_byte
        pop     bc
        ld      (de),a
        inc     de
        djnz    keyboard_set_expand_copy
keyboard_set_expand_done:
        ld      a,082h
        out     (0f2h),a
        pop     ix
        scf
        ret
keyboard_set_expand_bad:
        pop     ix
        or      a
        ret

keyboard_userf_set_key:
        push    bc
        push    de
        ld      a,c
        cp      81
        jr      nc,keyboard_set_key_done
        ld      a,b
        ld      (keyboard_set_character),a
        ld      a,d
        and     01fh
        ld      (keyboard_set_bitmap),a
        ld      l,c
        ld      h,0
        ld      de,keyboard_override_valid
        add     hl,de
        or      (hl)
        ld      (hl),a
        ld      l,c
        ld      h,0
        ld      d,h
        ld      e,l
        add     hl,hl
        add     hl,hl
        add     hl,de
        ld      de,keyboard_override_values
        add     hl,de
        ld      b,5
keyboard_set_key_state:
        ld      a,(keyboard_set_bitmap)
        rra
        ld      (keyboard_set_bitmap),a
        jr      nc,keyboard_set_key_next
        ld      a,(keyboard_set_character)
        ld      (hl),a
keyboard_set_key_next:
        inc     hl
        djnz    keyboard_set_key_state
keyboard_set_key_done:
        pop     de
        pop     bc
        ret

keyboard_userf_get:
        push    de
        push    hl
        call    keyboard_raw_event
        jr      nc,keyboard_userf_get_none
        pop     hl
        pop     de
        scf
        ret
keyboard_userf_get_none:
        pop     hl
        pop     de
        or      a
        ret

keyboard_userf_put:
        ld      a,b
        and     004h
        ld      (keyboard_caps_lock),a
        ld      a,b
        and     010h
        ld      (keyboard_num_lock),a
        ld      a,c
        cp      81
        ret     nc
        ld      (keyboard_injected_key),a
        ld      a,b
        and     0bfh
        ld      e,a
        ld      a,(keyboard_shift_lock)
        or      a
        jr      z,keyboard_userf_put_ready
        set     6,e
keyboard_userf_put_ready:
        ld      a,e
        ld      (keyboard_injected_shifts),a
        ret

keyboard_userf_set_speed:
        ld      a,h
        ld      (keyboard_repeat_initial),a
        ld      a,l
        ld      (keyboard_repeat_delay),a
        jp      native_userf_restore_af

; CP/M Plus BDOS Function 1 fits in the remaining page-one keyboard-runtime
; hole. Keeping it here is important: growing the later runtime would move
; mutable keyboard storage into a different part of PCW display memory.
native_console_input_pause:
        call    native_getc
        cp      17
        jr      nz,native_console_input_pause
native_console_input_result:
.read:
        ; native_getc returns the character in both A and B.
        call    native_getc
        ld      a,(OPENPCW_COMMON_SCB+033h)
        bit     1,a
        jr      nz,.deliver
        ld      a,b
        cp      19
        jr      z,native_console_input_pause
        cp      17
        jr      z,.read
        cp      16
        jr      nz,.deliver
        ld      hl,OPENPCW_COMMON_SCB+038h
        ld      a,(hl)
        xor     1
        ld      (hl),a
        jr      .read
.deliver:
        ld      a,b
        cp      32
        jr      nc,.printable
        sub     8
        cp      3
        jr      c,.echo
        cp      5
        jr      z,.echo
        jr      .return
.printable:
        cp      127
        jr      nc,.return
.echo:
        push    bc
        call    native_putc
        pop     bc
.return:
        ld      a,b
        jp      native_console_result_a_hl

keyboard_scan_shifts: db 0
keyboard_translation_state: db 0
keyboard_set_index: db 0
keyboard_set_character: db 0
keyboard_set_bitmap: db 0
keyboard_expansion_active: db 0ffh
keyboard_expansion_position: db 0
keyboard_long_expansion_index: db 0ffh
endm

; Assemble the keyboard runtime into the physical page-one hole formerly
; occupied by the font bitmap, then resume the ordinary page-one stream after
; the immutable keyboard tables above. A hard assertion prevents it from
; silently colliding with those tables.
        org     04000h
        keyboard_runtime_blob
    if $ > 04400h
        .error  "keyboard runtime exceeds physical page-one hole"
    endif
        org     keyboard_runtime_continuation

; Function 28 is process-visible policy, not a controller write-protect bit.
; Reject every M: directory/data mutation before it can perform partial work,
; and publish physical error 2 through the ordinary result tail. The caller
; has restored this page after reading the TPA FCB. A protected path removes
; our own CALL return before entering the normal status tail, whose RET must
; go directly back to the resident common-bank bridge.
native_reject_read_only_mutation:
        ld      a,(m_function)
        ld      hl,.drive_mutation_functions
        ld      b,.drive_mutation_functions_end-.drive_mutation_functions
.mutation_scan:
        cp      (hl)
        jr      z,.mutation_check_drive
        inc     hl
        djnz    .mutation_scan
        or      a
        ret
.mutation_check_drive:
        ld      hl,(OPENPCW_COMMON_RO_VECTOR)
        bit     4,h                     ; M: is drive twelve
        jr      z,.mutation_check_file
        ld      a,2
        ld      (native_physical_error_code),a
        jp      native_protected_mutation_error
.mutation_check_file:
        call    native_file_mutation_requested
        ret     nz
        call    native_reject_interface_read_only
        jp      nz,native_read_only_file_error
        call    native_mutation_is_xfcb
        ret     nz
        jp      native_scan_m_read_only_file
.drive_mutation_functions:
        db      19,21,22,23,30,34,40,99,100
.drive_mutation_functions_end:

; A read-only file is a distinct CP/M Plus physical error (H=3), and only
; these six functions publish it. In particular Function 30 must remain able
; to clear t1'. Scan before any data or directory write, making an ambiguous
; delete atomic when one of several matches is protected.
native_reject_a_read_only_mutation:
        call    native_file_mutation_requested
        ret     nz
        call    native_reject_interface_read_only
        jp      nz,native_read_only_file_error
        call    native_mutation_is_xfcb
        ret     nz
        call    disk_login
        ret     c
        xor     a
        ld      (a_dir_sector),a
.a_read_only_sector:
        ld      a,(a_dir_sector)
        ld      c,a
        ld      a,(disk_dir_sectors)
        cp      c
        ret     z
        call    a_directory_sector_address
        call    read_logical_sector
        ret     c
        ld      ix,sector_buffer
        ld      b,16
.a_read_only_entry:
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        cp      (ix+0)
        jr      nz,.a_read_only_advance
        push    bc
        ld      a,(m_function)
        cp      19
        jr      nz,.a_read_only_exact
        call    a_entry_name_pattern
        jr      .a_read_only_tested
.a_read_only_exact:
        call    a_entry_name_exact
.a_read_only_tested:
        pop     bc
        jr      nz,.a_read_only_advance
        bit     7,(ix+9)
        jp      nz,native_read_only_file_error
.a_read_only_advance:
        ld      de,32
        add     ix,de
        djnz    .a_read_only_entry
        ld      a,(a_dir_sector)
        inc     a
        ld      (a_dir_sector),a
        jr      .a_read_only_sector

native_scan_m_read_only_file:
        ld      a,SPARSE_METADATA_PAGE
        out     (0f2h),a
        ld      ix,SPARSE_DIRECTORY_F2_BASE
        ld      b,128
.m_read_only_entry:
        ld      a,(m_match_user)
        cp      (ix+0)
        jr      nz,.m_read_only_advance
        push    bc
        push    ix
        pop     hl
        inc     hl
        ld      de,m_name
        ld      b,11
.m_read_only_name:
        ld      a,(de)
        cp      '?'
        jr      nz,.m_read_only_compare
        ld      a,(m_function)
        cp      19
        jr      z,.m_read_only_next_byte
        ld      a,'?'
.m_read_only_compare:
        cp      (hl)
        jr      nz,.m_read_only_different
.m_read_only_next_byte:
        inc     de
        inc     hl
        djnz    .m_read_only_name
        pop     bc
        bit     4,(ix+12)                ; private t1' read-only bit
        jr      nz,.m_read_only_error
        jr      .m_read_only_advance
.m_read_only_different:
        pop     bc
.m_read_only_advance:
        ld      de,16
        add     ix,de
        djnz    .m_read_only_entry
        ld      a,082h
        out     (0f2h),a
        ret
.m_read_only_error:
        ld      a,082h
        out     (0f2h),a
native_read_only_file_error:
        ld      a,3
        ld      (native_physical_error_code),a
native_protected_mutation_error:
        pop     hl
        ld      a,0ffh
        jp      native_m_status_result

native_file_mutation_requested:
        ld      a,(m_function)
        ld      hl,.file_mutation_functions
        ld      b,.file_mutation_functions_end-.file_mutation_functions
.file_mutation_scan:
        cp      (hl)
        jr      z,.file_mutation_yes
        inc     hl
        djnz    .file_mutation_scan
        ld      a,1
        or      a
        ret
.file_mutation_yes:
        xor     a
        ret
.file_mutation_functions:
        db      19,21,23,34,40,99
.file_mutation_functions_end:

; f7'/f8' are activated-FCB write locks (password/write mode and USER 0 SYS
; fallback respectively). This page-one policy code reads the caller through
; the disposable F2 window so it never pages out the code currently executing.
native_reject_interface_read_only:
        ld      hl,(m_fcb)
        ld      de,7
        add     hl,de
        call    line_read_guest
        and     080h
        ret     nz
        ld      hl,(m_fcb)
        ld      de,8
        add     hl,de
        call    line_read_guest
        and     080h
        ret

; Function 15 is sizeable enough to live in a separately loaded physical-page
; overlay.  Defining it as a macro here keeps its source beside the filesystem
; implementation; the single invocation after the ordinary kernel image emits
; it at logical 8000h in physical block three.
macro native_open_overlay_blob

; Block-three Open helpers ------------------------------------------------
;
; The overlay executes through F2. Access the transient through F1, then put
; native page one back before any helper there is called. Both wrappers retain
; the caller's logical FCB pointer.
native_open_tpa_read:
        call    gencom_tpa_read
        push    af
        ld      a,OPENPCW_RUNTIME_PAGE
        out     (0f1h),a
        pop     af
        ret

native_open_tpa_write:
        call    gencom_tpa_write
        push    af
        ld      a,OPENPCW_RUNTIME_PAGE
        out     (0f1h),a
        pop     af
        ret

; A successful Function 15 replaces f5'..f8'. A failed Open leaves the
; caller's interface bits untouched. USER-0 SYS fallback is the sole output
; which reactivates f8' after the successful clear.
native_open_clear_interfaces:
        ld      hl,(m_fcb)
        ld      de,5
        add     hl,de
        ld      b,4
.open_clear_interface:
        call    native_open_tpa_read
        and     07fh
        call    native_open_tpa_write
        inc     hl
        djnz    .open_clear_interface
        ld      a,(m_open_fallback)
        or      a
        jr      z,.open_apply_password_lock
        dec     hl
        call    native_open_tpa_read
        or      080h
        call    native_open_tpa_write
.open_apply_password_lock:
        ld      a,(m_open_password_lock)
        or      a
        ret     z
        ld      hl,(m_fcb)
        ld      de,7
        add     hl,de
        call    native_open_tpa_read
        or      080h
        jp      native_open_tpa_write

; Private M: directory byte zero stores user+1 (zero remains the free marker).
; An activated f8' FCB deliberately resolves through USER 0 for subsequent
; reads; Open itself has just cleared f8' and therefore starts at current user.
m_select_fcb_user:
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        inc     a
        ld      (m_match_user),a
        ld      hl,(m_fcb)
        ld      de,8
        add     hl,de
        call    native_open_tpa_read
        and     080h
        ret     z
        ld      a,1
        ld      (m_match_user),a
        ret

native_open_prepare_overlay:
        ld      a,(m_function)
        cp      15
        jp      nz,m_select_fcb_user
        ; Open treats f5'..f8' as output-only interface bits. Select the
        ; current user without consuming a stale caller-supplied f8'.
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        inc     a
        ld      (m_match_user),a
        ret

; Find m_name in the selected private M: user area. The entry's persistent
; attributes and byte count are saved before private metadata is unmapped.
m_open_find:
        ld      a,SPARSE_METADATA_PAGE
        out     (0f1h),a
        ld      ix,SPARSE_DIRECTORY_BASE
        ld      c,0
.m_open_find_next:
        ld      a,(m_match_user)
        cp      (ix+0)
        jr      nz,.m_open_find_advance
        push    bc
        push    ix
        pop     hl
        inc     hl
        ld      de,m_name
        ld      b,11
.m_open_find_name:
        ld      a,(de)
        cp      (hl)
        jr      nz,.m_open_find_different
        inc     de
        inc     hl
        djnz    .m_open_find_name
        pop     bc
        ld      a,c
        ld      (m_slot),a
        ld      a,(ix+12)
        ld      (m_open_attributes),a
        ld      a,(ix+13)
        ld      (m_open_byte_count),a
        ld      a,(ix+14)
        ld      (m_open_password_mode),a
        ld      a,(ix+15)
        ld      (m_open_password_valid),a
        ld      a,OPENPCW_RUNTIME_PAGE
        out     (0f1h),a
        or      a
        ret
.m_open_find_different:
        pop     bc
.m_open_find_advance:
        ld      de,16
        add     ix,de
        inc     c
        ld      a,c
        cp      128
        jr      c,.m_open_find_next
        ld      a,OPENPCW_RUNTIME_PAGE
        out     (0f1h),a
        scf
        ret

; Compute max(record)+1 for the selected private slot without paging out this
; page-one routine. native_size_consider_candidate is mapping-independent.
m_open_compute_size:
        call    sparse_compute_slot_size
        ld      a,OPENPCW_RUNTIME_PAGE
        out     (0f1h),a
        ld      a,(native_size_found)
        or      a
        ret     z
        ld      hl,(native_size)
        inc     hl
        ld      (native_size),hl
        ret     nz
        ld      a,(native_size+2)
        inc     a
        ld      (native_size+2),a
        ret

; Standalone M: Function 15. The private sparse representation is materialised
; as a normal activated FCB, including extent/count, attributes and CR=FF byte
; count. USER 0 fallback is accepted only for a t2' SYS file and sets f8'.
m_open_page_one:
        xor     a
        ld      (m_open_password_lock),a
        call    a_name_is_exact
        jr      nc,.m_open_exact
        ld      a,9
        ld      (native_physical_error_code),a
        ld      a,0ffh
        ret
.m_open_exact:
        ld      hl,(m_fcb)
        ld      de,32
        add     hl,de
        call    native_open_tpa_read
        cp      0ffh
        ld      a,0
        jr      nz,.m_open_request_ready
        inc     a
.m_open_request_ready:
        ld      (m_open_byte_request),a
        ld      hl,(m_fcb)
        ld      de,12
        add     hl,de
        call    native_open_tpa_read
        and     01fh
        ld      (m_open_ex),a
        ; Function 15 takes input only through EX (byte 12). S1 and S2 are
        ; reserved internal fields and are replaced when the FCB is activated.
        xor     a
        ld      (m_open_s2),a

        call    m_open_find
        jr      nc,.m_open_found
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        jp      z,.m_open_missing
        ld      a,1
        ld      (m_match_user),a
        call    m_open_find
        jp      c,.m_open_missing
        ld      a,(m_open_attributes)
        and     020h                   ; t2' SYS
        jp      z,.m_open_missing
        ld      a,1
        ld      (m_open_fallback),a
        jr      .m_open_have_user
.m_open_found:
        xor     a
        ld      (m_open_fallback),a
.m_open_have_user:
        call    m_open_password_gate_overlay
        jp      nz,.m_open_missing
        call    m_open_compute_size

        ; M: uses 2 KiB blocks (EXM=1). Normalize the requested EX/S2 to the
        ; even raw extent which owns this 256-record directory group.
        ld      a,(m_open_s2)
        ld      l,a
        ld      h,0
        ld      b,5
.m_open_extent_shift:
        add     hl,hl
        djnz    .m_open_extent_shift
        ld      a,(m_open_ex)
        ld      e,a
        ld      d,0
        add     hl,de
        res     0,l
        ld      (m_open_extent),hl
        xor     a
        ld      b,7
.m_open_record_shift:
        add     hl,hl
        rla
        djnz    .m_open_record_shift
        ld      (m_record),hl
        ld      (m_record+2),a

        ld      hl,(native_size)
        ld      a,h
        or      l
        ld      a,(native_size+2)
        jr      nz,.m_open_nonempty
        or      a
        jr      nz,.m_open_nonempty
        ld      hl,(m_record)
        ld      a,h
        or      l
        ld      a,(m_record+2)
        or      a
        jp      nz,.m_open_missing
        ld      hl,0
        jr      .m_open_records_ready
.m_open_nonempty:
        call    m_target_below_native_size
        jp      c,.m_open_missing
        ld      hl,(native_size)
        ld      de,(m_record)
        or      a
        sbc     hl,de
        ld      a,(native_size+2)
        ld      e,a
        ld      a,(m_record+2)
        ld      d,a
        ld      a,e
        sbc     a,d
        or      a
        jr      nz,.m_open_records_cap
        ld      a,h
        or      a
        jr      z,.m_open_records_ready
        cp      1
        jr      nz,.m_open_records_cap
        ld      a,l
        or      a
        jr      z,.m_open_records_ready
.m_open_records_cap:
        ld      hl,256
.m_open_records_ready:
        ld      (m_open_records),hl

        ; Replace the complete directory-owned portion of the FCB.
        ld      hl,(m_fcb)
        ld      de,12
        add     hl,de
        ld      b,20
        xor     a
.m_open_clear_metadata:
        call    native_open_tpa_write
        inc     hl
        djnz    .m_open_clear_metadata
        call    m_open_fill_allocations

        ; Copy the exact low 8.3 name and materialise the seven persistent
        ; attribute bits. Interface bits stay clear until optional f8' below.
        ld      de,m_name
        ld      hl,(m_fcb)
        inc     hl
        ld      b,11
        ld      a,1
        ld      (m_open_field),a
.m_open_name_byte:
        ld      a,(de)
        ld      (m_open_name_value),a
        ld      a,(m_open_field)
        cp      5
        jr      c,.m_open_attribute_byte
        cp      9
        jr      c,.m_open_name_write
.m_open_attribute_byte:
        ld      a,(m_open_attributes)
        rrca
        ld      (m_open_attributes),a
        jr      nc,.m_open_name_write
        ld      a,(m_open_name_value)
        or      080h
        ld      (m_open_name_value),a
.m_open_name_write:
        ld      a,(m_open_name_value)
        call    native_open_tpa_write
        inc     de
        inc     hl
        ld      a,(m_open_field)
        inc     a
        ld      (m_open_field),a
        djnz    .m_open_name_byte

        ; OPEN activates the logical extent requested by the caller.  The
        ; directory entry can legitimately carry the odd EXM=1 extent (for
        ; example EX=1,RC=52 for a 180-record file), but copying that EX into
        ; an FCB opened with EX=0 would make the first sequential read start
        ; at record 128.  The public directory mirror below derives its own
        ; physical extent from the complete file size.
        ld      a,(m_open_ex)
        and     01fh
        ld      hl,(m_fcb)
        ld      de,12
        add     hl,de
        call    native_open_tpa_write
        inc     hl
        ; Observable module stamp used by the PCW RAM-disc implementation.
        ld      a,2
        call    native_open_tpa_write
        inc     hl
        ld      a,(m_open_s2)
        and     03fh
        or      080h                   ; newly opened FCB is unmodified
        call    native_open_tpa_write
        inc     hl
        ld      de,(m_open_records)
        ld      a,d
        or      a
        ld      a,128
        jr      nz,.m_open_rc_write
        ld      a,e
        cp      129
        jr      c,.m_open_rc_write
        sub     128
.m_open_rc_write:
        call    native_open_tpa_write

        ld      a,(m_open_byte_request)
        or      a
        jr      z,.m_open_no_byte_count
        ld      hl,(m_fcb)
        ld      de,32
        add     hl,de
        ld      a,(m_open_byte_count)
        call    native_open_tpa_write
.m_open_no_byte_count:
.m_open_good:
        call    m_sync_public_directory_entry
        call    native_open_clear_interfaces
        xor     a
        ret
.m_open_missing:
        ld      a,0ffh
        ret

; Physical A: Function 15 uses the same public FCB contract as M:. The normal
; user is searched first; only an exact USER 0 t2' entry can satisfy fallback.
a_open:
        call    disk_login
        jp      c,.a_open_missing
        call    a_name_is_exact
        jr      nc,.a_open_exact
        ld      a,9
        ld      (native_physical_error_code),a
        ld      a,0ffh
        ret
.a_open_exact:
        ld      hl,(m_fcb)
        ld      de,32
        add     hl,de
        call    native_open_tpa_read
        cp      0ffh
        ld      a,0
        jr      nz,.a_open_request_ready
        inc     a
.a_open_request_ready:
        ld      (m_open_byte_request),a

        ; Open receives only the caller's five-bit EX request. S1/S2 are
        ; reserved internal fields and may contain arbitrary workspace bytes.
        ld      hl,(m_fcb)
        ld      de,12
        add     hl,de
        call    native_open_tpa_read
        and     01fh
        ld      l,a
        ld      h,0
        ld      a,(disk_extent_shift)
        or      a
        jr      z,.a_open_extent_ready
        ld      b,a
.a_open_extent_normalize:
        srl     h
        rr      l
        djnz    .a_open_extent_normalize
.a_open_extent_ready:
        ld      (wanted_extent),hl
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        ld      (a_find_user),a
        call    a_find_extent
        jr      nc,.a_open_current
        ld      a,(native_physical_error_code)
        or      a
        jp      nz,.a_open_missing
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        jp      z,.a_open_missing
        xor     a
        ld      (a_find_user),a
        call    a_find_extent
        jp      c,.a_open_missing
        bit     7,(ix+10)               ; t2' SYS
        jp      z,.a_open_missing
        ld      a,1
        ld      (m_open_fallback),a
        jr      .a_open_found
.a_open_current:
        xor     a
        ld      (m_open_fallback),a
.a_open_found:
        ld      a,(ix+13)
        ld      (m_open_byte_count),a
        call    a_save_entry_location
        call    a_open_password_gate_overlay
        jp      nz,.a_open_missing
        call    a_restore_entry_location
        call    a_directory_sector_address
        call    read_logical_sector
        jp      c,.a_open_missing
        call    a_index_to_ix

        ; Copy the directory name/type, masking the four interface attributes,
        ; followed by all twenty directory-owned extent/allocation bytes.
        push    ix
        pop     de
        inc     de
        ld      hl,(m_fcb)
        inc     hl
        ld      b,11
        ld      a,1
        ld      (m_open_field),a
.a_open_name:
        ld      a,(de)
        push    af
        ld      a,(m_open_field)
        cp      5
        jr      c,.a_open_name_attribute
        cp      9
        jr      nc,.a_open_name_attribute
        pop     af
        and     07fh
        jr      .a_open_name_write
.a_open_name_attribute:
        pop     af
.a_open_name_write:
        call    native_open_tpa_write
        inc     de
        inc     hl
        ld      a,(m_open_field)
        inc     a
        ld      (m_open_field),a
        djnz    .a_open_name

        push    ix
        pop     de
        ld      bc,12
        ex      de,hl
        add     hl,bc
        ex      de,hl
        ld      hl,(m_fcb)
        add     hl,bc
        ld      b,20
.a_open_metadata:
        ld      a,(de)
        call    native_open_tpa_write
        inc     de
        inc     hl
        djnz    .a_open_metadata

        ; Activate the physical-disc FCB exactly as the resident read path
        ; does: S1 carries the PCW module stamp and S2 bit 7 starts set until
        ; a write changes directory-owned state.
        ld      de,0ffedh
        add     hl,de
        ld      a,4
        call    native_open_tpa_write
        inc     hl
        call    native_open_tpa_read
        or      080h
        call    native_open_tpa_write

        ld      a,(m_open_byte_request)
        or      a
        jr      z,.a_open_no_byte_count
        ld      hl,(m_fcb)
        ld      de,32
        add     hl,de
        ld      a,(m_open_byte_count)
        call    native_open_tpa_write
.a_open_no_byte_count:
.a_open_good:
        call    native_open_clear_interfaces
        xor     a
        ret
.a_open_missing:
        ld      a,0ffh
        ret

; Read-error classification shares Function 15's permanently loaded block-3
; service page. The compact callers in resident block zero map F2 only for
; these calls and restore page two before returning to the BDOS dispatcher.
native_read_extent_status_overlay:
        xor     a
        ld      (record_mode),a
        ld      a,(native_physical_error_code)
        or      a
        jr      z,native_read_extent_logical_overlay
        ld      a,0ffh
        ret
native_read_extent_logical_overlay:
        ld      a,(m_function)
        cp      33
        ld      a,1
        ret     nz
        ld      a,(cached_entry_valid)
        dec     a                       ; existing 1 -> status 1, absent 0 -> 4
        and     3
        inc     a
        jp      native_random_failure_status_overlay

native_m_extent_status_overlay:
        ld      hl,(m_record+1)
        ld      a,h
        or      l
        jr      z,native_m_extent_unwritten_overlay
        call    native_compute_m_size
        or      a
        jr      nz,native_m_extent_missing_overlay
        ld      de,(m_record)
        ld      e,0
        ld      hl,(native_size)
        or      a
        sbc     hl,de
        ld      a,(m_record+2)
        ld      c,a
        ld      a,(native_size+2)
        sbc     a,c
        jr      c,native_m_extent_missing_overlay
        or      h
        or      l
        jr      z,native_m_extent_missing_overlay
native_m_extent_unwritten_overlay:
        ld      a,1
        jp      native_random_failure_status_overlay
native_m_extent_missing_overlay:
        ld      a,4
        ret

m_open_ex:             db 0
m_open_s2:             db 0
m_open_extent:         dw 0
m_open_records:        dw 0
m_open_byte_request:   db 0
m_open_fallback:       db 0
m_open_attributes:     db 0
m_open_byte_count:     db 0
m_open_field:          db 0
m_open_name_value:     db 0
m_open_password_lock:  db 0
m_open_password_mode:  db 0
m_open_password_valid: db 0
m_password_checksum:   db 0
m_password_byte:       db 0
m_xfcb_mode:           db 0

endm

; f5' asks Function 19 to remove matching password XFCBs only. Skip ordinary
; read-only-file enforcement: the password preflight still runs separately.
native_mutation_is_xfcb:
        ld      a,(m_function)
        cp      19
        jr      nz,.mutation_not_xfcb
        ld      hl,(m_fcb)
        ld      de,5
        add     hl,de
        call    line_read_guest
        and     080h
        ret
.mutation_not_xfcb:
        xor     a
        ret

; Publish the conventional FC00h BOOT..USERF table for every transient, not
; only GENCOM containers. Plain PCW loaders legitimately call FC5Ah directly.
; This initialization-only routine lives in native page one to leave page
; zero available to filesystem code used while the caller occupies F1/F2.
native_publish_bios_aliases:
        ld      hl,0fc00h
        ld      de,0fc5dh
        ld      (hl),0c3h              ; BOOT aliases the resident WBOOT
        inc     hl
        ld      (hl),e
        inc     hl
        ld      (hl),d
        inc     hl
        ld      (hl),0c3h              ; WBOOT uses the FCxx trampoline too
        inc     hl
        ld      (hl),e
        inc     hl
        ld      (hl),d
        inc     hl
        ld      de,0f231h              ; authored CONST..USERF source table
        ld      b,29
.alias:
        ld      (hl),0c3h
        inc     hl
        inc     de                     ; source JP low operand
        ld      a,(de)
        ld      (hl),a
        inc     hl
        inc     de
        ld      a,(de)
        ld      (hl),a
        inc     hl
        inc     de                     ; following source JP opcode
        djnz    .alias
        ret

; ---------------------------------------------------------------------------
; Banked CP/M Plus Function 10 editor
;
; This code deliberately lives in native physical page one.  The executable
; page zero is full, while the disk image still has ample native-system space.
; Page F2 is used as a temporary window onto the caller's physical TPA page;
; page F1, containing this code and the private 255-byte previous-line buffer,
; never moves.  No transient memory is reserved or stolen from the published
; F1FFh TPA ceiling.

native_read_line:
        ld      (line_buffer),de
        ld      a,d
        or      e
        ld      b,0
        jr      nz,line_read_address_ready
        ld      hl,(0f7f6h)       ; DE=0 selects initialized current DMA
        ld      (line_buffer),hl
        inc     b
line_read_address_ready:
        ld      hl,(line_buffer)
        call    line_read_guest
        or      a                 ; mx=0 is the documented one-byte buffer
        jr      nz,line_read_maximum_ready
        inc     a
line_read_maximum_ready:
        ld      (line_maximum),a
        xor     a
        ld      (line_length),a
        ld      (line_cursor),a
        call    line_publish_count
        ld      a,b
        or      a
        jr      z,line_read_keyboard
        xor     a
        ld      (line_initialized_index),a
line_read_initialized:
        ld      a,(line_maximum)
        ld      b,a
        ld      a,(line_initialized_index)
        cp      b
        jr      nc,line_read_keyboard
        call    line_read_index
        or      a
        jr      z,line_read_keyboard
        call    line_process_character
        cp      0ffh
        ret     z
        or      a
        jr      nz,line_read_accepted
        ld      a,(line_initialized_index)
        inc     a
        ld      (line_initialized_index),a
        jr      line_read_initialized
line_read_keyboard:
        call    native_getc
        call    line_process_character
        cp      0ffh
        ret     z
        or      a
        jr      z,line_read_keyboard
line_read_accepted:
        xor     a
        ld      h,a
        ld      l,a
        ret

; A byte index relative to buffer+2 -> A byte.  Every access restores F2 to
; native physical page two before any keyboard or terminal routine runs.
line_read_index:
        call    line_data_address
line_read_guest:
        call    line_map_guest
        ld      a,(hl)
        ld      (OPENPCW_COMMON_TPA_BYTE),a
        ld      a,082h
        out     (0f2h),a
        ld      a,(OPENPCW_COMMON_TPA_BYTE)
        ret

; A=index, C=value.
line_write_index:
        call    line_data_address
line_write_guest:
        ld      a,c
        ld      (OPENPCW_COMMON_TPA_BYTE),a
        call    line_map_guest
        ld      a,(OPENPCW_COMMON_TPA_BYTE)
        ld      (hl),a
        ld      a,082h
        out     (0f2h),a
        ret

line_data_address:
        ld      e,a
        ld      d,0
        ld      hl,(line_buffer)
        inc     hl
        inc     hl
        add     hl,de
        ret

; Map the caller page containing HL at logical 8000h-BFFFh. Common-memory
; addresses remain directly visible through physical page seven.
line_map_guest:
        ld      a,h
        cp      0c0h
        ret     nc
        and     0c0h
        rlca
        rlca
        add     a,084h
        out     (0f2h),a
        ld      a,h
        and     03fh
        or      080h
        ld      h,a
        ret

line_publish_count:
        ld      hl,(line_buffer)
        inc     hl
        ld      a,(line_length)
        ld      c,a
        jp      line_write_guest

; A is a logical-character count. ESC D/C are non-destructive cursor moves;
; the terminal's ordinary BS intentionally erases and cannot be used here.
line_move_left:
        ld      (line_move_count),a
line_move_left_again:
        ld      a,(line_move_count)
        or      a
        ret     z
        ld      a,27
        call    native_putc
        ld      a,'D'
        call    native_putc
        ld      a,(line_move_count)
        dec     a
        ld      (line_move_count),a
        jr      line_move_left_again

line_move_right:
        ld      (line_move_count),a
line_move_right_again:
        ld      a,(line_move_count)
        or      a
        ret     z
        ld      a,27
        call    native_putc
        ld      a,'C'
        call    native_putc
        ld      a,(line_move_count)
        dec     a
        ld      (line_move_count),a
        jr      line_move_right_again

line_echo_byte:
        cp      32
        jr      c,line_echo_control
        cp      127
        jp      nz,native_putc
        ld      a,'?'
        jr      line_echo_caret
line_echo_control:
        add     a,'@'
line_echo_caret:
        ld      (OPENPCW_COMMON_TPA_BYTE),a
        ld      a,'^'
        call    native_putc
        ld      a,(OPENPCW_COMMON_TPA_BYTE)
        jp      native_putc

; Redraw from the current logical cursor and restore the physical cursor.
; line_old_length describes the pre-edit tail that may need blanking.
line_refresh_tail:
        ld      a,(line_cursor)
        ld      (line_index),a
line_refresh_draw:
        ld      a,(line_index)
        ld      b,a
        ld      a,(line_length)
        cp      b
        jr      z,line_refresh_erase
        ld      a,b
        call    line_read_index
        call    line_echo_byte
        ld      a,(line_index)
        inc     a
        ld      (line_index),a
        jr      line_refresh_draw
line_refresh_erase:
        ld      a,(line_old_length)
        ld      b,a
        ld      a,(line_length)
        cp      b
        jr      nc,line_refresh_move_new_tail
        ld      a,b
        ld      b,a
        ld      a,(line_length)
        ld      c,a
        ld      a,b
        sub     c
        ld      (line_move_count),a
line_refresh_blank:
        ld      a,(line_move_count)
        or      a
        jr      z,line_refresh_move_old_tail
        ld      a,' '
        call    native_putc
        ld      a,(line_move_count)
        dec     a
        ld      (line_move_count),a
        jr      line_refresh_blank
line_refresh_move_old_tail:
        ld      a,(line_old_length)
        ld      b,a
        ld      a,(line_cursor)
        ld      c,a
        ld      a,b
        sub     c
        jp      line_move_left
line_refresh_move_new_tail:
        ld      a,(line_length)
        ld      b,a
        ld      a,(line_cursor)
        ld      c,a
        ld      a,b
        sub     c
        jp      line_move_left

line_save_previous:
        ld      (line_previous_length),a
        xor     a
        ld      (line_index),a
line_save_previous_copy:
        ld      a,(line_index)
        ld      b,a
        ld      a,(line_previous_length)
        cp      b
        ret     z
        ld      a,b
        call    line_read_index
        ld      c,a
        ld      a,(line_index)
        ld      e,a
        ld      d,0
        ld      hl,line_previous
        add     hl,de
        ld      (hl),c
        ld      a,(line_index)
        inc     a
        ld      (line_index),a
        jr      line_save_previous_copy

line_insert_character:
        ld      (line_character),a
        ld      a,(line_maximum)
        ld      b,a
        ld      a,(line_length)
        cp      b
        jr      c,line_insert_space
        ld      a,7
        call    native_putc
        xor     a
        ret
line_insert_space:
        ld      (line_old_length),a
        ld      (line_index),a
line_insert_shift:
        ld      a,(line_index)
        ld      b,a
        ld      a,(line_cursor)
        cp      b
        jr      z,line_insert_store
        ld      a,b
        dec     a
        call    line_read_index
        ld      c,a
        ld      a,(line_index)
        call    line_write_index
        ld      a,(line_index)
        dec     a
        ld      (line_index),a
        jr      line_insert_shift
line_insert_store:
        ld      a,(line_character)
        ld      c,a
        ld      a,(line_cursor)
        call    line_write_index
        ld      a,(line_length)
        inc     a
        ld      (line_length),a
        call    line_publish_count
        call    line_refresh_tail
        ld      a,1
        call    line_move_right
        ld      a,(line_cursor)
        inc     a
        ld      (line_cursor),a
        xor     a
        ret

line_delete_character:
        ld      a,(line_cursor)
        ld      b,a
        ld      a,(line_length)
        cp      b
        ret     z
        ld      (line_old_length),a
        ld      a,b
        ld      (line_index),a
line_delete_shift:
        ld      a,(line_index)
        inc     a
        ld      b,a
        ld      a,(line_length)
        cp      b
        jr      c,line_delete_shorten
        ld      a,b
        call    line_read_index
        ld      c,a
        ld      a,(line_index)
        call    line_write_index
        ld      a,(line_index)
        inc     a
        ld      (line_index),a
        jr      line_delete_shift
line_delete_shorten:
        ld      a,(line_length)
        dec     a
        ld      (line_length),a
        call    line_publish_count
        call    line_refresh_tail
        xor     a
        ret

; A=character. Return zero to continue, one to accept, or FFh to warm boot.
line_process_character:
        ld      (line_character),a
        cp      13
        jp      z,line_accept
        cp      10
        jp      z,line_accept
        cp      1
        jp      z,line_process_left
        cp      2
        jp      z,line_process_toggle
        cp      3
        jp      z,line_process_control_c
        cp      5
        jp      z,line_process_physical_end
        cp      6
        jp      z,line_process_right
        cp      7
        jp      z,line_delete_character
        cp      8
        jp      z,line_process_delete_left
        cp      127
        jp      z,line_process_delete_left
        cp      11
        jp      z,line_process_delete_right
        cp      16
        jp      z,line_process_consumed
        cp      18
        jp      z,line_process_retype
        cp      21
        jp      z,line_process_clear_line
        cp      23
        jp      z,line_process_recall
        cp      24
        jp      z,line_process_delete_left_half
        ld      a,(line_character)
        jp      line_insert_character
line_process_left:
        ld      a,(line_cursor)
        or      a
        jp      z,line_process_consumed
        dec     a
        ld      (line_cursor),a
        ld      a,1
        call    line_move_left
        jp      line_process_consumed
line_process_toggle:
        ld      a,(line_cursor)
        or      a
        jr      z,line_process_toggle_end
        call    line_move_left
        xor     a
        ld      (line_cursor),a
        ret
line_process_toggle_end:
        ld      a,(line_length)
        call    line_move_right
        ld      a,(line_length)
        ld      (line_cursor),a
        xor     a
        ret
line_process_control_c:
        ld      a,(line_length)
        or      a
        jr      nz,line_process_insert_saved
        ld      a,(0f81bh+033h)
        and     8
        jr      nz,line_process_insert_saved
        ld      a,0ffh
        ret
line_process_insert_saved:
        ld      a,(line_character)
        jp      line_insert_character
line_process_physical_end:
        ld      a,13
        call    native_putc
        ld      a,10
        call    native_putc
        ld      a,(line_cursor)
        ld      (line_index),a
line_process_physical_tail:
        ld      a,(line_index)
        ld      b,a
        ld      a,(line_length)
        cp      b
        jr      z,line_process_physical_done
        ld      a,b
        call    line_read_index
        call    line_echo_byte
        ld      a,(line_index)
        inc     a
        ld      (line_index),a
        jr      line_process_physical_tail
line_process_physical_done:
        ld      a,(line_length)
        ld      (line_cursor),a
        xor     a
        ret
line_process_right:
        ld      a,(line_cursor)
        ld      b,a
        ld      a,(line_length)
        cp      b
        jp      z,line_process_consumed
        ld      a,1
        call    line_move_right
        ld      a,(line_cursor)
        inc     a
        ld      (line_cursor),a
        jp      line_process_consumed
line_process_delete_left:
        ld      a,(line_cursor)
        or      a
        jp      z,line_process_consumed
        dec     a
        ld      (line_cursor),a
        ld      a,1
        call    line_move_left
        jp      line_delete_character
line_process_delete_right:
        ld      a,(line_length)
        ld      (line_old_length),a
        ld      a,(line_cursor)
        ld      (line_length),a
        call    line_publish_count
        call    line_refresh_tail
        jp      line_process_consumed
line_process_retype:
        ld      a,13
        call    native_putc
        ld      a,10
        call    native_putc
        xor     a
        ld      (line_index),a
line_process_retype_loop:
        ld      a,(line_index)
        ld      b,a
        ld      a,(line_cursor)
        cp      b
        jp      z,line_process_consumed
        ld      a,b
        call    line_read_index
        call    line_echo_byte
        ld      a,(line_index)
        inc     a
        ld      (line_index),a
        jr      line_process_retype_loop
line_process_clear_line:
        ld      a,(line_cursor)
        call    line_save_previous
        ld      a,(line_cursor)
        call    line_move_left
        ld      a,(line_length)
        ld      (line_move_count),a
line_process_clear_spaces:
        ld      a,(line_move_count)
        or      a
        jr      z,line_process_clear_newline
        ld      a,' '
        call    native_putc
        ld      a,(line_move_count)
        dec     a
        ld      (line_move_count),a
        jr      line_process_clear_spaces
line_process_clear_newline:
        ld      a,13
        call    native_putc
        ld      a,10
        call    native_putc
        xor     a
        ld      (line_cursor),a
        ld      (line_length),a
        call    line_publish_count
        jp      line_process_consumed
line_process_recall:
        ld      a,(line_length)
        or      a
        jr      z,line_process_recall_previous
        ld      b,a
        ld      a,(line_cursor)
        ld      c,a
        ld      a,b
        sub     c
        call    line_move_right
        ld      a,(line_length)
        ld      (line_cursor),a
        jp      line_process_consumed
line_process_recall_previous:
        ld      a,(line_previous_length)
        ld      b,a
        ld      a,(line_maximum)
        cp      b
        jr      nc,line_process_recall_length_ready
        ld      b,a
line_process_recall_length_ready:
        ld      a,b
        ld      (line_length),a
        ld      (line_cursor),a
        xor     a
        ld      (line_index),a
line_process_recall_copy:
        ld      a,(line_index)
        ld      c,a
        ld      a,(line_length)
        cp      c
        jr      z,line_process_recall_done
        ld      e,c
        ld      d,0
        ld      hl,line_previous
        add     hl,de
        ld      c,(hl)
        ld      a,(line_index)
        call    line_write_index
        ld      a,c
        call    line_echo_byte
        ld      a,(line_index)
        inc     a
        ld      (line_index),a
        jr      line_process_recall_copy
line_process_recall_done:
        call    line_publish_count
        jp      line_process_consumed
line_process_delete_left_half:
        ld      a,(line_cursor)
        or      a
        jp      z,line_process_consumed
        ld      (line_removed),a
        call    line_move_left
        ld      a,(line_length)
        ld      (line_old_length),a
        xor     a
        ld      (line_index),a
line_process_left_shift:
        ld      a,(line_index)
        ld      b,a
        ld      a,(line_removed)
        add     a,b
        ld      b,a
        ld      a,(line_length)
        cp      b
        jr      z,line_process_left_shorter
        ld      a,b
        call    line_read_index
        ld      c,a
        ld      a,(line_index)
        call    line_write_index
        ld      a,(line_index)
        inc     a
        ld      (line_index),a
        jr      line_process_left_shift
line_process_left_shorter:
        ld      a,(line_removed)
        ld      b,a
        ld      a,(line_length)
        sub     b
        ld      (line_length),a
        xor     a
        ld      (line_cursor),a
        call    line_publish_count
        call    line_refresh_tail
line_process_consumed:
        xor     a
        ret

line_accept:
        ld      a,(line_character)
        call    native_putc
        ld      a,(line_length)
        call    line_save_previous
        call    line_publish_count
        ld      a,1
        ret

line_buffer:           dw      0
line_maximum:          db      1
line_length:           db      0
line_cursor:           db      0
line_old_length:       db      0
line_index:            db      0
line_initialized_index: db     0
line_value:            db      0
line_character:        db      0
line_move_count:       db      0
line_removed:          db      0
line_previous_length:  db      0
line_previous:         defs    255,0

; Synchronous sector transfers run from physical page one.  The page-zero
; bridges select this page before jumping here, so a BIOS write may first copy
; its source out of an arbitrary TPA bank without making the controller engine
; disappear.  All buffers and mutable status remain in page zero.
fdc_read_sector_page_one:
        ; The application-facing XBIOS may leave the FDC routed to NMI or INT.
        ; This engine is deliberately synchronous, so disconnect both lines
        ; immediately before every command rather than relying on the mode
        ; selected at the last disk login.  Otherwise a program which changes
        ; the route can interrupt this private transfer halfway through.
        ld      a,4
        out     (0f8h),a
        xor     a
        ld      (sector_cache_valid),a
        ld      a,046h
        call    fdc_write
        ld      a,c
        add     a,a
        add     a,a
        call    fdc_write           ; unit/head
        ld      a,d
        call    fdc_write           ; C
        ld      a,c
        call    fdc_write           ; H
        ld      a,e
        call    fdc_write           ; R
        ld      a,2
        call    fdc_write           ; N
        ld      a,e
        call    fdc_write           ; EOT
        ld      a,02ah
        call    fdc_write           ; GPL
        ld      a,0ffh
        call    fdc_write           ; DTL
        ld      bc,0200h
.data:
        call    fdc_read_data_or_result
        jr      c,.result_status
        ld      (hl),a
        inc     hl
        dec     c
        jr      nz,.data
        djnz    .data
        call    fdc_read
.result_status:
        ld      (last_fdc_st0),a
        and     0c0h
        rlca                            ; 40h/80h EOC tuple normalises to zero
        ld      c,a
        call    fdc_read
        ld      (last_fdc_st1),a
        xor     c
        ld      c,a
        call    fdc_read
        ld      (last_fdc_st2),a
        or      c
        ld      c,a
        ld      b,4
.drain:
        call    fdc_read
        djnz    .drain
        ld      a,c
        or      a
        ret     z
        scf
        ret

fdc_write_sector_page_one:
        xor     a
        ld      (sector_cache_valid),a
        ld      a,045h
        call    fdc_write
        ld      a,c
        add     a,a
        add     a,a
        call    fdc_write           ; unit/head
        ld      a,d
        call    fdc_write           ; C
        ld      a,c
        call    fdc_write           ; H
        ld      a,e
        call    fdc_write           ; R
        ld      a,2
        call    fdc_write           ; N
        ld      a,e
        call    fdc_write           ; EOT
        ld      a,02ah
        call    fdc_write           ; GPL
        ld      a,0ffh
        call    fdc_write           ; DTL
        ld      bc,0200h
.write_data:
        ld      a,(hl)
        call    fdc_write_data_or_result
        jr      c,.write_result_status
        inc     hl
        dec     c
        jr      nz,.write_data
        djnz    .write_data
        call    fdc_read
.write_result_status:
        ld      (last_fdc_st0),a
        and     0c0h
        rlca                            ; 40h/80h EOC tuple normalises to zero
        ld      c,a
        call    fdc_read
        ld      (last_fdc_st1),a
        xor     c
        ld      c,a
        call    fdc_read
        ld      (last_fdc_st2),a
        or      c
        ld      c,a
        ld      b,4
.write_drain:
        call    fdc_read
        djnz    .write_drain
        ld      a,c
        or      a
        ret     z
        scf
        ret

fdc_write_data_or_result:
        ld      d,a                    ; D is scratch after command submission
.write_phase_wait:
        in      a,(0)
        and     0e0h
        cp      0a0h                   ; CPU -> controller data phase
        jr      z,.write_data_ready
        cp      0c0h                   ; controller -> CPU result phase
        jr      nz,.write_phase_wait
        in      a,(1)                  ; consume ST0 for the shared parser
        scf
        ret
.write_data_ready:
        ld      a,d
        out     (1),a
        ; CP A0h on the path above already cleared carry; OUT preserves flags.
        ret
        nop
        nop                             ; retain the fixed page-one ABI size

; Restore both published seven-byte drive records and program the uPD765 with
; the default A: timings. The records themselves live in common memory so a
; normal machine save state retains subsequent DD SETUP changes.
native_xbios_disk_defaults:
        ld      hl,native_disk_defaults
        ld      de,OPENPCW_COMMON_DISK_PARAMS
        ld      bc,7
        ldir
        ld      hl,OPENPCW_COMMON_DISK_PARAMS
        ld      de,OPENPCW_COMMON_DISK_PARAMS+7
        ld      bc,7
        ldir
        xor     a
        ld      (OPENPCW_COMMON_MOTOR_TICKS),a
        ld      (OPENPCW_COMMON_MOTOR_TICKS+1),a
        ld      (motor_ready),a
        ld      hl,OPENPCW_COMMON_DISK_PARAMS
        jp      native_xbios_issue_specify

; Convert the documented step time to the 765 SRT nibble. HUT is already in
; controller units and the final HLT/ND byte is explicitly pre-encoded by the
; caller. SPECIFY has command phase only and therefore needs no result drain.
native_xbios_issue_specify:
        ld      de,4
        add     hl,de
        ld      a,3                      ; uPD765 SPECIFY
        call    fdc_write
        ld      a,(hl)
        neg
        and     00fh
        rlca
        rlca
        rlca
        rlca
        ld      b,a
        inc     hl
        ld      a,(hl)
        and     00fh
        or      b
        call    fdc_write
        inc     hl
        ld      a,(hl)
        jp      fdc_write

native_xbios_disk_setup:
        ld      a,h
        or      l
        jr      z,.disk_setup_one
        call    native_xbios_parameter_pointer
        jr      c,.disk_setup_done
        ld      de,OPENPCW_COMMON_DISK_PARAMS
        ld      bc,7
        ldir
        ld      hl,OPENPCW_COMMON_DISK_PARAMS
        ld      de,OPENPCW_COMMON_DISK_PARAMS+7
        ld      bc,7
        ldir
        ld      hl,OPENPCW_COMMON_DISK_PARAMS
        call    native_xbios_issue_specify
.disk_setup_done:
        xor     a
        ret
.disk_setup_one:
        ex      de,hl                    ; modern form: DE is parameter block
        call    native_xbios_parameter_pointer
        jr      c,.disk_setup_done
        ld      a,c
        cp      2
        jr      nc,.disk_setup_done
        push    af
        or      a
        ld      de,OPENPCW_COMMON_DISK_PARAMS
        jr      z,.disk_setup_destination
        ld      de,OPENPCW_COMMON_DISK_PARAMS+7
.disk_setup_destination:
        ld      bc,7
        ldir
        pop     af
        or      a
        jr      nz,.disk_setup_done      ; B: is stored but is not installed
        ld      hl,OPENPCW_COMMON_DISK_PARAMS
        call    native_xbios_issue_specify
        jr      .disk_setup_done

native_xbios_parameter_pointer:
        ld      a,h
        cp      0c0h
        jr      c,.disk_parameter_bad
        cp      0ffh
        jr      nz,.disk_parameter_good
        ld      a,l
        cp      0fah                     ; seven bytes must not wrap at FFFFh
        jr      nc,.disk_parameter_bad
.disk_parameter_good:
        or      a
        ret
.disk_parameter_bad:
        scf
        ret

; Turn on the real motor and wait the configured number of 100ms periods only
; on the off-to-on transition. 15385 iterations of this 26-T-state loop are
; approximately one tenth of a second on a 4MHz PCW.
native_disk_motor_on:
        xor     a
        ld      (OPENPCW_COMMON_MOTOR_TICKS),a
        ld      (OPENPCW_COMMON_MOTOR_TICKS+1),a
        ld      a,9
        out     (0f8h),a
        ld      a,4
        out     (0f8h),a
        ld      a,(motor_ready)
        or      a
        ret     nz
        ld      a,(OPENPCW_COMMON_DISK_PARAMS)
        ld      b,a
        or      a
        jr      z,.motor_on_ready
.motor_tenth:
        push    bc
        ld      de,03c19h
.motor_delay:
        dec     de
        ld      a,d
        or      e
        jr      nz,.motor_delay
        pop     bc
        djnz    .motor_tenth
.motor_on_ready:
        ld      a,1
        ld      (motor_ready),a
        ret

; Convert the configured motor-off timeout from tenths to 300Hz ticks. A zero
; parameter deliberately stores zero, meaning that no automatic stop occurs.
native_disk_arm_motor_off:
        ld      a,(OPENPCW_COMMON_DISK_PARAMS+1)
        ld      l,a
        ld      h,0
        or      a
        jr      z,.motor_off_store
        add     hl,hl                    ; 2x
        ld      d,h
        ld      e,l
        add     hl,hl                    ; 4x
        add     hl,hl                    ; 8x
        add     hl,hl                    ; 16x
        add     hl,hl                    ; 32x
        or      a
        sbc     hl,de                    ; 30x = 300Hz / 10
.motor_off_store:
        ld      (OPENPCW_COMMON_MOTOR_TICKS),hl
        ret

; Public USERF/XBIOS services which do not need the special common-memory
; screen-callback trampoline. The dispatcher runs in native page one and calls
; page-zero bridges for operations which temporarily repurpose F1.
native_userf_misc:
        ld      a,(OPENPCW_COMMON_ARGUMENT_A)
        cp      080h                    ; DD INIT
        jp      z,.userf_disk_init
        cp      083h                    ; DD SETUP
        jp      z,.userf_disk_setup
        cp      086h                    ; DD READ SECTOR
        jp      z,.userf_read_sector
        cp      089h                    ; DD WRITE SECTOR
        jp      z,.userf_write_sector
        cp      08ch                    ; DD CHECK SECTOR
        jp      z,.userf_check_sector
        cp      08fh                    ; DD FORMAT
        jp      z,.userf_format_track
        cp      092h                    ; DD LOGIN
        jp      z,.userf_disk_login
        cp      095h                    ; DD SEL FORMAT
        jp      z,.userf_select_format
        cp      098h                    ; DD DRIVE STATUS
        jp      z,.userf_drive_status
        cp      09bh                    ; DD READ ID
        jp      z,native_xbios_read_id
        cp      09eh                    ; DD L DPB
        jp      z,.userf_load_dpb
        cp      0a1h                    ; DD L XDPB
        jp      z,.userf_load_xdpb
        cp      0a4h                    ; DD L ON MOTOR
        jp      z,.userf_motor_on
        cp      0a7h                    ; DD L T OFF MOTOR
        jp      z,.userf_motor_toff
        cp      0aah                    ; DD L OFF MOTOR
        jp      z,.userf_motor_off
        cp      0adh                    ; DD L READ
        jp      z,native_userf_low_read_bridge
        cp      0b0h                    ; DD L WRITE
        jp      z,native_xbios_low_write
        cp      0b3h                    ; DD L SEEK
        jp      z,.userf_seek
        cp      0b6h                    ; CD SA INIT
        jp      z,.userf_serial_init
        cp      0b9h                    ; CD SA BAUD
        jp      z,.userf_serial_baud
        cp      0bch                    ; CD SA PARAMS
        jp      z,.userf_serial_params
        cp      0bfh                    ; TE ASK
        jp      z,.userf_terminal_ask
        cp      0c2h                    ; TE RESET
        jp      z,.userf_terminal_reset
        cp      0c5h                    ; TE STATUS ASK
        jp      z,.userf_status_ask
        cp      0c8h                    ; TE STATUS ON/OFF
        jp      z,.userf_status_set
        cp      0cbh                    ; TE SET INK
        jp      z,.userf_set_ink
        cp      0ceh                    ; TE SET BORDER
        jp      z,.userf_set_border
        cp      0d1h                    ; TE SET SPEED (no colour flash)
        jp      z,native_userf_restore_af
        cp      0d4h                    ; KM SET EXPAND
        jp      z,keyboard_userf_set_expand
        cp      0d7h                    ; KM SET KEY
        jp      z,keyboard_userf_set_key
        cp      0dah                    ; KM KT GET
        jp      z,keyboard_userf_get
        cp      0ddh                    ; KM KT PUT
        jp      z,keyboard_userf_put
        cp      0e0h                    ; KM SET SPEED
        jp      z,keyboard_userf_set_speed
        cp      0e3h                    ; CD VERSION
        jp      z,.userf_version
        cp      0e6h                    ; CD INFO
        jp      z,.userf_info
        ld      a,0ffh
        ret

.userf_disk_init:
        call    native_xbios_disk_defaults
        ld      a,10                     ; PCW system command: motor off
        out     (0f8h),a
        call    native_disk_media_reset   ; DD INIT selects fresh media data
        xor     a
        ld      (motor_ready),a
        xor     a
        ret

.userf_disk_setup:
        jp      native_xbios_disk_setup

.userf_read_sector:
        xor     a                        ; transfer to the requested CP/M bank
        call    native_userf_read_bridge
        or      a
        ret     nz                       ; error: carry clear
        scf
        ret

.userf_write_sector:
        call    native_xbios_write_sector
        or      a
        ret     nz                       ; A=1 write protected, otherwise error
        scf
        ret

.userf_check_sector:
        ld      a,1                      ; compare without transferring
        call    native_userf_read_bridge
        cp      4
        jr      z,.userf_error_flags
        or      a                        ; zero reports equality
        scf
        ld      a,0
        ret
.userf_error_flags:
        or      a                        ; error: carry and zero clear
        ret

.userf_format_track:
        call    native_xbios_format_track
        or      a
        ret     nz                       ; error: carry clear
        scf
        ret

.userf_disk_login:
        call    native_userf_login_bridge
        cp      0ffh
        jr      z,.userf_login_bad
        scf
        ret
.userf_login_bad:
        ld      a,4
        or      a
        ret

.userf_select_format:
        ; Caller A, saved before USERF decoded its inline address, selects one
        ; of the four public Amstrad formats. Keep the records here rather than
        ; reading the mounted medium: this service preloads an offline XDPB.
        ld      hl,(OPENPCW_COMMON_SAVED_AF)
        ld      a,h
        cp      4
        jr      nc,.userf_bad_format
        ld      hl,userf_standard_formats
        or      a
        jr      z,.userf_select_ready
        ld      de,10
.userf_select_advance:
        add     hl,de
        dec     a
        jr      nz,.userf_select_advance
.userf_select_ready:
        ld      b,27
        jp      native_xbios_build_record

.userf_load_dpb:
        ld      b,17
        jp      native_xbios_build_record
.userf_load_xdpb:
        ld      b,27
        jp      native_xbios_build_record
.userf_bad_format:
        ld      a,6
        or      a
        ret

.userf_drive_status:
        ld      a,c
        and     3
        jr      nz,.userf_drive_absent
        ld      a,c
        and     5                        ; selected unit/head bits
        or      030h                     ; drive A ready and at track zero
        ret
.userf_drive_absent:
        ld      a,c
        and     5                        ; echo absent unit/head selection
        ret

.userf_motor_on:
        push    bc
        push    de
        push    hl
        call    native_disk_motor_on
        pop     hl
        pop     de
        pop     bc
        jp      native_userf_restore_af
.userf_motor_toff:
        push    bc
        push    de
        push    hl
        call    native_disk_arm_motor_off
        pop     hl
        pop     de
        pop     bc
        jp      native_userf_restore_af
.userf_motor_off:
        ld      a,10                     ; PCW system command: motor off
        out     (0f8h),a
        xor     a
        ld      (OPENPCW_COMMON_MOTOR_TICKS),a
        ld      (OPENPCW_COMMON_MOTOR_TICKS+1),a
        ld      (motor_ready),a
        jp      native_userf_restore_af

.userf_seek:
        ld      a,9
        out     (0f8h),a
        ld      a,4
        out     (0f8h),a
        ld      a,c
        and     3
        jr      nz,.userf_seek_bad
        ld      a,d
        call    fdc_seek
        jr      c,.userf_seek_bad
        xor     a
        scf
        ret
.userf_seek_bad:
        ld      a,2
        or      a
        ret

.userf_serial_init:
        push    hl
        ld      hl,(OPENPCW_COMMON_SAVED_AF)
        ld      a,h
        pop     hl
        or      a
        jr      z,.userf_serial_store
        cp      0fdh
        jp      c,native_userf_restore_af ; DTR/RTS command: no hardware
.userf_serial_store:
        ld      (serial_mode),a
        ld      a,d
        ld      (serial_stop_bits),a
        ld      a,e
        ld      (serial_parity),a
        ld      a,h
        ld      (serial_receive_bits),a
        ld      a,l
        ld      (serial_transmit_bits),a
        jp      native_userf_restore_af

.userf_serial_baud:
        ld      a,h
        ld      (serial_receive_baud),a
        ld      a,l
        ld      (serial_transmit_baud),a
        jp      native_userf_restore_af

.userf_serial_params:
        ld      a,(serial_receive_baud)
        ld      b,a
        ld      a,(serial_transmit_baud)
        ld      c,a
        ld      a,(serial_stop_bits)
        ld      d,a
        ld      a,(serial_parity)
        ld      e,a
        ld      a,(serial_receive_bits)
        ld      h,a
        ld      a,(serial_transmit_bits)
        ld      l,a
        ld      a,(serial_mode)
        ret

.userf_terminal_ask:
        ld      a,(terminal_view_top)
        ld      b,a
        ld      a,(terminal_view_left)
        ld      c,a
        ld      a,(terminal_bottom_row)
        sub     b
        ld      d,a
        ld      a,(terminal_view_right)
        sub     c
        ld      e,a
        ld      a,(cursor_y)
        sub     b
        ld      h,a
        ld      a,(cursor_x)
        sub     c
        ld      l,a
        jp      native_userf_restore_af

.userf_terminal_reset:
        push    bc
        push    de
        push    hl
        call    terminal_clear
        xor     a
        ld      (escape_state),a
        ld      a,30
        ld      (terminal_bottom_row),a
        ld      a,05fh
        ld      (OPENPCW_COMMON_TERMINAL_F7),a
        out     (0f7h),a
        pop     hl
        pop     de
        pop     bc
        jp      native_userf_restore_af

.userf_status_ask:
        ld      a,(terminal_bottom_row)
        cp      31
        jr      z,.userf_status_off
        ld      a,0ffh
        or      a                        ; enabled and visible: zero false
        ret
.userf_status_off:
        xor     a                        ; disabled: A=0 and zero true
        ret

.userf_status_set:
        ld      hl,(OPENPCW_COMMON_SAVED_AF)
        ld      a,h
        or      a
        jr      z,.userf_status_disable
        ld      a,30
        ld      (terminal_bottom_row),a
        ld      a,(cursor_y)
        cp      31
        jr      c,.userf_status_draw
        ld      a,30
        ld      (cursor_y),a
.userf_status_draw:
        push    bc
        push    de
        ld      b,0
        call    terminal_draw_status
        pop     de
        pop     bc
        jp      native_userf_restore_af
.userf_status_disable:
        ld      a,31
        ld      (terminal_bottom_row),a
        jp      native_status_disable_private

.userf_set_ink:
        ; Published PCW CP/M bug: B/C are discarded before examination. Both
        ; inks therefore remain zero and the monochrome display is unchanged.
        ld      bc,0
        ld      hl,(OPENPCW_COMMON_SAVED_AF)
        ld      a,h
        add     a,a                      ; internal two-byte ink record offset
        ld      h,a
        ld      l,0a8h                   ; observed public AF result
        push    hl
        pop     af
        ret

.userf_set_border:
        ld      a,b
        and     0c0h
        xor     040h                     ; B6 is active-low screen enable
        or      001h                     ; standard PCW screen-mode bits
        ld      (OPENPCW_COMMON_TERMINAL_F7),a
        out     (0f7h),a
        jp      native_userf_restore_af

.userf_version:
        ld      a,1                      ; PCW 8xxx/9xxx/10 family
        ld      b,1                      ; OpenPCW public ABI 1.0
        ld      c,0
        ld      hl,0
        ret

.userf_info:
        ld      a,(native_ram_pages)
        ld      b,a
        xor     a                        ; no second floppy drive
        ld      c,a                      ; no serial interface
        ld      d,a                      ; no drive B
        ld      e,5                      ; 3-inch SS/ST drive A
        ld      hl,0                     ; no spare-buffer table
        ret

; Public READ ID retains the controller's complete result packet. It lives in
; page one so the boot-time page-zero reader stays compact enough to preserve
; the fixed ALV addresses.
native_fdc_read_id:
        ld      a,04ah
        call    fdc_write
        ld      a,c
        and     1
        add     a,a
        add     a,a
        call    fdc_write
        call    fdc_read
        ld      (last_fdc_st0),a
        and     0c0h
        ld      b,a
        call    fdc_read
        ld      (last_fdc_st1),a
        or      b
        ld      b,a
        call    fdc_read
        ld      (last_fdc_st2),a
        or      b
        ld      b,a
        call    fdc_read
        ld      (userf_read_id_c),a
        call    fdc_read
        ld      (userf_read_id_h),a
        call    fdc_read
        ld      (userf_read_id_r),a
        call    fdc_read
        ld      (disk_sector_n),a
        ld      a,b
        or      a
        jr      nz,.public_id_error
        ld      a,(userf_read_id_r)
        ret
.public_id_error:
        scf
        ret

native_xbios_read_id:
        ld      a,d
        ld      (xbios_track),a
        ld      a,c
        and     3
        jr      nz,.read_id_bad_request
        call    disk_login
        jr      c,.read_id_bad_request
        ld      a,(xbios_track)
        ld      d,a
        ld      e,0
        call    native_map_physical_sector
        jr      c,.read_id_bad_request
        call    native_fdc_read_id
        jr      c,.read_id_controller_error
        call    native_xbios_publish_id_result
        ld      a,(userf_read_id_r)
        scf
        ret
.read_id_bad_request:
        ld      a,040h
        ld      (last_fdc_st0),a
        ld      a,4
        ld      (last_fdc_st1),a
        xor     a
        ld      (last_fdc_st2),a
        ld      a,(xbios_track)
        ld      (userf_read_id_c),a
        xor     a
        ld      (userf_read_id_h),a
        ld      (userf_read_id_r),a
        ld      (disk_sector_n),a
.read_id_controller_error:
        call    native_xbios_publish_id_result
        ld      a,4
        or      a
        ret

native_xbios_publish_id_result:
        ld      hl,0ffe0h
        ld      (hl),7
        inc     hl
        ld      a,(last_fdc_st0)
        ld      (hl),a
        inc     hl
        ld      a,(last_fdc_st1)
        ld      (hl),a
        inc     hl
        ld      a,(last_fdc_st2)
        ld      (hl),a
        inc     hl
        ld      a,(userf_read_id_c)
        ld      (hl),a
        inc     hl
        ld      a,(userf_read_id_h)
        ld      (hl),a
        inc     hl
        ld      a,(userf_read_id_r)
        ld      (hl),a
        inc     hl
        ld      a,(disk_sector_n)
        ld      (hl),a
        ld      hl,0ffe0h
        ret

userf_read_id_c:
        db      0
userf_read_id_h:
        db      0
userf_read_id_r:
        db      0
xbios_format_fill:
        db      0
xbios_format_n:
        db      2
xbios_format_sectors:
        db      9
xbios_format_gap:
        db      052h
xbios_format_cylinder:
        db      0
xbios_format_side:
        db      0
low_scan_relation:
        db      0
low_scan_disk_byte:
        db      0
low_scan_memory_byte:
        db      0
low_scan_st2:
        db      0

; Read one address in the published CP/M system bank without replacing page
; one, where this routine executes. F2 is the disposable window and the data
; bank selected by DD FORMAT is restored before returning.
xbios_cpm_read_bank0_f2:
        push    de
        ld      a,(xbios_bank)
        push    af
        xor     a
        ld      (xbios_bank),a
        call    xbios_cpm_read_f2
        ld      d,a
        pop     af
        ld      (xbios_bank),a
        ld      a,d
        pop     de
        ret

; DD FORMAT streams the caller's C/H/R/N list to a real uPD765 FORMAT TRACK
; command. It therefore behaves identically under emulation and on physical
; PCW hardware, while accepting the list from either documented CP/M bank.
native_xbios_format_track:
        ld      a,c
        and     3
        jp      nz,.format_no_data
        ld      a,b
        cp      2
        jp      nc,.format_no_data
        ld      (xbios_bank),a
        ld      a,d
        ld      (xbios_track),a
        ld      a,e
        ld      (xbios_format_fill),a
        ld      (xbios_destination),hl

        ; The XDPB belongs to system bank zero even when the sector-ID list is
        ; in bank one. Validate the full 27-byte object before dereferencing.
        push    ix
        pop     hl
        ld      de,27
        add     hl,de
        jp      c,.format_bad
        call    disk_login
        jp      c,.format_no_data

        push    ix
        pop     hl
        ld      de,15
        add     hl,de
        call    xbios_cpm_read_bank0_f2  ; physical-sector shift / FDC N
        cp      7
        jp      nc,.format_bad
        ld      (xbios_format_n),a
        ld      b,a
        ld      a,(disk_sector_n)
        cp      b
        jp      nz,.format_bad
        ld      de,4
        add     hl,de                    ; XDPB+19: sectors per track
        call    xbios_cpm_read_bank0_f2
        or      a
        jp      z,.format_bad
        cp      17
        jp      nc,.format_bad
        ld      (xbios_format_sectors),a
        ld      b,a
        ld      a,(disk_sectors)
        cp      b
        jp      nz,.format_bad
        inc     hl
        inc     hl                       ; XDPB+21: physical bytes, low
        call    xbios_cpm_read_bank0_f2
        or      a                        ; native media currently use 512
        jp      nz,.format_bad
        inc     hl
        call    xbios_cpm_read_bank0_f2
        cp      2
        jp      nz,.format_bad
        inc     hl
        inc     hl                       ; XDPB+24: format gap
        call    xbios_cpm_read_bank0_f2
        ld      (xbios_format_gap),a

        ; Four bytes per sector must fit before the 64K CP/M-bank boundary.
        ld      a,(xbios_format_sectors)
        add     a,a
        add     a,a
        ld      e,a
        ld      d,0
        ld      hl,(xbios_destination)
        add     hl,de
        jp      c,.format_no_data

        ld      a,(xbios_track)
        ld      d,a
        ld      e,0
        call    native_map_physical_sector
        jp      c,.format_no_data
        ld      a,d
        ld      (xbios_format_cylinder),a
        ld      a,c
        ld      (xbios_format_side),a
        xor     a
        ld      (sector_cache_valid),a
        ld      (cached_entry_valid),a

        ld      a,04dh                   ; MFM FORMAT TRACK
        call    fdc_write
        ld      a,(xbios_format_side)
        add     a,a
        add     a,a                      ; head plus unit zero
        call    fdc_write
        ld      a,(xbios_format_n)
        call    fdc_write
        ld      a,(xbios_format_sectors)
        call    fdc_write
        ld      a,(xbios_format_gap)
        call    fdc_write
        ld      a,(xbios_format_fill)
        call    fdc_write

        ld      a,(xbios_format_sectors)
        add     a,a
        add     a,a
        ld      c,a
        ld      b,0
        ld      hl,(xbios_destination)
.format_stream:
        call    xbios_cpm_read_f2
        call    fdc_write_data_or_result
        jr      c,.format_result
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,.format_stream
        call    fdc_read                 ; ST0 after all ID tuples
.format_result:
        ld      (last_fdc_st0),a
        and     0c0h
        rlca                            ; 40h/80h EOC tuple normalises to zero
        ld      c,a
        call    fdc_read
        ld      (last_fdc_st1),a
        xor     c
        ld      c,a
        call    fdc_read
        ld      (last_fdc_st2),a
        or      c
        ld      c,a
        ld      b,4
.format_drain:
        call    fdc_read
        djnz    .format_drain
        ld      a,c
        or      a
        jr      z,.format_good
        ld      a,(last_fdc_st1)
        and     2
        ld      a,1                      ; write protected
        ret     nz
.format_no_data:
        ld      a,4
        ret
.format_bad:
        ld      a,6
        ret
.format_good:
        xor     a
        ret

; DD L WRITE sends WRITE DATA, WRITE DELETED DATA and FORMAT TRACK to the
; uPD765 unchanged. SCAN is implemented below with READ DATA because the
; ZEsarUX controller lacks those opcodes; MAME, Joyce and physical hardware
; retain the same published result semantics. The CP/M payload is exposed
; through the disposable F2 window.
native_xbios_low_write:
        push    hl
        pop     ix
        ld      a,h
        cp      0c0h
        jp      c,.low_write_invalid
        ld      a,(ix+0)
        cp      2
        jp      nc,.low_write_invalid
        ld      (xbios_bank),a
        ld      l,(ix+1)
        ld      h,(ix+2)
        ld      (low_address),hl
        ld      e,(ix+3)
        ld      d,(ix+4)
        ld      (low_remaining),de
        ld      a,d
        or      e
        jp      z,.low_write_invalid
        add     hl,de
        jr      nc,.low_write_range_ok
        ld      a,h
        or      l
        jp      nz,.low_write_invalid
.low_write_range_ok:
        ld      a,(ix+5)
        cp      6
        jp      c,.low_write_invalid
        cp      17
        jp      nc,.low_write_invalid
        ld      b,a
        ld      a,(ix+6)
        and     01fh
        cp      05h                     ; WRITE DATA
        jr      z,.low_write_nine
        cp      09h                     ; WRITE DELETED DATA
        jr      z,.low_write_nine
        cp      0dh                     ; FORMAT TRACK
        jr      z,.low_write_six
        cp      11h                     ; SCAN EQUAL
        jr      z,.low_write_nine
        cp      19h                     ; SCAN LOW OR EQUAL
        jr      z,.low_write_nine
        cp      1dh                     ; SCAN HIGH OR EQUAL
        jp      nz,.low_write_invalid
.low_write_nine:
        ld      a,b
        cp      9
        jp      nz,.low_write_invalid
        jr      .low_write_command_ok
.low_write_six:
        ld      a,b
        cp      6
        jp      nz,.low_write_invalid
.low_write_command_ok:
        ld      a,(ix+7)
        and     3
        jp      nz,.low_write_invalid
        ld      a,(ix+6)
        ld      (low_command),a
        and     01fh
        cp      11h
        jr      z,.low_write_scan
        cp      19h
        jr      z,.low_write_scan
        cp      1dh
        jr      nz,.low_write_raw
.low_write_scan:
        ld      a,(ix+7)
        ld      (low_unit),a
        rrca
        rrca
        and     1
        ld      (low_side),a
        ld      a,(ix+8)
        ld      (low_cylinder),a
        ld      a,(ix+9)
        ld      (low_head),a
        ld      a,(ix+10)
        ld      (low_sector),a
        ld      a,(ix+11)
        cp      7
        jp      nc,.low_write_invalid
        ld      (low_n),a
        ld      a,(ix+12)
        ld      (low_end_sector),a
        ld      a,(ix+13)
        ld      (low_gpl),a
        ld      a,(ix+14)                ; sector step for SCAN
        or      a
        jp      z,.low_write_invalid
        ld      (low_dtl),a
        jp      native_xbios_low_scan

.low_write_raw:
        ld      a,9
        out     (0f8h),a
        ld      a,4
        out     (0f8h),a
        push    ix
        pop     hl
        ld      de,6
        add     hl,de
.low_write_command:
        ld      a,(hl)
        call    fdc_write
        inc     hl
        djnz    .low_write_command

        ld      hl,(low_address)
        ld      bc,(low_remaining)
.low_write_data:
        call    xbios_cpm_read_f2
        call    fdc_write_data_or_result
        jr      c,.low_write_result_st0
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,.low_write_data
        ld      a,5                      ; terminal count after caller bytes
        out     (0f8h),a
        call    fdc_read
.low_write_result_st0:
        ld      (last_fdc_st0),a
        ld      hl,0ffe0h
        ld      (hl),7
        inc     hl
        ld      (hl),a
        inc     hl
        call    fdc_read
        ld      (last_fdc_st1),a
        ld      (hl),a
        inc     hl
        call    fdc_read
        ld      (last_fdc_st2),a
        ld      (hl),a
        inc     hl
        ld      b,4
.low_write_result_tail:
        call    fdc_read
        ld      (hl),a
        inc     hl
        djnz    .low_write_result_tail
        ld      hl,0ffe0h
        ld      a,(last_fdc_st0)
        and     0c0h
        ld      b,a
        ld      a,(last_fdc_st1)
        or      b
        jr      z,.low_write_good
        ld      a,(last_fdc_st1)
        and     2
        ld      a,1
        scf
        ret     nz
        ld      a,4
        scf
        ret
.low_write_good:
        xor     a
        ret

.low_write_invalid:
        ld      hl,0ffe0h
        ld      (hl),7
        inc     hl
        ld      (hl),040h
        inc     hl
        ld      (hl),4
        inc     hl
        xor     a
        ld      b,5
.low_write_invalid_tail:
        ld      (hl),a
        inc     hl
        djnz    .low_write_invalid_tail
        ld      hl,0ffe0h
        ld      a,4
        scf
        ret

; ZEsarUX's uPD765 model deliberately omits the three SCAN commands. Execute
; their published bytewise predicates with ordinary READ DATA operations so
; native OpenPCW remains compatible there while retaining identical behavior
; on controller-complete emulators and real hardware.
native_xbios_low_scan:
        ld      a,9
        out     (0f8h),a
        ld      a,4
        out     (0f8h),a
        ld      a,(low_cylinder)
        call    fdc_seek
        jp      c,.scan_seek_error
.scan_next_sector:
        ld      a,(low_n)
        ld      b,a
        ld      hl,128
        or      a
        jr      z,.scan_size_ready
.scan_size_scale:
        add     hl,hl
        djnz    .scan_size_scale
.scan_size_ready:
        ld      (low_sector_bytes),hl
        ld      de,(low_remaining)
        or      a
        sbc     hl,de
        jr      c,.scan_use_sector_size
        ld      hl,(low_remaining)
        jr      .scan_transfer_ready
.scan_use_sector_size:
        ld      hl,(low_sector_bytes)
.scan_transfer_ready:
        ld      (low_transfer),hl
        xor     a
        ld      (low_scan_relation),a

        ld      a,(low_command)
        and     020h                    ; preserve SCAN's skip-deleted bit
        or      046h                    ; MFM READ DATA, single sector
        call    fdc_write
        ld      a,(low_unit)
        call    fdc_write
        ld      a,(low_cylinder)
        call    fdc_write
        ld      a,(low_head)
        call    fdc_write
        ld      a,(low_sector)
        call    fdc_write
        ld      a,(low_n)
        call    fdc_write
        ld      a,(low_sector)
        call    fdc_write
        ld      a,(low_gpl)
        call    fdc_write
        ld      a,0ffh
        call    fdc_write

        ld      hl,(low_address)
        ld      bc,(low_sector_bytes)
        ld      de,(low_transfer)
.scan_data:
        call    fdc_read_data_or_result
        jr      c,.scan_result_st0
        ld      (low_scan_disk_byte),a
        ld      a,d
        or      e
        jr      z,.scan_drain_byte
        call    xbios_cpm_read_f2
        ld      (low_scan_memory_byte),a
        ld      a,(low_scan_relation)
        or      a
        jr      nz,.scan_compared
        push    de
        ld      a,(low_scan_memory_byte)
        ld      e,a
        ld      a,(low_scan_disk_byte)
        cp      e
        ld      a,0ffh                  ; disk byte is lower
        jr      c,.scan_set_relation
        ld      a,1                     ; disk byte is higher
        jr      nz,.scan_set_relation
        xor     a
.scan_set_relation:
        ld      (low_scan_relation),a
        pop     de
.scan_compared:
        inc     hl
        dec     de
.scan_drain_byte:
        dec     bc
        ld      a,b
        or      c
        jr      nz,.scan_data
        call    fdc_read
.scan_result_st0:
        ld      (last_fdc_st0),a
        call    fdc_read
        ld      (last_fdc_st1),a
        call    fdc_read
        ld      (last_fdc_st2),a
        call    fdc_read
        ld      (userf_read_id_c),a
        call    fdc_read
        ld      (userf_read_id_h),a
        call    fdc_read
        ld      (userf_read_id_r),a
        call    fdc_read
        ld      (disk_sector_n),a

        ld      a,(last_fdc_st0)
        and     0c0h
        ld      b,a
        ld      a,(last_fdc_st1)
        or      b
        ld      b,a
        ld      a,(last_fdc_st2)
        and     037h                    ; CM is not a read failure for SCAN
        or      b
        jp      nz,native_xbios_low_scan_controller_error

        ld      de,(low_transfer)
        ld      hl,(low_address)
        add     hl,de
        ld      (low_address),hl
        ld      hl,(low_remaining)
        or      a
        sbc     hl,de
        ld      (low_remaining),hl

        ld      a,(low_command)
        and     01fh
        cp      11h
        jr      z,.scan_test_equal
        cp      19h
        jr      z,.scan_test_low
        ; SCAN HIGH OR EQUAL: relation zero or positive is a hit.
        ld      a,(low_scan_relation)
        cp      0ffh
        jr      nz,.scan_hit
        jr      .scan_not_hit
.scan_test_low:
        ld      a,(low_scan_relation)
        cp      1
        jr      nz,.scan_hit
        jr      .scan_not_hit
.scan_test_equal:
        ld      a,(low_scan_relation)
        or      a
        jr      z,.scan_hit
.scan_not_hit:
        ld      hl,(low_remaining)
        ld      a,h
        or      l
        jr      z,.scan_unsatisfied
        ld      a,(low_sector)
        ld      b,a
        ld      a,(low_end_sector)
        cp      b
        jr      z,.scan_unsatisfied
        ld      a,(low_dtl)             ; STP
        add     a,b
        jr      c,.scan_unsatisfied
        ld      (low_sector),a
        jp      .scan_next_sector

.scan_hit:
        ld      a,(low_scan_relation)
        or      a
        ld      a,0
        jr      nz,.scan_publish
        ld      a,8                     ; SH: exact equality
        jr      .scan_publish
.scan_unsatisfied:
        ld      a,4                     ; SN: no sector met predicate
.scan_publish:
        ld      (low_scan_st2),a
        ld      hl,0ffe0h
        ld      (hl),7
        inc     hl
        ld      a,(low_unit)
        and     7
        ld      (hl),a
        inc     hl
        xor     a
        ld      (hl),a
        inc     hl
        ld      a,(low_scan_st2)
        ld      (hl),a
        inc     hl
        ld      a,(userf_read_id_c)
        ld      (hl),a
        inc     hl
        ld      a,(userf_read_id_h)
        ld      (hl),a
        inc     hl
        ld      a,(userf_read_id_r)
        ld      (hl),a
        inc     hl
        ld      a,(disk_sector_n)
        ld      (hl),a
        ld      hl,0ffe0h
        xor     a
        ret

.scan_seek_error:
        ld      a,040h
        ld      (last_fdc_st0),a
        ld      a,4
        ld      (last_fdc_st1),a
        xor     a
        ld      (last_fdc_st2),a
        ld      (userf_read_id_c),a
        ld      (userf_read_id_h),a
        ld      (userf_read_id_r),a
        ld      (disk_sector_n),a
native_xbios_low_scan_controller_error:
        ld      hl,0ffe0h
        ld      (hl),7
        inc     hl
        ld      a,(last_fdc_st0)
        ld      (hl),a
        inc     hl
        ld      a,(last_fdc_st1)
        ld      (hl),a
        inc     hl
        ld      a,(last_fdc_st2)
        ld      (hl),a
        inc     hl
        ld      a,(userf_read_id_c)
        ld      (hl),a
        inc     hl
        ld      a,(userf_read_id_h)
        ld      (hl),a
        inc     hl
        ld      a,(userf_read_id_r)
        ld      (hl),a
        inc     hl
        ld      a,(disk_sector_n)
        ld      (hl),a
        ld      hl,0ffe0h
        ld      a,4
        scf
        ret

; DD WRITE SECTOR can remain in executable page one by using F2 as its CP/M
; bank window. This leaves F1 mapped to the code while copying a caller's
; sector into the page-zero transfer buffer, and therefore avoids consuming
; the fixed page-zero ALV area merely to support writes from either bank.
native_xbios_write_sector:
        ld      a,c
        and     3
        jp      nz,.write_bad
        ld      a,b
        cp      2
        jp      nc,.write_bad
        ld      (xbios_bank),a
        ld      a,d
        ld      (xbios_track),a
        ld      a,e
        ld      (xbios_sector),a
        ld      (xbios_destination),hl
        ld      de,0fe01h
        or      a
        sbc     hl,de
        jp      nc,.write_bad
        call    disk_login
        jp      c,.write_bad
        ld      a,(xbios_track)
        ld      d,a
        ld      a,(xbios_sector)
        ld      e,a
        call    native_map_physical_sector
        jp      c,.write_bad
        ld      hl,(xbios_destination)
        ld      de,sector_buffer
        ld      bc,512
.write_copy:
        call    xbios_cpm_read_f2
        ld      (de),a
        inc     hl
        inc     de
        dec     bc
        ld      a,b
        or      c
        jr      nz,.write_copy
        ; DE was the transfer-buffer cursor and BC counted bytes, so restore
        ; the physical CHR tuple before issuing WRITE DATA.
        ld      a,(xbios_track)
        ld      d,a
        ld      a,(xbios_sector)
        ld      e,a
        call    native_map_physical_sector
        jp      c,.write_bad
        ld      hl,sector_buffer
        call    fdc_write_sector
        jr      nc,.write_good
        ld      a,(last_fdc_st1)
        and     2
        ld      a,1                      ; write protected
        ret     nz
.write_bad:
        ld      a,4                      ; no data / invalid request
        ret
.write_good:
        xor     a
        ret

xbios_cpm_map_f2:
        ld      c,h
        ld      a,h
        and     0c0h
        rlca
        rlca
        ld      b,a                      ; logical 16K page 0..3
        cp      3
        jr      z,.write_common
        ld      a,(xbios_bank)
        or      a
        ld      a,b
        jr      z,.write_system
        add     a,4
        jr      .write_page_ready
.write_system:
        cp      2
        jr      nz,.write_page_ready
        inc     a                        ; bank-0 page 2 is physical block 3
        jr      .write_page_ready
.write_common:
        ld      a,7
.write_page_ready:
        or      080h
        out     (0f2h),a
        ld      a,c
        and     03fh
        or      080h                     ; F2 window occupies 8000h-BFFFh
        ld      h,a
        ret

xbios_cpm_read_f2:
        push    bc
        call    xbios_cpm_map_f2
        ld      a,(hl)
        ld      h,c
        pop     bc
        ret

; Build a standard 17-byte DPB or 27-byte Amstrad XDPB from the independent
; 16-byte disk specification at HL. B is the requested result size. The input
; is copied before writing IX, so source and destination may overlap. This is
; the implementation shared by DD SEL FORMAT, DD L DPB and DD L XDPB; it never
; consults or alters the mounted medium's cached geometry.
native_xbios_build_record:
        ld      a,b
        ld      (userf_dpb_length),a
        ld      de,userf_disk_record
        ld      bc,10
        ldir

        ; Ten E5 bytes denote the default PCW 180K format.
        ld      hl,userf_disk_record
        ld      b,10
.record_erased:
        ld      a,(hl)
        cp      0e5h
        jr      nz,.record_ready
        inc     hl
        djnz    .record_erased
        ld      hl,userf_standard_formats
        ld      de,userf_disk_record
        ld      bc,10
        ldir
.record_ready:
        ld      a,(userf_disk_record+0)
        cp      4
        jp      nc,.record_bad
        ld      (userf_disk_format),a
        ld      a,(userf_disk_record+1)
        and     3
        cp      3
        jp      z,.record_bad
        ld      c,a                      ; zero=single side, nonzero=double
        ld      a,(userf_disk_record+2)
        or      a
        jp      z,.record_bad
        ld      e,a                      ; logical tracks before reservation
        ld      a,c
        or      a
        jr      z,.record_tracks_ready
        sla     e
        jp      c,.record_bad
.record_tracks_ready:
        ld      a,(userf_disk_record+3)
        or      a
        jp      z,.record_bad
        ld      a,(userf_disk_record+4)
        cp      7
        jp      nc,.record_bad           ; physical shift 0..6
        ld      c,a
        ld      a,(userf_disk_record+6)
        cp      3
        jp      c,.record_bad
        cp      c
        jp      c,.record_bad
        cp      8
        jp      nc,.record_bad           ; block shift <=7
        ld      a,(userf_disk_record+7)
        or      a
        jp      z,.record_bad
        cp      17
        jp      nc,.record_bad           ; allocation bitmap is 16 bits

        ; DSM = usable_tracks * sectors / sectors_per_block - 1.
        ld      a,e
        ld      c,a
        ld      a,(userf_disk_record+5)
        ld      b,a
        ld      a,c
        sub     b
        jp      c,.record_bad
        jp      z,.record_bad
        ld      c,a
        ld      a,(userf_disk_record+3)
        ld      e,a
        ld      a,c
        call    multiply_8
        ld      a,(userf_disk_record+6)
        ld      b,a
        ld      a,(userf_disk_record+4)
        ld      c,a
        ld      a,b
        sub     c
        ld      b,a
        or      a
        jr      z,.record_blocks_ready
.record_divide_blocks:
        srl     h
        rr      l
        djnz    .record_divide_blocks
.record_blocks_ready:
        ld      a,h
        or      l
        jp      z,.record_bad
        dec     hl
        ld      (userf_disk_dsm),hl
        ld      a,h
        or      a
        jr      z,.record_dsm_valid
        ld      a,(userf_disk_record+6)
        cp      4
        jp      c,.record_bad             ; large disks need >=2K blocks
.record_dsm_valid:

        ; DRM = directory_blocks * (block_size / 32) - 1. Use a 16-bit
        ; accumulator so the complete published BSH range is validated.
        ld      hl,4
        ld      a,(userf_disk_record+6)
        ld      b,a
.record_entries_scale:
        add     hl,hl
        djnz    .record_entries_scale
        ld      de,0
        ld      a,(userf_disk_record+7)
        ld      c,a
.record_entries_multiply:
        ex      de,hl
        add     hl,de
        ex      de,hl
        dec     c
        jr      nz,.record_entries_multiply
        ex      de,hl
        dec     hl
        ld      a,h
        cp      2
        jp      nc,.record_bad            ; CP/M directory maximum is 512
        ld      (userf_disk_drm),hl

        ld      hl,userf_xdpb_result
        ld      b,27
        xor     a
.record_clear_result:
        ld      (hl),a
        inc     hl
        djnz    .record_clear_result

        ; SPT, BSH, BLM and EXM.
        ld      a,(userf_disk_record+3)
        ld      l,a
        ld      h,0
        ld      a,(userf_disk_record+4)
        ld      b,a
        or      a
        jr      z,.record_spt_ready
.record_spt_scale:
        add     hl,hl
        djnz    .record_spt_scale
.record_spt_ready:
        ld      (userf_xdpb_result+0),hl
        ld      a,(userf_disk_record+6)
        ld      (userf_xdpb_result+2),a
        ld      b,a
        ld      a,1
.record_blm_scale:
        add     a,a
        djnz    .record_blm_scale
        dec     a
        ld      (userf_xdpb_result+3),a
        ld      hl,(userf_disk_dsm)
        ld      a,h
        or      a
        ld      a,(userf_disk_record+6)
        jr      z,.record_small_exm
        sub     4
        jr      .record_exm_power
.record_small_exm:
        sub     3
.record_exm_power:
        ld      b,a
        or      a
        ld      a,1
        jr      z,.record_exm_ready
.record_exm_scale:
        add     a,a
        djnz    .record_exm_scale
.record_exm_ready:
        dec     a
        ld      (userf_xdpb_result+4),a

        ; DSM, DRM, allocation bitmap, checksum-vector length and offset.
        ld      hl,(userf_disk_dsm)
        ld      (userf_xdpb_result+5),hl
        ld      hl,(userf_disk_drm)
        ld      (userf_xdpb_result+7),hl
        ld      a,(userf_disk_record+7)
        ld      b,a
        ld      a,16
        sub     b
        ld      b,a
        ld      hl,0ffffh
        jr      z,.record_allocation_ready
.record_allocation_shift:
        add     hl,hl
        djnz    .record_allocation_shift
.record_allocation_ready:
        ld      a,h
        ld      (userf_xdpb_result+9),a
        ld      a,l
        ld      (userf_xdpb_result+10),a
        ld      hl,(userf_disk_drm)
        inc     hl
        srl     h
        rr      l
        srl     h
        rr      l
        ld      (userf_xdpb_result+11),hl
        ld      a,(userf_disk_record+5)
        ld      (userf_xdpb_result+13),a

        ; Physical geometry extension.
        ld      a,(userf_disk_record+4)
        ld      (userf_xdpb_result+15),a
        ld      b,a
        or      a
        ld      a,1
        jr      z,.record_phm_ready
.record_phm_scale:
        add     a,a
        djnz    .record_phm_scale
.record_phm_ready:
        dec     a
        ld      (userf_xdpb_result+16),a
        ld      a,(userf_disk_record+1)
        ld      (userf_xdpb_result+17),a
        ld      a,(userf_disk_record+2)
        ld      (userf_xdpb_result+18),a
        ld      a,(userf_disk_record+3)
        ld      (userf_xdpb_result+19),a
        ld      a,(userf_disk_format)
        cp      1
        ld      a,041h
        jr      z,.record_first_sector
        ld      a,(userf_disk_format)
        cp      2
        ld      a,0c1h
        jr      z,.record_first_sector
        ld      a,1
.record_first_sector:
        ld      (userf_xdpb_result+20),a
        ld      hl,128
        ld      a,(userf_disk_record+4)
        ld      b,a
        or      a
        jr      z,.record_sector_size_ready
.record_sector_size:
        add     hl,hl
        djnz    .record_sector_size
.record_sector_size_ready:
        ld      (userf_xdpb_result+21),hl
        ld      a,(userf_disk_record+8)
        ld      (userf_xdpb_result+23),a
        ld      a,(userf_disk_record+9)
        ld      (userf_xdpb_result+24),a
        ld      a,060h
        ld      (userf_xdpb_result+25),a

        ; Publish only the requested public structure. IX itself is preserved.
        ld      hl,userf_xdpb_result
        push    ix
        pop     de
        ld      a,(userf_dpb_length)
        ld      c,a
        ld      b,0
        ldir

        ; DD SEL FORMAT publishes buffer sizes like DD LOGIN. The load calls
        ; document these registers as corrupt, so returning the same useful
        ; values is compatible: DE=double-bit ALV bytes, HL=hash bytes.
        ld      hl,(userf_disk_dsm)
        srl     h
        rr      l
        srl     h
        rr      l
        inc     hl
        inc     hl
        ex      de,hl
        ld      hl,(userf_disk_drm)
        inc     hl
        add     hl,hl
        add     hl,hl
        ld      a,(userf_disk_format)
        scf
        ret
.record_bad:
        ld      a,6                      ; bad format
        or      a                        ; carry clear
        ret

userf_standard_formats:
        db      0,000h,40,9,2,1,3,2,02ah,052h
        db      1,000h,40,9,2,2,3,2,02ah,052h
        db      2,000h,40,9,2,0,3,2,02ah,052h
        db      3,081h,80,9,2,1,4,4,02ah,052h
userf_disk_record:
        defs    10,0
userf_disk_format:
        db      0
userf_dpb_length:
        db      0
userf_disk_dsm:
        dw      0
userf_disk_drm:
        dw      0
userf_xdpb_result:
        defs    27,0

; Retained serial configuration. These settings remain observable through
; CD SA PARAMS even when no optional CPS8256 hardware is present.
serial_mode: db 0ffh
serial_receive_baud: db 14
serial_transmit_baud: db 14
serial_stop_bits: db 0
serial_parity: db 0
serial_receive_bits: db 8
serial_transmit_bits: db 8

; Restore the caller's complete AF for services documented (or deliberately
; implemented) as preserving it, without changing any other public register.
native_userf_restore_af:
        push    hl
        ld      hl,(OPENPCW_COMMON_SAVED_AF)
        push    hl
        pop     af
        pop     hl
        ret

; The shell invalidates a caller-selected geometry only at its explicit media
; boundary. Ordinary BDOS Function 13 resets retain the latest validated XDPB.
native_disk_media_reset:
        xor     a
        ld      (userf_dpb_length),a
        jp      native_disk_reset

; Return carry and the specification pointer only for the latest validated
; 27-byte XDPB. DD L DPB publishes 17 bytes and does not select geometry.
native_xbios_active_spec:
        ld      a,(userf_dpb_length)
        cp      27
        jr      nz,.inactive
        ld      a,(userf_disk_record+2)
        or      a                       ; zero tracks is never valid
        jr      z,.inactive
        ld      hl,userf_disk_record
        scf
        ret
.inactive:
        or      a                       ; clear carry, preserve caller HL
        ret

; Clear the physical 90x32 display and restore the default full-screen view.
; This runs only while the resident page-one terminal engine is mapped.
terminal_clear:
        xor     a
        ld      hl,05930h
        ld      de,05c01h
        ld      bc,23039
        call    native_screen_transfer_private
        ld      (cursor_x),a
        ld      (cursor_y),a
        ld      (terminal_view_top),a
        ld      (terminal_view_left),a
        ld      a,30
        ld      (terminal_bottom_row),a
        ld      a,89
        ld      (terminal_view_right),a
        call    terminal_draw_status
        ret

; Viewport-scoped scrolling and clearing are resident page-one terminal code.
; A row occupies 720 bytes (90 cells x 8 bitmap scanline bytes).
terminal_scroll:
        ld      a,(terminal_bottom_row)
        ld      b,a
        ld      a,(terminal_view_top)
        cp      b
        jr      z,terminal_scroll_clear_bottom
        call    terminal_view_row_address
        ex      de,hl              ; DE=first destination row
        ld      hl,720
        add     hl,de              ; HL=following source row
        ld      a,(terminal_bottom_row)
        ld      b,a
        ld      a,(terminal_view_top)
        ld      c,a
        ld      a,b
        sub     c                  ; number of rows to copy
terminal_scroll_row:
        push    af
        push    hl
        push    de
        call    terminal_view_width
        call    native_screen_copy_private
        pop     de
        pop     hl
        ld      bc,720
        add     hl,bc
        ex      de,hl
        add     hl,bc
        ex      de,hl
        pop     af
        dec     a
        jr      nz,terminal_scroll_row
terminal_scroll_clear_bottom:
        ld      a,(terminal_bottom_row)
        push    af
        call    terminal_clear_row
        pop     af
        ld      (cursor_y),a
        ret

; Return the physical bitmap address of the viewport's first cell on row A.
terminal_view_row_address:
        ld      hl,05930h
        or      a
        jr      z,terminal_view_address_row_ready
        ld      b,a
        ld      de,720
terminal_view_address_add_row:
        add     hl,de
        djnz    terminal_view_address_add_row
terminal_view_address_row_ready:
        ld      a,(terminal_view_left)
        ld      e,a
        ld      d,0
        ex      de,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,de
        ret

; Return the viewport width in bitmap bytes (eight bytes per text cell).
terminal_view_width:
        push    hl
        ld      a,(terminal_view_right)
        ld      c,a
        ld      a,(terminal_view_left)
        ld      b,a
        ld      a,c
        sub     b
        inc     a
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      b,h
        ld      c,l
        pop     hl
        ret

; Clear one viewport row. Input A is the absolute text-row number.
terminal_clear_row:
        call    terminal_view_row_address
        push    hl
        pop     de
        inc     de
        call    terminal_view_width
        xor     a
        dec     bc
        call    native_screen_transfer_private
        ret

terminal_clear_viewport:
        ld      a,(terminal_view_top)
terminal_clear_viewport_row:
        push    af
        call    terminal_clear_row
        pop     af
        ld      b,a
        ld      a,(terminal_bottom_row)
        cp      b
        ret     z
        ld      a,b
        inc     a
        jr      terminal_clear_viewport_row

; ESC X consumes four printable-offset arguments (top, left, height, width).
; Keep this comparatively large parser in the resident page-one runtime: page
; zero is constrained by the fixed ALV addresses at 3e00h/3f00h, while every
; native terminal call already executes with page one mapped.
terminal_escape_view_top:
        ld      b,31
        call    terminal_escape_view_decode
        ld      (terminal_pending_top),a
        ld      a,6
        ld      (escape_state),a
        ret

terminal_escape_view_left:
        ld      b,89
        call    terminal_escape_view_decode
        ld      (terminal_pending_left),a
        ld      a,7
        ld      (escape_state),a
        ret

terminal_escape_view_height:
        ld      b,31
        call    terminal_escape_view_decode
        inc     a
        ld      (terminal_pending_height),a
        ld      a,8
        ld      (escape_state),a
        ret

terminal_escape_view_width:
        ld      b,89
        call    terminal_escape_view_decode
        inc     a
        ld      b,a
        ld      a,(terminal_pending_top)
        ld      (terminal_view_top),a
        ld      c,a
        ld      a,(terminal_pending_height)
        dec     a
        add     a,c
        cp      32
        jr      c,terminal_escape_view_bottom_ready
        ld      a,31
terminal_escape_view_bottom_ready:
        ld      (terminal_bottom_row),a
        ld      a,(terminal_pending_left)
        ld      (terminal_view_left),a
        ld      c,a
        ld      a,b
        dec     a
        add     a,c
        cp      90
        jr      c,terminal_escape_view_right_ready
        ld      a,89
terminal_escape_view_right_ready:
        ld      (terminal_view_right),a
        ; A viewport change clamps the existing cursor into the new rectangle.
        ld      c,a
        ld      a,(terminal_view_left)
        ld      b,a
        ld      a,(cursor_x)
        call    terminal_clamp_coordinate
        ld      (cursor_x),a
        ld      a,(terminal_bottom_row)
        ld      c,a
        ld      a,(terminal_view_top)
        ld      b,a
        ld      a,(cursor_y)
        call    terminal_clamp_coordinate
        ld      (cursor_y),a
        xor     a
        ld      (escape_state),a
        ret

; Clamp coordinate A into inclusive range B..C.
terminal_clamp_coordinate:
        cp      b
        jr      nc,terminal_clamp_coordinate_low_ok
        ld      a,b
        ret
terminal_clamp_coordinate_low_ok:
        cp      c
        ret     c
        ld      a,c
        ret

; Decode one ESC X argument: printable-offset byte -> 0..B inclusive.
terminal_escape_view_decode:
        ld      a,(terminal_character)
        sub     32
        jr      nc,terminal_escape_view_decode_nonnegative
        xor     a
        ret
terminal_escape_view_decode_nonnegative:
        cp      b
        ret     c
        ld      a,b
        ret

; The lossless font unpacker is transient, so keep only this jump in the live
; area below the screen. native_init invokes it while page one is mapped and
; then mirrors the resulting 1 KiB table into the high 128 cells.
native_install_low_font:
        jp      native_unpack_font

; Render the status directly into the final screen row from the same installed
; font applications use.  Keeping only the short source text in private page 8
; avoids a second bitmap cache and leaves the public 05930h environment wholly
; dedicated to the display.  The caller's current B value is immaterial.
terminal_draw_status:
        jp      terminal_draw_status_impl
        ; Preserve the separately assembled native-shell bridge address.
        defs    8,0

; -------------------------------------------------------------------------
; Native resident shell commands
;
; This resident DIR is part of the protected native runtime and remains
; available after replacing A:. It uses the same BDOS search implementation
; exposed to CP/M applications.
; DE points at the zero-terminated command line in resident common memory.
native_shell_command:
        ; DE=0 is the resident prompt's private request for the current user
        ; prefix.  CP/M omits user zero and renders users 1..15 immediately
        ; before the selected drive letter (for example, 8A> or 15A>).
        ld      a,d
        or      e
        jr      nz,native_shell_parse_command
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        ld      (native_file_user),a
        ret     z
        cp      10
        jr      c,native_shell_prompt_digit
        push    af
        ld      a,'1'
        call    native_putc
        pop     af
        sub     10
native_shell_prompt_digit:
        add     a,'0'
        jp      native_putc

native_shell_parse_command:
        push    de
        call    native_shell_select_user
        or      a
        jp      nz,native_dir_handled
        call    command_name
        jr      c,native_dir_not_builtin
        ld      hl,wanted_name
        ld      de,native_dir_name
        ld      b,11
native_dir_compare_name:
        ld      a,(de)
        cp      (hl)
        jr      nz,native_dir_not_builtin
        inc     de
        inc     hl
        djnz    native_dir_compare_name

        ; Build an all-files extent-zero FCB in the now-disposable shell
        ; command buffer. Search results use the conventional DMA at 0080h.
        ld      hl,OPENPCW_COMMON_COMMAND_BUFFER
        xor     a
        ld      (hl),a
        inc     hl
        ld      b,11
        ld      a,'?'
native_dir_fill_wildcard:
        ld      (hl),a
        inc     hl
        djnz    native_dir_fill_wildcard
        xor     a
        ld      (hl),a
        ld      hl,OPENPCW_COMMON_COMMAND_BUFFER
        ld      (m_fcb),hl
        ld      hl,0080h
        ld      (m_dma),hl
        ; A physical disk may have been replaced since the prompt appeared.
        ; Force the same fresh geometry/directory login used by native .COM
        ; execution; M: remains an already live RAM medium.
        ld      a,(OPENPCW_COMMON_CURRENT_DISK)
        or      a
        call    z,native_disk_reset
        call    native_dir_search_first_bridge
        cp      0ffh
        jp      z,native_dir_empty_result
        xor     a
        ld      (native_dir_column),a
native_dir_entry:
        call    native_dir_print_entry
        call    native_dir_search_next_bridge
        cp      0ffh
        jr      nz,native_dir_entry
        ld      a,(native_dir_column)
        or      a
        jp      z,native_dir_handled
        ld      hl,native_dir_newline
        call    native_print_string
native_dir_handled:
        pop     de
        ld      a,2
        ret
native_dir_empty_result:
        ld      hl,native_dir_empty
        call    native_print_string
        jp      native_dir_handled
native_dir_not_builtin:
        pop     de
        xor     a
        ret

; A selects one of the four 32-byte entries copied to the DMA by BDOS search.
native_dir_print_entry:
        and     3
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      de,0081h
        add     hl,de
        ld      a,(native_dir_column)
        or      a
        jr      nz,native_dir_separator
        ld      a,(OPENPCW_COMMON_CURRENT_DISK)
        add     a,'A'
        call    native_dir_put_preserved
        ld      a,':'
        call    native_dir_put_preserved
        ld      a,' '
        call    native_dir_put_preserved
        jr      native_dir_stem_start
native_dir_separator:
        ld      a,' '
        call    native_dir_put_preserved
        ld      a,':'
        call    native_dir_put_preserved
        ld      a,' '
        call    native_dir_put_preserved
native_dir_stem_start:
        ld      b,8
native_dir_stem:
        call    native_dir_tpa_read_bridge
        and     07fh
        call    native_dir_put_preserved
        inc     hl
        djnz    native_dir_stem
        ld      a,' '
        call    native_dir_put_preserved
        ld      b,3
native_dir_extension:
        call    native_dir_tpa_read_bridge
        and     07fh
        call    native_dir_put_preserved
        inc     hl
        djnz    native_dir_extension
        ld      a,(native_dir_column)
        inc     a
        cp      5
        jr      z,native_dir_end_row
        ld      (native_dir_column),a
        ret
native_dir_end_row:
        xor     a
        ld      (native_dir_column),a
        ld      hl,native_dir_newline
        jp      native_print_string

native_dir_put_preserved:
        push    bc
        push    hl
        call    native_putc
        pop     hl
        pop     bc
        ret

native_dir_name:    db 'DIR     COM'
native_dir_newline: db 13,10,0
native_dir_empty:   db 'No File',13,10,0
native_dir_column:  db 0

; Recognise the exact CP/M Plus user-area commands 0: through 15:.  The parser
; accepts leading spaces, requires the colon to terminate the numeric token,
; and changes the same SCB byte used by BDOS Function 32 and all filesystem
; lookups.  A=2 reports a handled shell command; zero leaves DE untouched for
; the ordinary resident-command and .COM dispatch paths.
native_shell_select_user:
        push    de
native_shell_user_skip_space:
        call    command_read
        cp      ' '
        jr      nz,native_shell_user_first
        inc     de
        jr      native_shell_user_skip_space
native_shell_user_first:
        cp      '0'
        jr      c,native_shell_user_bad
        cp      '9'+1
        jr      nc,native_shell_user_bad
        sub     '0'
        ld      b,a
        inc     de
        call    command_read
        cp      ':'
        jr      z,native_shell_user_colon
        ld      c,a
        ld      a,b
        cp      1
        jr      nz,native_shell_user_bad
        ld      a,c
        cp      '0'
        jr      c,native_shell_user_bad
        cp      '6'
        jr      nc,native_shell_user_bad
        sub     '0'-10
        ld      b,a
        inc     de
        call    command_read
        cp      ':'
        jr      nz,native_shell_user_bad
native_shell_user_colon:
        inc     de
        call    command_read
        or      a
        jr      nz,native_shell_user_bad
        ld      a,b
        ld      (OPENPCW_COMMON_SCB_USER),a
        pop     de
        ld      a,2
        ret
native_shell_user_bad:
        pop     de
        xor     a
        ret

; The rendering body follows the shell's fixed bridge entry so additions to
; terminal presentation cannot silently move that separately assembled ABI.
terminal_draw_status_impl:
        ld      hl,status_text
        ld      de,0b2a8h
terminal_draw_status_character:
        ld      a,(hl)
        inc     hl
        or      a
        ret     z
        push    hl
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      bc,0b800h
        add     hl,bc
        ld      bc,8
        ldir
        pop     hl
        jr      terminal_draw_status_character
; The BIOSPB contains only AF/BC/DE/HL. Direct BIOS READ therefore selects
; the active drive's published XDPB explicitly instead of inheriting the
; transient program's unrelated IX value. This handler is kept after every
; fixed resident/native entry point so its private size cannot move an ABI.
.direct_read:
        ld      ix,0fb9ch
        ld      a,5
        jp      native_bios_disk

status_text:
        db      "Drive is A:",0

; Reconstruct the executable islands of application Page Zero through the F2
; paging window while this routine remains executable in protected page one.
; WBOOT can therefore retain a resident extension across commands even when
; that extension legitimately occupies every common byte below F000h. The
; caller restores F1/F2/F0 after return; IOBYTE and current drive survive.
native_warm_reset:
        xor     a
        ld      (key_pending_valid),a
        ld      a,085h
        ld      (0061h),a
        inc     a
        ld      (0062h),a
        ld      a,084h
        out     (0f2h),a
        ld      bc,(08003h)
        push    bc
        ld      hl,native_warm_page_zero_head
        ld      de,08000h
        ld      bc,8
        ldir
        pop     bc
        ld      (08003h),bc
        ld      hl,native_warm_interrupt
        ld      de,08038h
        ld      bc,12
        ldir
        ld      hl,(native_warm_retn)
        ld      (08066h),hl
        ld      hl,native_warm_low_bios
        ld      de,080e9h
        ld      bc,15
        ldir
        ret

native_warm_page_zero_head:
        db      0c3h,003h,0fch,0,0,0c3h,006h,0f6h
native_warm_interrupt:
        db      0c3h,066h,0ffh,0,0,0,0,0,0cdh,005h,000h,0c9h
native_warm_retn:
        db      0edh,045h
native_warm_low_bios:
        db      0c3h,003h,0fch,0c3h,003h,0fch,0c3h,006h,0fch
        db      0c3h,009h,0fch,0c3h,00ch,0fch

; Select a resident BDOS handler while physical page 8 is mapped at 4000h.
; Input is the function saved by the common bridge in ARGUMENT_A. Output is
; the absolute common-memory handler in HL; DE is preserved and Function 96
; additionally returns B=0. The generated table contains only symbol-derived
; addresses from this project's resident kernel.
    if $ != 05b3ah
        .error  "native BDOS selector entry moved"
    endif
native_bdos_select:
        ld      a,(OPENPCW_COMMON_ARGUMENT_A)
        cp      60
        jr      nc,.native_bdos_extended
        push    de
        ld      de,native_bdos_function_table
        jr      .native_bdos_indexed
.native_bdos_extended:
        cp      152
        jr      nz,.native_bdos_not_parse
        ld      hl,KERNEL_NATIVE_M_BDOS_CALL
        ret
.native_bdos_not_parse:
        cp      96
        jr      nz,.native_bdos_not_reserved_96
        ld      b,0
.native_bdos_not_reserved_96:
        cp      98
        jr      c,.native_bdos_unsupported
        sub     98
        jr      z,.native_bdos_zero
        cp      15
        jr      nc,.native_bdos_unsupported
        dec     a
        push    de
        ld      de,KERNEL_EXTENDED_TABLE
.native_bdos_indexed:
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ex      de,hl
        pop     de
        ret
.native_bdos_zero:
        ld      hl,KERNEL_ZERO_RESULT
        ret
.native_bdos_unsupported:
        ld      hl,KERNEL_UNSUPPORTED
        ret

native_bdos_function_table:
        dw      KERNEL_WARM_BOOT_PREPARE,KERNEL_BDOS_WAIT_CHARACTER
        dw      KERNEL_CONSOLE_OUTPUT,KERNEL_AUXILIARY_INPUT
        dw      KERNEL_NO_DEVICE_STATUS,KERNEL_NO_DEVICE_STATUS
        dw      KERNEL_DIRECT_CONSOLE,KERNEL_NO_DEVICE_STATUS
        dw      KERNEL_NO_DEVICE_STATUS,KERNEL_PRINT_STRING
        dw      KERNEL_BDOS_READ_LINE,KERNEL_CONSOLE_STATUS
        dw      KERNEL_VERSION,KERNEL_RESET_DISK,KERNEL_SELECT_DISK
        dw      KERNEL_OPEN_FILE,KERNEL_CLOSE_FILE
        dw      KERNEL_NATIVE_M_BDOS_CALL,KERNEL_NATIVE_M_BDOS_CALL
        dw      KERNEL_NATIVE_M_BDOS_CALL,KERNEL_NATIVE_M_BDOS_CALL
        dw      KERNEL_NATIVE_M_BDOS_CALL,KERNEL_NATIVE_M_BDOS_CALL
        dw      KERNEL_NATIVE_M_BDOS_CALL,KERNEL_NATIVE_M_BDOS_CALL
        dw      KERNEL_CURRENT_DISK,KERNEL_SET_DMA
        dw      KERNEL_NATIVE_M_BDOS_CALL,KERNEL_NATIVE_M_BDOS_CALL
        dw      KERNEL_NATIVE_M_BDOS_CALL,KERNEL_NATIVE_M_BDOS_CALL
        dw      KERNEL_NATIVE_M_BDOS_CALL,KERNEL_USER_CODE
        dw      KERNEL_NATIVE_M_BDOS_CALL,KERNEL_NATIVE_M_BDOS_CALL
        dw      KERNEL_NATIVE_M_BDOS_CALL,KERNEL_NATIVE_M_BDOS_CALL
        dw      KERNEL_RESET_DRIVES,KERNEL_ZERO_RESULT,KERNEL_ZERO_RESULT
        dw      KERNEL_NATIVE_M_BDOS_CALL,KERNEL_UNSUPPORTED
        dw      KERNEL_ZERO_RESULT,KERNEL_ZERO_RESULT
        dw      KERNEL_SET_MULTISECTOR,KERNEL_SET_ERROR_MODE
        dw      KERNEL_NATIVE_M_BDOS_CALL,KERNEL_CHAIN_PROGRAM
        dw      KERNEL_ZERO_RESULT,KERNEL_SCB
        dw      KERNEL_NATIVE_DIRECT_BIOS_CALL
        dw      KERNEL_UNSUPPORTED,KERNEL_UNSUPPORTED,KERNEL_UNSUPPORTED
        dw      KERNEL_UNSUPPORTED,KERNEL_UNSUPPORTED,KERNEL_UNSUPPORTED
        dw      KERNEL_UNSUPPORTED,KERNEL_UNSUPPORTED
        dw      KERNEL_NATIVE_M_BDOS_CALL
native_bdos_function_table_end:
    if native_bdos_function_table_end-native_bdos_function_table != 120
        .error  "native BDOS selector table must contain functions 0..59"
    endif

; Only live code/data may precede this boundary.  The packed font and unpacker
; are deliberately transient: native_init consumes them before the shell runs.
native_runtime_end:
font_bitmap:
        incbin  "native_font.bin"

; Expand the lossless row-dictionary representation generated by build.py.
; The first 64 bytes are the row dictionary; each following three bytes hold
; four 6-bit indices. B=0 deliberately gives the 256 iterations needed for
; all 1024 rows.
native_unpack_font:
        ld      hl,font_bitmap+64
        ld      de,0b800h
        ld      b,0
native_unpack_font_group:
        ld      a,(hl)
        inc     hl
        ld      (native_unpack_font_byte0),a
        ld      a,(hl)
        inc     hl
        ld      (native_unpack_font_byte1),a
        ld      a,(hl)
        inc     hl
        ld      (native_unpack_font_byte2),a

        ld      a,(native_unpack_font_byte0)
        and     3fh
        call    native_unpack_font_emit

        ld      a,(native_unpack_font_byte0)
        rlca
        rlca
        and     03h
        ld      c,a
        ld      a,(native_unpack_font_byte1)
        and     0fh
        add     a,a
        add     a,a
        or      c
        call    native_unpack_font_emit

        ld      a,(native_unpack_font_byte1)
        rrca
        rrca
        rrca
        rrca
        and     0fh
        ld      c,a
        ld      a,(native_unpack_font_byte2)
        and     03h
        add     a,a
        add     a,a
        add     a,a
        add     a,a
        or      c
        call    native_unpack_font_emit

        ld      a,(native_unpack_font_byte2)
        rrca
        rrca
        and     3fh
        call    native_unpack_font_emit
        djnz    native_unpack_font_group
        ret

native_unpack_font_emit:
        push    hl
        push    bc
        ld      l,a
        ld      h,0
        ld      bc,font_bitmap
        add     hl,bc
        ld      a,(hl)
        pop     bc
        pop     hl
        ld      (de),a
        inc     de
        ret

native_unpack_font_byte0: db 0
native_unpack_font_byte1: db 0
native_unpack_font_byte2: db 0

; Finish the cold-only Screen/BIOS Page Zero specialisation after the font
; source has been consumed. Its CONST and CONIN veneers restore blocks 0/1/2
; after private keyboard services; the independently rebuilt TPA page retains
; the ordinary BIOS vectors. Symbolic resident addresses come from the
; generated kernel dispatch include.
native_init_screen_vectors:
        ld      hl,KERNEL_LOW_BIOS_CONSOLE_STATUS
        ld      (00f0h),hl
        ld      hl,KERNEL_LOW_BIOS_CONSOLE_INPUT
        ld      (00f3h),hl
        jp      native_init_finish

; BDOS Function 49 operates on the four-byte request copied by the common
; bridge to resident scratch. The SCB itself is common memory, so this mapped
; private routine never exposes a transient paging window while executing.
native_scb_result:
        call    KERNEL_NATIVE_SCB_SYNC
        ld      hl,(m_fcb)
        ld      a,(hl)
        cp      100
        jr      nc,.native_scb_zero
        ld      c,a
        inc     hl
        ld      a,(hl)
        or      a
        jr      z,.native_scb_read
        cp      0ffh
        jr      z,.native_scb_write_byte
        cp      0feh
        jr      z,.native_scb_write_word
        jr      .native_scb_zero
.native_scb_read:
        ld      l,c
        ld      h,0
        ld      de,OPENPCW_COMMON_SCB
        add     hl,de
        ld      c,(hl)
        inc     hl
        ld      b,(hl)
        jr      .native_scb_finish
.native_scb_write_byte:
        inc     hl
        ld      a,(hl)
        ld      b,0
        jr      .native_scb_store
.native_scb_write_word:
        ld      a,c
        cp      99
        jr      nc,.native_scb_zero
        inc     hl
        ld      a,(hl)
        inc     hl
        ld      b,(hl)
.native_scb_store:
        push    af
        ld      l,c
        ld      h,0
        ld      de,OPENPCW_COMMON_SCB
        add     hl,de
        pop     af
        ld      (hl),a
        ld      c,a
        inc     hl
        ld      (hl),b
        call    KERNEL_NATIVE_SCB_APPLY
        jr      .native_scb_finish
.native_scb_zero:
        ld      bc,0
.native_scb_finish:
        ld      h,b
        ld      l,c
        ld      a,c
        ret

native_kernel_end:

; Mutable keyboard tables are BSS, not part of the physical boot payload.
; keyboard_init_page_one clears every validity/length byte before use, so
; loading thousands of irrelevant zeroes from floppy would only delay boot
; and would provide no deterministic state that the API can observe.
; BSS follows the loaded private services and remains below the physical-page
; boundary checked by the builder. Its symbols are internal to this module.
        defs    89,0
keyboard_override_valid: defs 81,0
keyboard_override_values: defs 81*5,0
keyboard_expansion_lengths: defs 31,0
keyboard_expansion_slots: defs 31*128,0
keyboard_long_expansion: defs 255,0
native_kernel_bss_end:

; Physical block three is a boot-time Open/cursor overlay. It is deliberately
; outside the contiguous page-zero/page-one payload and is extracted
; separately by the source builder, so the ORG gap never consumes sectors on
; disk. Takeover programs may reuse it; persistent OS state lives elsewhere.
        org     08000h
native_open_overlay_start:
        native_open_overlay_blob
        ; Preserve the established cursor-overlay address without placing any
        ; persistent interrupt code in application-reusable block three.
        defs    08400h-$,0

; Cursor overlay. These helpers need no F2-resident data and therefore can
; share physical block three with Open.
m_normalize_deferred_cursor_overlay:
        ld      a,(m_cr)
        cp      080h
        jp      nz,native_open_restore_page_two
        xor     a
        ld      (m_cr),a
        ld      a,(m_ex)
        inc     a
        and     01fh
        ld      (m_ex),a
        jr      nz,.m_normalize_done
        ld      a,(m_s2)
        inc     a
        and     03fh
        ld      (m_s2),a
.m_normalize_done:
        jp      native_open_restore_page_two

; Input C is the new low six S2 bits. Reads activate the FCB; every write
; clears that flag after changing file state.
a_write_fcb_s2_overlay:
        ld      hl,(m_fcb)
        ld      de,14
        add     hl,de
        ld      a,(m_function)
        cp      20
        jr      z,.a_write_fcb_s2_read
        cp      33
        ld      a,c
        jr      nz,.a_write_fcb_s2_store
.a_write_fcb_s2_read:
        ld      a,c
        or      080h
.a_write_fcb_s2_store:
        call    gencom_tpa_write
        jp      native_open_restore_page_two

m_write_random_cr_overlay:
        ld      hl,(m_fcb)
        ld      de,32
        add     hl,de
        ld      a,(m_record)
        and     07fh
        call    gencom_tpa_write
        jp      native_open_restore_page_two

sparse_lowest_valid_record_overlay:
        ld      a,c
        call    sparse_valid_address
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      a,d
        or      e
        jr      z,.lowest_overlay_no_valid
        ld      c,0
.lowest_overlay_shift:
        bit     0,e
        ld      a,c
        jr      nz,.lowest_overlay_found
        srl     d
        rr      e
        inc     c
        jr      .lowest_overlay_shift
.lowest_overlay_found:
        or      a
        jp      native_open_restore_page_two
.lowest_overlay_no_valid:
        scf
        jp      native_open_restore_page_two

m_advance_sequential_fcb_overlay:
        ; Derive the committed cursor from the absolute record just
        ; transferred, not from directory metadata which a physical extent
        ; load is entitled to copy over the public FCB.
        ld      hl,(m_record)
        inc     hl
        ld      a,(m_record+2)
        ld      c,a
        ld      a,h
        or      l
        ld      a,c
        jr      nz,.m_next_record_ready
        inc     a
.m_next_record_ready:
        ld      d,a
        ld      a,l
        and     07fh
        jr      z,.m_deferred_boundary
        ld      (m_cr),a
        ld      a,d
        jr      .m_cursor_value_ready
.m_deferred_boundary:
        ld      a,080h
        ld      (m_cr),a
        ld      hl,(m_record)
        ld      a,(m_record+2)
.m_cursor_value_ready:
        ld      b,7
.m_cursor_extent_shift:
        srl     a
        rr      h
        rr      l
        djnz    .m_cursor_extent_shift
        ld      a,l
        and     01fh
        ld      (m_ex),a
        xor     a
        ld      b,5
.m_cursor_s2_shift:
        srl     h
        rr      l
        djnz    .m_cursor_s2_shift
        ld      a,l
        and     03fh
        ld      (m_s2),a

        ld      hl,(m_fcb)
        ld      de,12
        add     hl,de
        ld      a,(m_ex)
        call    gencom_tpa_write
        inc     hl
        inc     hl
        ld      a,(m_s2)
        ld      c,a
        ld      a,c
        ld      b,a
        ld      a,(m_function)
        cp      21
        ld      a,b
        jr      z,.m_cursor_s2_ready
        or      080h
        call    gencom_tpa_write
        jr      .m_cursor_cr
.m_cursor_s2_ready:
        call    gencom_tpa_write
.m_cursor_cr:
        ld      hl,(m_fcb)
        ld      de,32
        add     hl,de
        ld      a,(m_cr)
        call    gencom_tpa_write
        jp      native_open_restore_page_two

; A random read of an unwritten record still activates EX/S2 when its
; normalized extent exists. A genuinely absent extent (status 4) leaves those
; fields untouched; CR was already set from R0 when the request began.
native_random_failure_status_overlay:
        cp      1
        ret     nz
        push    af
        call    native_commit_random_extent_overlay
        pop     af
        ret

native_commit_random_extent_overlay:
        ld      hl,(m_record)
        ld      a,(m_record+2)
        ld      b,7
.random_extent_shift:
        srl     a
        rr      h
        rr      l
        djnz    .random_extent_shift
        ld      a,l
        and     01fh
        ld      c,a
        ld      hl,(m_fcb)
        ld      de,12
        add     hl,de
        ld      a,c
        call    gencom_tpa_write
        inc     hl
        inc     hl
        ld      de,(m_record)
        ld      a,(m_record+2)
        ld      b,12
.random_s2_shift:
        srl     a
        rr      d
        rr      e
        djnz    .random_s2_shift
        ld      a,e
        and     03fh
        or      080h
        jp      gencom_tpa_write

; Materialise M:'s ordinary CP/M allocation map in the caller's FCB.  The
; sparse implementation keeps private allocation keys, but applications are
; entitled to observe the public 2 KiB block numbers returned by OPEN.  Blocks
; zero and one belong to the 4 KiB directory, so dense allocation index N is
; published as block N+2.  EXM=1 means one FCB map describes the normalized
; pair of raw extents (sixteen logical blocks / 256 records).
m_open_fill_allocations:
        ld      hl,(m_record)
        ld      a,(m_record+2)
        ld      b,4
.m_open_allocation_key_shift:
        srl     a
        rr      h
        rr      l
        djnz    .m_open_allocation_key_shift
        ld      c,a
        ld      a,l
        and     0f0h                   ; normalized EXM=1 directory group
        ld      l,a
        ld      (sparse_block_key),hl
        ld      a,c
        ld      (sparse_block_key+2),a
        ld      hl,(m_fcb)
        ld      de,16
        add     hl,de
        ld      (m_open_allocation_fcb),hl
        ld      a,16
        ld      (m_open_allocation_left),a
.m_open_allocation_slot:
        ld      a,SPARSE_METADATA_PAGE
        out     (0f1h),a
        ld      ix,SPARSE_ALLOCATION_BASE
        ld      a,(native_m_data_blocks)
        ld      b,a
        ld      c,2
.m_open_allocation_scan:
        ld      a,(m_slot)
        cp      (ix+0)
        jr      nz,.m_open_allocation_next
        ld      a,(sparse_block_key)
        cp      (ix+1)
        jr      nz,.m_open_allocation_next
        ld      a,(sparse_block_key+1)
        cp      (ix+2)
        jr      nz,.m_open_allocation_next
        ld      a,(sparse_block_key+2)
        cp      (ix+3)
        ld      a,c
        jr      z,.m_open_allocation_write
.m_open_allocation_next:
        ld      de,4
        add     ix,de
        inc     c
        djnz    .m_open_allocation_scan
        xor     a
.m_open_allocation_write:
        ld      hl,(m_open_allocation_fcb)
        call    native_open_tpa_write
        inc     hl
        ld      (m_open_allocation_fcb),hl
        ld      hl,sparse_block_key
        inc     (hl)
        jr      nz,.m_open_allocation_key_ready
        inc     hl
        inc     (hl)
        jr      nz,.m_open_allocation_key_ready
        inc     hl
        inc     (hl)
.m_open_allocation_key_ready:
        ld      a,(m_open_allocation_left)
        dec     a
        ld      (m_open_allocation_left),a
        jr      nz,.m_open_allocation_slot
        ret

m_open_allocation_fcb:  dw 0
m_open_allocation_left: db 0

; CLOSE is dispatched through the F2-resident overlay so page zero only needs
; the six-byte bridge above.  Besides validating the FCB, closing M: commits
; the private sparse metadata to the ordinary CP/M directory image that raw
; disk readers are entitled to inspect.
m_close_overlay:
        call    a_name_is_exact
        jr      c,.m_close_overlay_bad
        call    m_find
        jr      c,.m_close_overlay_bad
        jp      m_sync_public_directory_after_write
.m_close_overlay_bad:
        ld      a,0ffh
        ret

m_sync_public_directory_after_write:
        ld      a,OPENPCW_RUNTIME_PAGE
        out     (0f1h),a
        call    m_open_compute_size
        call    m_open_fill_allocations
        xor     a
        ld      (m_open_byte_count),a
        call    m_sync_public_directory_entry
        xor     a
        ret

; Mirror the activated FCB into its standard 32-byte M: directory slot. The
; staging buffer is F2-resident, so the routine can alternate between the
; caller's transient bank and public page 9 without hiding its own data.
m_sync_public_directory_entry:
        ld      hl,(m_fcb)
        ld      de,m_public_directory_buffer
        ld      b,32
.m_public_directory_fetch:
        call    native_open_tpa_read
        ld      (de),a
        inc     hl
        inc     de
        djnz    .m_public_directory_fetch
        ld      a,(m_match_user)
        dec     a
        and     00fh
        ld      (m_public_directory_buffer),a
        ld      a,(m_open_byte_count)
        ld      (m_public_directory_buffer+13),a
        xor     a
        ld      (m_public_directory_buffer+14),a

        ; The first EXM=1 directory group represents up to 256 records. Derive
        ; its actual raw extent and RC from the private sparse file size rather
        ; than from a writer's transient cursor fields.
        ld      hl,(native_size)
        ld      a,(native_size+2)
        or      a
        jr      nz,.m_public_directory_full_group
        ld      a,h
        or      a
        jr      nz,.m_public_directory_full_group
        ld      a,l
        cp      129
        jr      c,.m_public_directory_low_extent
        sub     128
        ld      (m_public_directory_buffer+15),a
        ld      a,1
        ld      (m_public_directory_buffer+12),a
        jr      .m_public_directory_extent_ready
.m_public_directory_low_extent:
        ld      (m_public_directory_buffer+15),a
        xor     a
        ld      (m_public_directory_buffer+12),a
        jr      .m_public_directory_extent_ready
.m_public_directory_full_group:
        ld      a,128
        ld      (m_public_directory_buffer+15),a
        ld      a,1
        ld      (m_public_directory_buffer+12),a
.m_public_directory_extent_ready:

        ld      a,(m_slot)
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      de,04000h
        add     hl,de
        ex      de,hl
        ld      a,089h
        out     (0f1h),a
        ld      hl,m_public_directory_buffer
        ld      bc,32
        ldir
        ld      a,OPENPCW_RUNTIME_PAGE
        out     (0f1h),a
        ret

m_public_directory_buffer: defs 32,0

sparse_map_data_overlay:
        ld      hl,(sparse_data_index)
        ld      de,32                  ; two 2 KiB directory blocks
        add     hl,de
        push    hl
        ld      b,7
.sparse_overlay_bank:
        srl     h
        rr      l
        djnz    .sparse_overlay_bank
        ld      a,l
        add     a,089h                 ; physical M: begins at page 9
        out     (0f1h),a
        pop     hl
        ld      a,l
        and     07fh
        ld      c,a
        and     1
        rrca
        ld      l,a
        ld      a,c
        srl     a
        add     a,040h
        ld      h,a
        ld      a,(sparse_allocation_new)
        or      a
        jr      z,.sparse_overlay_ready
        xor     a
        ld      (sparse_allocation_new),a
        push    hl
        ld      a,h
        and     0f8h
        ld      h,a
        ld      l,0
        ld      d,h
        ld      e,l
        inc     de
        ld      (hl),0e5h
        ld      bc,2047
        ldir
        pop     hl
.sparse_overlay_ready:
        jp      native_open_restore_page_two

; The page-zero filesystem bank is deliberately full. Keep the comparatively
; rare Function 59 overlay loader in this boot-time F2 overlay; its callers
; already restore the ordinary TPA mapping after it returns.
m_load_overlay_entry:
        ; Keep the cursor overlay mapped across every nested sparse-M helper.
        ; The restore trampoline is protected in physical block zero, so its
        ; immediate page shadow remains writable while this block executes.
        ; Its ordinary value is 82h, making this single increment the compact
        ; transition to the cursor-overlay page required by nested helpers.
        ld      hl,native_open_restore_page_value
        inc     (hl)
m_load_overlay_overlay:
        call    m_find
        jr      c,.m_overlay_bad
        call    m_overlay_read_address
        call    m_find_lowest_record
        jr      c,.m_overlay_bad
        ld      hl,(m_lowest+1)
        ld      a,h
        or      l
        jr      nz,.m_overlay_bridge
        ld      a,(m_lowest)
        cp      128
        jr      nc,.m_overlay_bridge
        call    m_overlay_generic
        jr      .m_overlay_finish
.m_overlay_bridge:
        call    m_overlay_sparse_bridge
        jr      nc,.m_overlay_finish
.m_overlay_bad:
        ld      a,1
.m_overlay_finish:
        ; Publish the ordinary native block before the common trampoline
        ; performs its AF-transparent OUT and returns to the BDOS dispatcher.
        ld      hl,native_open_restore_page_value
        ld      (hl),082h
        jp      native_open_restore_page_two

; BDOS 59 with DE=0 performs the published LOADER maintenance operation: it
; removes every resident extension whose prefix flag is FFh and repairs both
; directions of the chain. GET uses this after returning its final redirected
; line. All links live in common memory; only Page Zero needs the bank-aware
; writer because this routine executes while the native service page is mapped.
native_prune_rsx_overlay:
        ld      a,(OPENPCW_COMMON_GENCOM_MODE)
        or      a
        jp      z,.prune_bad
        ld      hl,(OPENPCW_COMMON_GENCOM_CHAIN)
        ld      iy,0007h                 ; high byte of Page Zero's JP operand
        ld      b,16                     ; at most fifteen GENCOM descriptors
.prune_next:
        ld      de,0f306h                ; independent LOADER prefix entry
        or      a
        sbc     hl,de
        jp      z,.prune_done
        add     hl,de
        ld      a,h
        cp      0c0h
        jp      c,.prune_bad
        cp      0f3h
        jp      nc,.prune_bad
        ld      de,0fffah                ; entry -> 27-byte prefix base
        add     hl,de
        push    hl
        pop     ix
        ld      a,(ix+9)
        cp      0c3h
        jp      nz,.prune_bad
        ld      e,(ix+10)
        ld      d,(ix+11)
        call    .prune_validate_next
        jp      c,.prune_bad
        ld      a,(ix+14)
        cp      0ffh
        jr      z,.prune_remove
        push    de                      ; retain the next chain entry
        ld      de,11                   ; high byte of this NEXT operand
        add     hl,de
        push    hl
        pop     iy
        pop     hl                      ; continue at the retained next entry
        djnz    .prune_next
        jp      .prune_bad

.prune_remove:
        push    de                      ; next entry
        push    bc                      ; descriptor guard
        push    iy
        pop     hl                      ; previous forward-link high byte
        ld      a,h
        or      a
        jr      nz,.prune_patch_previous
        call    .prune_publish_chain    ; removed the current public head
        jr      .prune_patch_next
.prune_patch_previous:
        dec     hl
        ld      (hl),e
        inc     hl
        ld      (hl),d
.prune_patch_next:
        pop     bc
        pop     hl                      ; next entry becomes current entry
        push    hl
        ld      de,6                    ; next entry + 6 = backward-link word
        add     hl,de
        push    iy
        pop     de
        ld      (hl),e
        inc     hl
        ld      (hl),d
        pop     hl
        djnz    .prune_next
        jp      .prune_bad

.prune_done:
        push    iy
        pop     hl
        ld      a,h
        or      l
        cp      7
        jr      nz,.prune_retained
        xor     a
        ld      (OPENPCW_COMMON_GENCOM_MODE),a
        ld      de,0f609h               ; private native BDOS implementation
        call    .prune_publish_chain
        ld      hl,0f000h
        ld      (gencom_rsx_low),hl
        ld      hl,0
        ret
.prune_retained:
        ld      de,(OPENPCW_COMMON_GENCOM_CHAIN)
        ld      h,d
        ld      l,e
        ld      de,0fffah
        add     hl,de
        ld      (gencom_rsx_low),hl
        xor     a
        ld      l,a
        ld      h,a
        ret

; Carry means that DE is neither a common-memory RSX entry nor F306h.
.prune_validate_next:
        ld      a,d
        cp      0f3h
        jr      nz,.prune_validate_module
        ld      a,e
        cp      06h
        ret     z
        scf
        ret
.prune_validate_module:
        cp      0c0h
        jr      c,.prune_invalid_next
        cp      0f3h
        jr      nc,.prune_invalid_next
        cp      0c0h
        jr      nz,.prune_valid_next
        ld      a,e
        cp      6
        jr      c,.prune_invalid_next
.prune_valid_next:
        or      a
        ret
.prune_invalid_next:
        scf
        ret

.prune_publish_chain:
        ld      (OPENPCW_COMMON_GENCOM_CHAIN),de
        push    hl
        ld      hl,0006h
        ld      a,e
        call    gencom_tpa_write
        inc     hl
        ld      a,d
        call    gencom_tpa_write
        pop     hl
        ret
.prune_bad:
        ld      a,0ffh
        ld      l,a
        ld      h,0
        ret

; Construct the CCP-owned part of Page Zero for a native command. The source
; may be the resident shell buffer or BDOS 47's transient DMA. Copy it into
; the block-three overlay before clearing 0050h..00FFh, then publish the
; source-drive byte, both default FCBs and an upper-case command tail.
native_prepare_command_page_zero_overlay:
        ld      hl,native_command_line_buffer
        ld      b,127
.copy_source:
        call    .source_read
        ld      (hl),a
        inc     hl
        inc     de
        or      a
        jr      z,.source_ready
        djnz    .copy_source
        xor     a
        ld      (hl),a
.source_ready:
        ld      de,native_command_line_buffer
        xor     a
        ld      hl,0050h
        ld      b,0b0h                  ; through the end of Page Zero
.clear_page_zero_fields:
        call    native_open_tpa_write
        inc     hl
        djnz    .clear_page_zero_fields
        ld      hl,0050h
        ld      a,1                     ; command was resolved on drive A:
        call    native_open_tpa_write

; command_name has already consumed the executable token and leaves DE on
; its terminating blank (or NUL). Retain the first operand as the command
; tail; treating DE as the complete line would silently discard operand one.
.skip_leading_space:
        ld      a,(de)
        cp      ' '
        jr      nz,.tail_ready
        inc     de
        jr      .skip_leading_space
.tail_ready:
        or      a
        jr      z,.no_tail
        push    de                      ; original tail for FCB 2 and 0080h
        ld      hl,005ch
        call    .fill_fcb
        pop     de
        push    de

; The second default FCB starts after '=' or after the first blank-delimited
; operand, matching the CCP convention used by copy/rename-style utilities.
.find_second:
        ld      a,(de)
        or      a
        jr      z,.second_ready
        cp      '='
        jr      z,.second_after_equals
        cp      ' '
        jr      z,.second_after_space
        inc     de
        jr      .find_second
.second_after_equals:
        inc     de
        jr      .second_ready
.second_after_space:
        inc     de
        ld      a,(de)
        cp      ' '
        jr      z,.second_after_space
.second_ready:
        ld      hl,006ch
        call    .fill_fcb
        pop     de

; Count at most 126 operand bytes, prefix the conventional separating blank,
; upper-case every command-tail byte, and terminate it with carriage return.
        push    de
        ld      b,0
.count_tail:
        ld      a,(de)
        or      a
        jr      z,.tail_counted
        inc     de
        inc     b
        ld      a,b
        cp      126
        jr      c,.count_tail
.tail_counted:
        pop     de
        ld      a,b
        or      a
        jr      z,.no_tail
        inc     a
        ld      hl,0080h
        call    native_open_tpa_write
        inc     hl
        ld      a,' '
        call    native_open_tpa_write
        inc     hl
.copy_tail:
        ld      a,(de)
        call    uppercase_a
        call    native_open_tpa_write
        inc     de
        inc     hl
        djnz    .copy_tail
        ld      a,13
        call    native_open_tpa_write
        jp      native_open_restore_page_two
.no_tail:
        ; CCP still publishes blank 8.3 fields for both unopened default
        ; FCBs when there are no operands; all-zero names are observably
        ; different to programs which inspect Page Zero directly.
        push    de
        ld      hl,005ch
        call    .fill_fcb
        pop     de
        ld      hl,006ch
        call    .fill_fcb
        ld      hl,0080h
        xor     a
        call    native_open_tpa_write
        inc     hl
        ld      a,13
        call    native_open_tpa_write
        jp      native_open_restore_page_two

; Input HL is a default FCB address and DE names one argument in the local
; command copy. The 36 bytes are already zero, so only drive/name/type need
; publication; '*' expands to the remaining '?' positions as CP/M specifies.
.fill_fcb:
        push    hl
        push    de
        ld      a,(de)
        or      a
        jr      nz,.fcb_have_first
        pop     de
        jr      .fcb_default_drive
.fcb_have_first:
        call    uppercase_a
        ld      c,a
        inc     de
        ld      a,(de)
        cp      ':'
        pop     de
        jr      nz,.fcb_default_drive
        ld      a,c
        cp      'A'
        jr      c,.fcb_default_drive
        cp      'Z'+1
        jr      nc,.fcb_default_drive
        sub     'A'-1
        call    native_open_tpa_write
        inc     de
        inc     de
        jr      .fcb_drive_ready
.fcb_default_drive:
        xor     a
        call    native_open_tpa_write
.fcb_drive_ready:
        pop     hl
        inc     hl
        push    de
        ld      b,11
        ld      a,' '
.fcb_spaces:
        call    native_open_tpa_write
        inc     hl
        djnz    .fcb_spaces
        pop     de
        ld      bc,0fff5h               ; rewind eleven name/type positions
        add     hl,bc
        ld      b,8
.fcb_stem:
        ld      a,(de)
        or      a
        ret     z
        cp      ' '
        ret     z
        cp      '='
        ret     z
        cp      '.'
        jr      z,.fcb_extension_start
        cp      '*'
        jr      z,.fcb_stem_wildcard
        call    uppercase_a
        call    native_open_tpa_write
        inc     hl
        inc     de
        djnz    .fcb_stem
.fcb_skip_stem:
        ld      a,(de)
        or      a
        ret     z
        cp      ' '
        ret     z
        cp      '='
        ret     z
        inc     de
        cp      '.'
        jr      nz,.fcb_skip_stem
        jr      .fcb_extension_ready
.fcb_stem_wildcard:
        ld      a,'?'
.fcb_fill_stem_wildcard:
        call    native_open_tpa_write
        inc     hl
        djnz    .fcb_fill_stem_wildcard
        inc     de
        jr      .fcb_skip_stem
.fcb_extension_start:
        inc     de
        ld      c,b
        ld      b,0
        add     hl,bc
.fcb_extension_ready:
        ld      b,3
.fcb_extension:
        ld      a,(de)
        or      a
        ret     z
        cp      ' '
        ret     z
        cp      '='
        ret     z
        cp      '*'
        jr      z,.fcb_extension_wildcard
        call    uppercase_a
        call    native_open_tpa_write
        inc     hl
        inc     de
        djnz    .fcb_extension
        ret
.fcb_extension_wildcard:
        ld      a,'?'
.fcb_fill_extension_wildcard:
        call    native_open_tpa_write
        inc     hl
        djnz    .fcb_fill_extension_wildcard
        ret

; The original pointer can address resident common RAM or a caller's bank-one
; transient. Restore native page one after every abstract TPA read because the
; overlay itself continues executing through F2.
.source_read:
        ld      a,d
        cp      0c0h
        jr      nc,.source_common
        push    hl
        push    de
        pop     hl
        call    native_open_tpa_read
        pop     hl
        ret
.source_common:
        ld      a,(de)
        ret

native_command_line_buffer:
        defs    128,0
native_open_overlay_end:
        ; Track 7 stores the two service regions as one contiguous image.
        ; The password region begins exactly where the Open/cursor region ends.
        org     0899eh
native_password_overlay_start:
native_a_overlay_dispatch:
        ld      a,(m_function)
        cp      19
        jp      z,a_secure_mutation_overlay
        cp      23
        jp      z,a_secure_mutation_overlay
        cp      30
        jp      z,a_secure_mutation_overlay
        cp      99
        jp      z,a_secure_mutation_overlay
        cp      22
        jp      z,a_make_password_overlay
        cp      100
        jp      z,a_set_label_overlay
        cp      102
        jp      z,a_read_password_mode_overlay
        cp      103
        jp      z,a_write_xfcb_overlay
        jp      a_open

native_m_overlay_dispatch:
        ld      a,(m_function)
        cp      17
        jp      z,m_search_special_overlay
        cp      18
        jp      z,m_search_special_overlay
        cp      19
        jp      z,m_secure_mutation_overlay
        cp      23
        jp      z,m_secure_mutation_overlay
        cp      30
        jp      z,m_secure_mutation_overlay
        cp      99
        jp      z,m_secure_mutation_overlay
        cp      22
        jp      z,m_make_password_overlay
        cp      100
        jp      z,m_set_label_overlay
        cp      102
        jp      z,m_read_stamps_overlay
        cp      103
        jp      z,m_write_xfcb_overlay
        jp      m_open_page_one

; Scan A:'s public directory for the current user's XFCB matching m_name.
; Carry means absent (A=0) or physical read failure (A=FFh), mirroring the
; ordinary extent helpers in the resident filesystem code.
a_find_xfcb_overlay:
        ld      a,(a_find_user)
        add     a,010h
        ld      (a_found),a
        xor     a
        ld      (a_dir_sector),a
.a_xfcb_sector:
        ld      a,(a_dir_sector)
        ld      c,a
        ld      a,(disk_dir_sectors)
        cp      c
        jr      z,.a_xfcb_missing
        call    a_directory_sector_address
        call    read_logical_sector
        jr      c,.a_xfcb_io
        ld      ix,sector_buffer
        ld      b,16
        ld      c,0
.a_xfcb_entry:
        ld      a,(a_found)
        cp      (ix+0)
        jr      nz,.a_xfcb_advance
        push    bc
        call    a_entry_name_exact
        pop     bc
        jr      z,.a_xfcb_found
.a_xfcb_advance:
        ld      de,32
        add     ix,de
        inc     c
        djnz    .a_xfcb_entry
        ld      a,(a_dir_sector)
        inc     a
        ld      (a_dir_sector),a
        jr      .a_xfcb_sector
.a_xfcb_found:
        ld      a,c
        ld      (a_dir_index),a
        xor     a
        ret
.a_xfcb_missing:
        xor     a
        scf
        ret
.a_xfcb_io:
        ld      a,0ffh
        scf
        ret

; Return NZ only when A: has an active directory label with password support.
a_passwords_enabled_overlay:
        ld      a,020h
        call    a_find_special
        jr      c,.a_passwords_not_found
        bit     7,(ix+12)
        jr      z,.a_passwords_disabled
        ld      a,1
        or      a
        ret
.a_passwords_not_found:
        or      a
        ret     nz
.a_passwords_disabled:
        xor     a
        ret

; XFCB password records follow REF-CPM3-DISK (Password encryption system):
; checksum=sum(plain bytes) modulo 256; stored bytes=reverse(plain) XOR checksum.
; This banked implementation reads caller data through native_open_tpa_read.
; IX addresses the XFCB. Return Z if DMA[0..7] or the default password matches.
a_xfcb_password_matches_overlay:
        ld      a,(ix+13)
        ld      (m_password_checksum),a
        push    ix
        pop     de
        ld      hl,23
        add     hl,de
        ex      de,hl
        ld      hl,(m_dma)
        ld      b,8
.a_password_dma_byte:
        call    native_open_tpa_read
        ld      (m_password_byte),a
        ld      a,(de)
        ld      c,a
        ld      a,(m_password_checksum)
        xor     c
        ld      c,a
        ld      a,(m_password_byte)
        cp      c
        jr      nz,.a_password_try_default
        inc     hl
        dec     de
        djnz    .a_password_dma_byte
        xor     a
        ret
.a_password_try_default:
        push    ix
        pop     de
        ld      hl,23
        add     hl,de
        ex      de,hl
        ld      hl,native_default_password
        ld      b,8
.a_password_default_byte:
        ld      a,(de)
        ld      c,a
        ld      a,(m_password_checksum)
        xor     c
        cp      (hl)
        jr      nz,.a_password_bad
        inc     hl
        dec     de
        djnz    .a_password_default_byte
        xor     a
        ret
.a_password_bad:
        ld      a,1
        or      a
        ret

; Encode DMA[8..15] into the XFCB selected in IX.
a_encode_xfcb_password_overlay:
        ld      hl,(m_dma)
        ld      de,8
        add     hl,de
        ld      b,8
        xor     a
.a_password_sum:
        ld      c,a
        call    native_open_tpa_read
        add     a,c
        inc     hl
        djnz    .a_password_sum
        ld      (ix+13),a
        ld      (m_password_checksum),a
        ld      hl,(m_dma)
        ld      de,15
        add     hl,de
        push    ix
        pop     de
        ex      de,hl
        ld      bc,16
        add     hl,bc
        ex      de,hl
        ld      b,8
.a_password_encode:
        call    native_open_tpa_read
        ld      c,a
        ld      a,(m_password_checksum)
        xor     c
        ld      (de),a
        dec     hl
        inc     de
        djnz    .a_password_encode
        ret

a_init_xfcb_overlay:
        push    ix
        pop     hl
        xor     a
        ld      b,32
.a_xfcb_clear:
        ld      (hl),a
        inc     hl
        djnz    .a_xfcb_clear
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        add     a,010h
        ld      (ix+0),a
        push    ix
        pop     hl
        inc     hl
        ld      de,m_name
        ld      b,11
.a_xfcb_name:
        ld      a,(de)
        ld      (hl),a
        inc     de
        inc     hl
        djnz    .a_xfcb_name
        ret

a_write_xfcb_overlay:
        ; Function 103 mutates directory metadata and therefore obeys the
        ; temporary read-only vector exactly like the ordinary A: writers.
        call    a_prepare
        jr      c,.a_write_xfcb_bad
        call    a_name_is_exact
        jr      c,.a_write_xfcb_name_bad
        ld      hl,(m_fcb)
        ld      de,12
        add     hl,de
        call    native_open_tpa_read
        ld      (m_xfcb_mode),a
        call    a_passwords_enabled_overlay
        cp      1
        jr      nz,.a_write_xfcb_bad
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        ld      (a_find_user),a
        ld      hl,0
        ld      (wanted_extent),hl
        call    a_find_extent
        jr      c,.a_write_xfcb_bad
        call    a_save_entry_location
        call    a_find_xfcb_overlay
        jr      nc,.a_write_xfcb_have
        or      a
        jr      nz,.a_write_xfcb_bad
        ld      a,(m_xfcb_mode)
        and     1
        jr      z,.a_write_xfcb_bad
        call    a_find_free_entry
        jr      c,.a_write_xfcb_bad
        call    a_init_xfcb_overlay
        jr      .a_write_xfcb_store
.a_write_xfcb_have:
        ld      a,(ix+12)
        and     0e0h
        jr      z,.a_write_xfcb_store
        call    a_xfcb_password_matches_overlay
        jr      z,.a_write_xfcb_store
        ld      a,7
        ld      (native_physical_error_code),a
        jr      .a_write_xfcb_bad
.a_write_xfcb_store:
        ld      a,(m_xfcb_mode)
        and     0e0h
        ld      (ix+12),a
        ld      a,(m_xfcb_mode)
        and     1
        call    nz,a_encode_xfcb_password_overlay
        call    a_write_current_directory
        jr      c,.a_write_xfcb_bad
        call    a_update_sfcb_mode_overlay
        jr      c,.a_write_xfcb_bad
        xor     a
        ld      (cached_entry_valid),a
        ret
.a_write_xfcb_name_bad:
        ld      a,9
        ld      (native_physical_error_code),a
.a_write_xfcb_bad:
        ld      a,0ffh
        ret

a_update_sfcb_mode_overlay:
        ld      a,(a_entry_index)
        and     3
        cp      3
        ret     z
        ld      c,a
        call    a_restore_entry_location
        call    a_directory_sector_address
        call    read_logical_sector
        ret     c
        ld      a,(a_dir_index)
        or      3
        ld      (a_dir_index),a
        call    a_index_to_ix
        ld      a,(ix+0)
        cp      021h
        jr      nz,.a_update_sfcb_good
        push    ix
        pop     hl
        ld      de,9
        add     hl,de
        ld      a,c
        or      a
        jr      z,.a_update_sfcb_ready
        ld      de,10
.a_update_sfcb_advance:
        add     hl,de
        dec     c
        jr      nz,.a_update_sfcb_advance
.a_update_sfcb_ready:
        ld      a,(m_xfcb_mode)
        and     0e0h
        ld      (hl),a
        call    a_write_current_directory
        ret
.a_update_sfcb_good:
        or      a
        ret

a_entry_has_password_overlay:
        ld      a,(ix+13)
        or      a
        ret     nz
        push    ix
        pop     hl
        ld      de,16
        add     hl,de
        ld      b,8
.a_label_password_byte:
        ld      a,(hl)
        or      a
        ret     nz
        inc     hl
        djnz    .a_label_password_byte
        xor     a
        ret

a_set_label_overlay:
        ; Function 100 is a drive-level mutation, even when no label exists.
        ; a_prepare rejects it atomically while A: is temporarily read-only.
        call    a_prepare
        jp      c,.a_set_label_bad
        ld      hl,(m_fcb)
        ld      de,12
        add     hl,de
        call    native_open_tpa_read
        ld      (m_xfcb_mode),a
        ld      a,020h
        call    a_find_special
        jr      c,.a_set_label_missing
        call    a_entry_has_password_overlay
        jr      z,.a_set_label_validate
        call    a_xfcb_password_matches_overlay
        jr      z,.a_set_label_validate
        ld      a,7
        ld      (native_physical_error_code),a
        jr      .a_set_label_bad
.a_set_label_missing:
        or      a
        jr      nz,.a_set_label_bad
.a_set_label_validate:
        ld      a,(m_xfcb_mode)
        and     070h
        jr      z,.a_set_label_find
        ld      a,021h
        call    a_find_special
        jr      c,.a_set_label_bad
.a_set_label_find:
        ld      a,020h
        call    a_find_special
        jr      nc,.a_set_label_have
        or      a
        jr      nz,.a_set_label_bad
        call    a_find_free_entry
        jr      c,.a_set_label_bad
        push    ix
        pop     hl
        xor     a
        ld      b,32
.a_set_label_clear:
        ld      (hl),a
        inc     hl
        djnz    .a_set_label_clear
        ld      (ix+0),020h
.a_set_label_have:
        push    ix
        pop     hl
        inc     hl
        ld      de,m_name
        ld      b,11
.a_set_label_name:
        ld      a,(de)
        and     07fh
        ld      (hl),a
        inc     de
        inc     hl
        djnz    .a_set_label_name
        ld      a,(m_xfcb_mode)
        and     0f0h
        or      1
        ld      (ix+12),a
        ld      a,(m_xfcb_mode)
        and     1
        call    nz,a_encode_xfcb_password_overlay
        call    a_write_current_directory
        jr      c,.a_set_label_bad
        xor     a
        ld      (cached_entry_valid),a
        ret
.a_set_label_bad:
        ld      a,0ffh
        ret

; Function 102 has already cleared the password-mode byte and populated any
; SFCB stamps. Overlay the matching XFCB mode when one exists.
a_read_password_mode_overlay:
        call    a_read_stamps
        or      a
        ret     nz
        xor     a
        ld      (m_password_checksum),a
        ld      a,(a_dir_index)
        and     3
        cp      3
        jr      z,.a_read_mode_find_xfcb
        ld      c,a
        ld      a,(ix+0)
        cp      021h
        jr      nz,.a_read_mode_find_xfcb
        push    ix
        pop     hl
        ld      de,9
        add     hl,de
        ld      a,c
        or      a
        jr      z,.a_read_mode_sfcb_ready
        ld      de,10
.a_read_mode_sfcb_advance:
        add     hl,de
        dec     c
        jr      nz,.a_read_mode_sfcb_advance
.a_read_mode_sfcb_ready:
        ld      a,(hl)
        ld      (m_password_byte),a
        ld      a,1
        ld      (m_password_checksum),a
.a_read_mode_find_xfcb:
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        ld      (a_find_user),a
        call    a_find_xfcb_overlay
        jr      c,.a_read_password_mode_missing
        ld      a,(ix+12)
        ld      c,a
        ld      hl,(m_fcb)
        ld      de,12
        add     hl,de
        ld      a,c
        call    native_open_tpa_write
        jr      .a_read_password_mode_sfcb
.a_read_password_mode_missing:
        or      a
        jr      z,.a_read_password_mode_sfcb
        ld      a,0ffh
        ret
.a_read_password_mode_sfcb:
        ld      a,(m_password_checksum)
        or      a
        jr      z,.a_read_password_mode_good
        ld      hl,(m_fcb)
        ld      de,12
        add     hl,de
        ld      a,(m_password_byte)
        call    native_open_tpa_write
.a_read_password_mode_good:
        xor     a
        ret

; Apply CP/M Plus read/write password modes to a successful physical Open.
; Read mode rejects a mismatch with extended error 7. Write mode permits the
; Open but activates f7', which the common mutation policy treats read-only.
a_open_password_gate_overlay:
        xor     a
        ld      (m_open_password_lock),a
        call    a_passwords_enabled_overlay
        or      a
        ret     z
        cp      1
        jr      nz,.a_open_password_io
        call    a_find_xfcb_overlay
        jr      nc,.a_open_password_have
        or      a
        ret     z
        jr      .a_open_password_io
.a_open_password_have:
        ld      a,(ix+12)
        and     0e0h
        ld      (m_xfcb_mode),a
        ret     z
        call    a_xfcb_password_matches_overlay
        ret     z
        ld      a,(m_xfcb_mode)
        bit     7,a
        jr      nz,.a_open_password_denied
        bit     6,a
        jr      z,.a_open_password_good
        ld      a,1
        ld      (m_open_password_lock),a
.a_open_password_good:
        xor     a
        ret
.a_open_password_denied:
        ld      a,7
        ld      (native_physical_error_code),a
.a_open_password_io:
        ld      a,0ffh
        or      a
        ret

; M: keeps its private file records compact: byte 14 is the password mode,
; byte 15 marks a valid XFCB, and plaintext passwords live in a separate
; eight-byte-per-slot array. This is private MIT-authored state; raw directory
; clients see the standard encoded XFCB materialised from it below.
m_slot_directory_address_overlay:
        ld      a,(m_slot)
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      de,SPARSE_DIRECTORY_F2_BASE
        add     hl,de
        ret

m_slot_password_address_overlay:
        ld      a,(m_slot)
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      de,SPARSE_PASSWORD_F2_BASE
        add     hl,de
        ex      de,hl
        ret

; DE=private plaintext password. Return Z when DMA[0..7] or the process-local
; default password matches it.
m_plain_password_matches_overlay:
        push    de
        ld      hl,(m_dma)
        ld      b,8
.m_password_dma_byte:
        call    native_open_tpa_read
        ld      c,a
        ld      a,(de)
        cp      c
        jr      nz,.m_password_try_default
        inc     hl
        inc     de
        djnz    .m_password_dma_byte
        pop     de
        xor     a
        ret
.m_password_try_default:
        pop     de
        ld      hl,native_default_password
        ld      b,8
.m_password_default_byte:
        ld      a,(de)
        cp      (hl)
        jr      nz,.m_password_bad
        inc     de
        inc     hl
        djnz    .m_password_default_byte
        xor     a
        ret
.m_password_bad:
        ld      a,1
        or      a
        ret

; DE=private destination. Copy the new password supplied at DMA+8.
m_copy_new_password_overlay:
        ld      hl,(m_dma)
        ld      bc,8
        add     hl,bc
        ld      b,8
.m_password_copy:
        call    native_open_tpa_read
        ld      (de),a
        inc     hl
        inc     de
        djnz    .m_password_copy
        ret

m_open_password_gate_overlay:
        xor     a
        ld      (m_open_password_lock),a
        ld      a,(m_label_data)
        bit     7,a
        ret     z
        ld      a,(m_open_password_valid)
        or      a
        ret     z
        ld      a,(m_open_password_mode)
        and     0e0h
        ret     z
        call    m_slot_password_address_overlay
        call    m_plain_password_matches_overlay
        ret     z
        ld      a,(m_open_password_mode)
        bit     7,a
        jr      nz,.m_open_password_denied
        bit     6,a
        jr      z,.m_open_password_good
        ld      a,1
        ld      (m_open_password_lock),a
.m_open_password_good:
        xor     a
        ret
.m_open_password_denied:
        ld      a,7
        ld      (native_physical_error_code),a
        ld      a,0ffh
        or      a
        ret

m_read_stamps_overlay:
        call    m_open_find
        jr      c,.m_read_stamps_bad
        call    native_clear_fcb_stamps
        ld      a,(m_open_password_valid)
        or      a
        jr      z,.m_read_stamps_good
        ld      a,(m_open_password_mode)
        ld      c,a
        ld      hl,(m_fcb)
        ld      de,12
        add     hl,de
        ld      a,c
        call    native_open_tpa_write
.m_read_stamps_good:
        xor     a
        ret
.m_read_stamps_bad:
        ld      a,0ffh
        ret

m_write_xfcb_overlay:
        call    a_name_is_exact
        jr      c,.m_write_xfcb_name_bad
        ld      a,(m_label_data)
        bit     7,a
        jr      z,.m_write_xfcb_bad
        ld      hl,(m_fcb)
        ld      de,12
        add     hl,de
        call    native_open_tpa_read
        ld      (m_xfcb_mode),a
        call    m_open_find
        jr      c,.m_write_xfcb_bad
        ld      a,(m_open_password_valid)
        or      a
        jr      z,.m_write_xfcb_new
        ld      a,(m_open_password_mode)
        and     0e0h
        jr      z,.m_write_xfcb_store
        call    m_slot_password_address_overlay
        call    m_plain_password_matches_overlay
        jr      z,.m_write_xfcb_store
        ld      a,7
        ld      (native_physical_error_code),a
        jr      .m_write_xfcb_bad
.m_write_xfcb_new:
        ld      a,(m_xfcb_mode)
        and     1
        jr      z,.m_write_xfcb_bad
.m_write_xfcb_store:
        call    m_slot_directory_address_overlay
        ld      de,14
        add     hl,de
        ld      a,(m_xfcb_mode)
        and     0e0h
        ld      (hl),a
        inc     hl
        ld      (hl),1
        ld      a,(m_xfcb_mode)
        and     1
        jr      z,.m_write_xfcb_good
        call    m_slot_password_address_overlay
        call    m_copy_new_password_overlay
.m_write_xfcb_good:
        xor     a
        ret
.m_write_xfcb_name_bad:
        ld      a,9
        ld      (native_physical_error_code),a
.m_write_xfcb_bad:
        ld      a,0ffh
        ret

m_set_label_overlay:
        ld      hl,(m_fcb)
        ld      de,12
        add     hl,de
        call    native_open_tpa_read
        ld      (m_xfcb_mode),a
        ld      a,(SPARSE_LABEL_F2_BASE+12)
        or      a
        jr      z,.m_label_password_ok
        ld      de,SPARSE_LABEL_F2_BASE+13
        call    m_plain_password_matches_overlay
        jr      z,.m_label_password_ok
        ld      a,7
        ld      (native_physical_error_code),a
        jr      .m_set_label_bad
.m_label_password_ok:
        ld      a,(m_xfcb_mode)
        and     070h
        jr      nz,.m_set_label_bad
        ld      hl,SPARSE_LABEL_F2_BASE+1
        ld      de,m_name
        ld      b,11
.m_label_name:
        ld      a,(de)
        ld      (hl),a
        inc     de
        inc     hl
        djnz    .m_label_name
        ld      a,(m_xfcb_mode)
        and     1
        jr      z,.m_label_mode
        ld      de,SPARSE_LABEL_F2_BASE+13
        call    m_copy_new_password_overlay
        ld      a,1
        ld      (SPARSE_LABEL_F2_BASE+12),a
.m_label_mode:
        ld      a,(m_xfcb_mode)
        and     080h
        or      1
        ld      (SPARSE_LABEL_F2_BASE),a
        ld      (m_label_data),a
        xor     a
        ret
.m_set_label_bad:
        ld      a,0ffh
        ret

make_password_requested_overlay:
        ld      hl,(m_fcb)
        ld      de,6
        add     hl,de
        call    native_open_tpa_read
        and     080h
        ret

make_clear_password_interfaces_overlay:
        ld      hl,(m_fcb)
        ld      de,5
        add     hl,de
        ld      b,2
.make_clear_interface:
        call    native_open_tpa_read
        and     07fh
        call    native_open_tpa_write
        inc     hl
        djnz    .make_clear_interface
        ret

; Function 22 supplies its initial password at DMA+0 rather than the
; old/new pair used by Functions 100/103.
a_encode_make_password_overlay:
        ld      hl,(m_dma)
        ld      b,8
        xor     a
.a_make_password_sum:
        ld      c,a
        call    native_open_tpa_read
        add     a,c
        inc     hl
        djnz    .a_make_password_sum
        ld      (ix+13),a
        ld      (m_password_checksum),a
        ld      hl,(m_dma)
        ld      de,7
        add     hl,de
        push    ix
        pop     de
        ex      de,hl
        ld      bc,16
        add     hl,bc
        ex      de,hl
        ld      b,8
.a_make_password_encode:
        call    native_open_tpa_read
        ld      c,a
        ld      a,(m_password_checksum)
        xor     c
        ld      (de),a
        dec     hl
        inc     de
        djnz    .a_make_password_encode
        ret

a_make_password_overlay:
        call    make_password_requested_overlay
        jr      z,.a_make_password_clear
        call    a_passwords_enabled_overlay
        or      a
        jr      z,.a_make_password_clear
        cp      1
        jr      nz,.a_make_password_bad
        call    a_find_free_entry
        jr      c,.a_make_password_bad
        call    a_init_xfcb_overlay
        ld      hl,(m_dma)
        ld      de,8
        add     hl,de
        call    native_open_tpa_read
        and     0e0h
        ld      (ix+12),a
        call    a_encode_make_password_overlay
        call    a_write_current_directory
        jr      c,.a_make_password_bad
.a_make_password_clear:
        call    make_clear_password_interfaces_overlay
        xor     a
        ret
.a_make_password_bad:
        ld      a,0ffh
        ret

m_copy_make_password_overlay:
        ld      hl,(m_dma)
        ld      b,8
.m_make_password_copy:
        call    native_open_tpa_read
        ld      (de),a
        inc     hl
        inc     de
        djnz    .m_make_password_copy
        ret

m_make_password_overlay:
        call    make_password_requested_overlay
        jr      z,.m_make_password_clear
        ld      a,(m_label_data)
        bit     7,a
        jr      z,.m_make_password_clear
        call    m_slot_directory_address_overlay
        ld      de,14
        add     hl,de
        push    hl
        ld      hl,(m_dma)
        ld      de,8
        add     hl,de
        call    native_open_tpa_read
        and     0e0h
        pop     hl
        ld      (hl),a
        inc     hl
        ld      (hl),1
        call    m_slot_password_address_overlay
        call    m_copy_make_password_overlay
.m_make_password_clear:
        call    make_clear_password_interfaces_overlay
        xor     a
        ret

; Destructive directory calls must validate every matching XFCB before they
; alter a sector. Delete permits '?' wildcards, so this scan deliberately uses
; the same public-name matcher as the ordinary delete preflight.
a_password_mutation_preflight_overlay:
        call    a_passwords_enabled_overlay
        or      a
        ret     z
        cp      1
        jr      nz,.a_password_mutation_bad
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        add     a,010h
        ld      (a_found),a
        xor     a
        ld      (a_dir_sector),a
.a_password_mutation_sector:
        ld      a,(a_dir_sector)
        ld      c,a
        ld      a,(disk_dir_sectors)
        cp      c
        jr      z,.a_password_mutation_good
        call    a_directory_sector_address
        call    read_logical_sector
        jr      c,.a_password_mutation_bad
        ld      ix,sector_buffer
        ld      b,16
.a_password_mutation_entry:
        ld      a,(a_found)
        cp      (ix+0)
        jr      nz,.a_password_mutation_advance
        push    bc
        call    a_entry_name_pattern
        pop     bc
        jr      nz,.a_password_mutation_advance
        ld      a,(ix+12)
        and     0e0h
        jr      z,.a_password_mutation_advance
        push    bc
        call    a_xfcb_password_matches_overlay
        pop     bc
        jr      nz,.a_password_mutation_denied
.a_password_mutation_advance:
        ld      de,32
        add     ix,de
        djnz    .a_password_mutation_entry
        ld      a,(a_dir_sector)
        inc     a
        ld      (a_dir_sector),a
        jr      .a_password_mutation_sector
.a_password_mutation_denied:
        ld      a,7
        ld      (native_physical_error_code),a
.a_password_mutation_bad:
        ld      a,0ffh
        or      a
        ret
.a_password_mutation_good:
        xor     a
        ret

; Remove every matching XFCB. Used both by f5' XFCB-only Delete and after an
; ordinary file Delete so no orphaned password metadata remains.
a_delete_xfcb_overlay:
        xor     a
        jr      a_mutate_xfcb_overlay
a_rename_xfcb_overlay:
        ld      a,1
a_mutate_xfcb_overlay:
        ld      (m_password_byte),a
        ld      a,(OPENPCW_COMMON_SCB_USER)
        and     00fh
        add     a,010h
        ld      (a_found),a
        xor     a
        ld      (a_dir_sector),a
.a_mutate_xfcb_sector:
        ld      a,(a_dir_sector)
        ld      c,a
        ld      a,(disk_dir_sectors)
        cp      c
        jr      z,.a_mutate_xfcb_done
        call    a_directory_sector_address
        call    read_logical_sector
        jr      c,.a_mutate_xfcb_bad
        xor     a
        ld      (a_sector_changed),a
        ld      ix,sector_buffer
        ld      b,16
.a_mutate_xfcb_entry:
        ld      a,(a_found)
        cp      (ix+0)
        jr      nz,.a_mutate_xfcb_advance
        push    bc
        ld      a,(m_password_byte)
        or      a
        jr      nz,.a_mutate_xfcb_exact
        call    a_entry_name_pattern
        jr      .a_mutate_xfcb_compared
.a_mutate_xfcb_exact:
        call    a_entry_name_exact
.a_mutate_xfcb_compared:
        pop     bc
        jr      nz,.a_mutate_xfcb_advance
        ld      a,(m_password_byte)
        or      a
        jr      nz,.a_mutate_xfcb_rename
        ld      (ix+0),0e5h
        jr      .a_mutate_xfcb_changed
.a_mutate_xfcb_rename:
        push    ix
        pop     hl
        inc     hl
        ld      de,a_new_name
        push    bc
        ld      b,11
.a_mutate_xfcb_name:
        ld      a,(de)
        ld      (hl),a
        inc     de
        inc     hl
        djnz    .a_mutate_xfcb_name
        pop     bc
.a_mutate_xfcb_changed:
        ld      a,1
        ld      (a_sector_changed),a
.a_mutate_xfcb_advance:
        ld      de,32
        add     ix,de
        djnz    .a_mutate_xfcb_entry
        ld      a,(a_sector_changed)
        or      a
        jr      z,.a_mutate_xfcb_next
        call    a_write_current_directory
        jr      c,.a_mutate_xfcb_bad
.a_mutate_xfcb_next:
        ld      a,(a_dir_sector)
        inc     a
        ld      (a_dir_sector),a
        jr      .a_mutate_xfcb_sector
.a_mutate_xfcb_done:
        xor     a
        ret
.a_mutate_xfcb_bad:
        ld      a,0ffh
        ret
a_secure_mutation_overlay:
        call    a_password_mutation_preflight_overlay
        or      a
        ret     nz
        ld      a,(m_function)
        cp      19
        jr      nz,.a_secure_not_delete
        ld      hl,(m_fcb)
        ld      de,5
        add     hl,de
        call    native_open_tpa_read
        and     080h
        jp      nz,a_delete_xfcb_overlay
        call    a_delete
        or      a
        ret     nz
        jp      a_delete_xfcb_overlay
.a_secure_not_delete:
        cp      23
        jr      nz,.a_secure_not_rename
        call    a_rename
        or      a
        ret     nz
        jp      a_rename_xfcb_overlay
.a_secure_not_rename:
        cp      30
        jp      z,a_set_attributes
        jp      a_truncate

m_secure_mutation_overlay:
        ld      a,(m_label_data)
        bit     7,a
        jr      z,.m_secure_dispatch
        ; Delete accepts '?' wildcards. Validate every matching protected
        ; file before mutating any slot, so one bad password cannot leave a
        ; partially deleted set. Other destructive calls use exact names and
        ; naturally pass through the same scan once.
        ld      ix,SPARSE_DIRECTORY_F2_BASE
        ld      bc,08000h                ; B=count, C=slot
.m_secure_password_next:
        ld      a,(m_match_user)
        cp      (ix+0)
        jr      nz,.m_secure_password_advance
        push    bc
        push    ix
        pop     hl
        inc     hl
        ld      de,m_name
        ld      b,11
.m_secure_password_name:
        ld      a,(de)
        cp      '?'
        jr      z,.m_secure_password_byte
        cp      (hl)
        jr      nz,.m_secure_password_different
.m_secure_password_byte:
        inc     de
        inc     hl
        djnz    .m_secure_password_name
        pop     bc
        ld      a,(ix+15)
        or      a
        jr      z,.m_secure_password_advance
        ld      a,(ix+14)
        and     0e0h
        jr      z,.m_secure_password_advance
        ld      a,c
        ld      (m_slot),a
        push    bc
        call    m_slot_password_address_overlay
        call    m_plain_password_matches_overlay
        pop     bc
        jr      nz,.m_secure_password_bad
        jr      .m_secure_password_advance
.m_secure_password_different:
        pop     bc
.m_secure_password_advance:
        ld      de,16
        add     ix,de
        inc     c
        djnz    .m_secure_password_next
        jr      .m_secure_dispatch
.m_secure_password_bad:
        ld      a,7
        ld      (native_physical_error_code),a
        ld      a,0ffh
        ret
.m_secure_dispatch:
        ld      a,(m_function)
        cp      19
        jr      nz,.m_secure_not_delete
        ld      hl,(m_fcb)
        ld      de,5
        add     hl,de
        call    native_open_tpa_read
        and     080h
        jr      z,.m_secure_delete_file
        ld      a,080h
        ld      (a_found),a
        jp      m_delete_next
.m_secure_delete_file:
        jp      m_delete
.m_secure_not_delete:
        cp      23
        jp      z,m_rename
        cp      30
        jp      z,m_set_attributes
        jp      m_truncate

; Continue a raw M: directory search after the 128 ordinary private slots.
; Cursor 128 materialises the label; 129..256 materialise per-file XFCBs.
m_search_special_overlay:
.m_search_special_next:
        ld      hl,(native_search_cursor)
        push    hl
        ld      de,257
        or      a
        sbc     hl,de
        pop     hl
        jp      nc,.m_search_special_missing
        inc     hl
        ld      (native_search_cursor),hl
        dec     hl
        ld      a,h
        or      a
        jr      nz,.m_search_slot_127
        ld      a,l
        cp      128
        jr      nz,.m_search_slot_low
        ld      a,(m_label_data)
        or      a
        jr      z,.m_search_special_next
        ld      ix,SPARSE_LABEL_F2_BASE
        ld      a,020h
        ld      (m_password_byte),a
        ld      a,(m_label_data)
        ld      (m_xfcb_mode),a
        ld      a,(ix+12)
        ld      (m_password_checksum),a
        ld      hl,SPARSE_LABEL_F2_BASE+13
        ld      (m_scan_index),hl
        jr      .m_search_special_build
.m_search_slot_low:
        sub     129
        jr      .m_search_slot_ready
.m_search_slot_127:
        ld      a,127
.m_search_slot_ready:
        ld      (m_slot),a
        call    m_slot_directory_address_overlay
        push    hl
        pop     ix
        ld      a,(ix+0)
        or      a
        jr      z,.m_search_special_next
        ld      a,(ix+15)
        or      a
        jr      z,.m_search_special_next
        ld      a,(ix+0)
        add     a,15
.m_search_special_prepare:
        ld      (m_password_byte),a
        ld      a,(ix+14)
        ld      (m_xfcb_mode),a
        ld      a,(ix+15)
        ld      (m_password_checksum),a
        call    m_slot_password_address_overlay
        ld      (m_scan_index),de
.m_search_special_build:
        ld      hl,sparse_io_buffer
        ld      de,sparse_io_buffer+1
        ld      (hl),0e5h
        ld      bc,127
        ldir
        ld      hl,sparse_io_buffer
        ld      de,sparse_io_buffer+1
        ld      (hl),0
        ld      bc,31
        ldir
        ld      a,(m_password_byte)
        ld      (sparse_io_buffer),a
        push    ix
        pop     hl
        inc     hl
        ld      de,sparse_io_buffer+1
        ld      bc,11
        ldir
        ld      a,(m_xfcb_mode)
        ld      (sparse_io_buffer+12),a
        ld      a,(m_password_checksum)
        or      a
        jr      z,.m_search_special_copy
        ld      hl,(m_scan_index)
        ld      b,8
        xor     a
.m_search_password_sum:
        add     a,(hl)
        inc     hl
        djnz    .m_search_password_sum
        ld      (m_password_checksum),a
        ld      (sparse_io_buffer+13),a
        ld      hl,(m_scan_index)
        ld      de,7
        add     hl,de
        ld      de,sparse_io_buffer+16
        ld      b,8
.m_search_password_encode:
        ld      a,(hl)
        ld      c,a
        ld      a,(m_password_checksum)
        xor     c
        ld      (de),a
        dec     hl
        inc     de
        djnz    .m_search_password_encode
.m_search_special_copy:
        ld      de,sparse_io_buffer
        call    native_search_copy_dma
        xor     a
        ret
.m_search_special_missing:
        xor     a
        ld      (native_search_valid),a
        dec     a
        ret

native_password_overlay_end:

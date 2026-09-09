; SPDX-License-Identifier: MIT
; Copyright (c) 2026 retrodiv <retrodiv@proton.me>
;
; Project-authored CP/M-compatible resident kernel for the Amstrad PCW,
; designed from REF-CPM3-PG, REF-PCW-IO, and the memory plan in DES-MEM-001.
; Native hardware services provide the complete guest implementation on the
; documented PCW machine model.

        org     0f200h

; Physical block 8 is the private system page immediately below M:, outside
; both published CP/M banks, common block 7 and RAM-disc pages 9..15/31.
OPENPCW_RUNTIME_PAGE equ 088h
OPENPCW_RESIDENT_SHELL_ENTRY equ 0f31bh
OPENPCW_NATIVE_BDOS_SELECT equ 05b3ah
; Plain transient programs receive their initial zero return word immediately
; below the public BDOS prefix.  F500h-F5FFh is the conventional high-loader
; margin: applications may fill the complete 61K TPA and stage documented PCW
; common-memory payloads through F4FFh without replacing their return stack.
plain_transient_stack_top equ 0f600h
; CP/M Plus GENCOM loaders expose a separate 16-level entry stack immediately
; below their F606h workspace anchor. F5DEh-F5FDh is an otherwise empty part
; of the high-loader margin, disjoint from resident code and private service
; frames; the zero return word occupies the final two bytes at F5FEh.
gencom_transient_stack_top equ 0f5feh

kernel_entry:
        jp      kernel_cold_start

; Retain the low F206h compatibility veneer. Page Zero publishes the high
; F606h entry used by PCW loaders and GENCOM; both reach the private
; dispatcher at F609h. The private interrupt stack lives above this boundary,
; so application buffers below it cannot be overwritten by interrupt frames.
        defs    0f206h-$,0
bdos_low_entry:
        jp      bdos_entry

; The PCW's low Screen/BIOS-bank entry points preserve the general register
; file even though the ordinary BIOS jump table only specifies A as the
; console result. A few native runtimes depend on that stronger machine ABI.
; Keep these independently authored veneers in the spare fixed public-page
; gap so their addresses remain stable for the bootstrap's low jumpblock.
low_bios_console_status:
        push    hl
        call    bios_console_status
        push    af
        call    native_restore_screen_mapping
        pop     af
        pop     hl
        inc     b
        dec     b
        ret
low_bios_console_input:
        push    hl
        call    bios_console_input
        push    af
        call    native_restore_screen_mapping
        pop     af
        pop     hl
        ret
        ; The ten-byte F221h-F22Ah cold-start window is lifecycle storage once
        ; a GENCOM image owns its documented common-memory resident range. The
        ; live Screen/BIOS interrupt veneer is consequently published at the
        ; protected FDBBh entry below.
        defs    10,0

; Reserved PCW probe 96 needs B=0 in addition to the ordinary negative result.
; This three-byte leaf occupies the complete low-page gap. The maskable-
; interrupt epilogue itself uses the canonical adjacent EI/RETI pair: EI's
; one-instruction delay keeps IRQs inhibited through RETI.
reserved_96_zero_b:
        ld      b,0
interrupt_reenable_return:
        ret

; CP/M Plus publishes a consecutive three-byte BIOS jump table.  Page zero
; points at WBOOT, so applications can derive the remaining entries by their
; documented offsets; USERF is WBOOT+57h.  Keep all thirty vectors real even
; when the first native revision implements only a subset.
        defs    0f22eh-$,0
warm_boot:
        jp      warm_boot_impl
        jp      bios_console_status       ; +03 CONST
        jp      bios_console_input        ; +06 CONIN
        jp      bios_console_output       ; +09 CONOUT
        jp      bios_no_device            ; +0C LIST
        jp      bios_no_device            ; +0F PUNCH/AUXOUT
        jp      bios_no_device            ; +12 READER/AUXIN
        jp      bios_disk_home             ; +15 HOME
        jp      bios_disk_select           ; +18 SELDSK
        jp      bios_disk_set_track        ; +1B SETTRK
        jp      bios_disk_set_sector       ; +1E SETSEC
        jp      bios_disk_set_dma          ; +21 SETDMA
        jp      bios_disk_read             ; +24 READ
        jp      bios_disk_write            ; +27 WRITE
        jp      bios_no_device             ; +2A LISTST
        jp      bios_sector_translate      ; +2D SECTRAN
        jp      bios_console_status        ; +30 CONOST
        jp      bios_no_device             ; +33 AUXIST
        jp      bios_no_device             ; +36 AUXOST
        jp      bios_no_device             ; +39 DEVTBL
        jp      bios_disk_stub             ; +3C DEVINI
        jp      0f080h                     ; +3F DRVTBL
        jp      bios_disk_multio           ; +42 MULTIO
        jp      bios_disk_flush            ; +45 FLUSH
        jp      bios_disk_move             ; +48 MOVE
        jp      bios_disk_time             ; +4B TIME
        jp      0f060h                     ; +4E SELMEM
        jp      bios_disk_set_bank         ; +51 SETBNK
        jp      bios_disk_xmove            ; +54 XMOVE
        jp      bios_userf                 ; +57 USERF

kernel_cold_start:
        di
        ; Keep the cold-start/CCP stack distinct from the interrupt stack.
        ; Both source ranges are disposable after Page Zero's initial copy.
        ld      sp,shell_stack_top
        ld      hl,page_zero_template
        ld      de,0000h
        ld      bc,page_zero_template_end-page_zero_template
        ldir
        xor     a
        ld      (cold_start_state),a
        call    native_init_call
        ; The standard 27-byte LOADER prefix ends at F31Ah. Copy the CCP
        ; command path into the following lifecycle-owned gap so an attached
        ; RSX may use the complete documented range below F000h.
        ld      hl,command_loop
        ld      de,OPENPCW_RESIDENT_SHELL_ENTRY
        ld      bc,resident_shell_size
        ldir
        jr      .native_ready
        ; Keep the established public addresses while the direct native cold
        ; path occupies fewer bytes than the original extension dispatch.
        defs    8,0
.native_ready:

warm_boot_impl:
        ; Continue in ordinary resident padding before entering the shell.
        ; GET observes the continuation flag before vector publication.
        jp      warm_boot_prepare

command_loop:
        ; Reclaim the completed cold-start/command workspace after each COM.
        ld      a,63
        ld      (command_buffer),a
        ld      de,command_buffer
        ld      c,10
        ; Enter through a low-page proxy, just as a conventional CCP does.
        ; RSXs reject calls originating above their own resident address so
        ; that operating-system internals cannot recurse through the chain.
        call    0040h
        ld      hl,newline
        call    put_string
        ld      a,(command_buffer+1)
        or      a
        jp      z,warm_boot_prepare
        ld      e,a
        xor     a
        ld      d,a
        ld      hl,command_buffer+2
        add     hl,de
        ld      (hl),a
        ld      de,command_buffer+2
        call    command_dispatch
        or      a
        jr      z,.native_unavailable
        jp      warm_boot_prepare
        ; Preserve the native execution bridge addresses published to the
        ; separately assembled service page.
        defs    9,0
.native_unavailable:
        call    native_execute_call
.native_execute_result:
        or      a
        jr      z,.native_not_found
        call    native_prepare_call
        cp      0ffh
        jr      z,.native_not_found
        ld      (native_gencom_mode),a
        jp      native_program_start
.native_not_found:
        ld      hl,not_found
        call    put_string
        jp      warm_boot_prepare

resident_shell_size equ $-command_loop
resident_shell_entry equ OPENPCW_RESIDENT_SHELL_ENTRY
resident_shell_execute_result equ OPENPCW_RESIDENT_SHELL_ENTRY+(.native_execute_result-command_loop)

; Conventional CP/M page-zero vectors copied to 0000h. Bytes 3 and 4 are the
; IOBYTE and current drive. Programs call 0005h with C=function and DE=arg.
; Plain programs also derive their TPA ceiling from the target at 0006h.
; The private interrupt stack must remain above that public boundary.
page_zero_template:
        jp      0fc03h
        db      0
        db      0
        jp      bdos_public_entry

; IM 1 enters at 0038h. The PCW application interrupt interface requires
; the operating system to dispatch through a three-byte hook at
; FDCB. The implementation of that public contract lives below; applications
; remain free to replace either vector.
        defs    038h-($-page_zero_template),0
        jp      interrupt_system_wrapper

; A CP/M DMA record spans 0080h-00FFh, so the CCP-side BDOS proxy must not
; live in that range: GET legitimately fills the whole record before its warm
; boot. CP/M 3 publishes program-loader data at 0050h-005Bh; use 0040h inside
; the documented reserved 003Bh-004Fh range instead. Its CALL pushes a return
; address below every RSX, allowing input-redirection modules to recognize a
; CCP request before returning here.
        defs    040h-($-page_zero_template),0
        call    0005h
        ret
        defs    066h-($-page_zero_template),0
        retn

; The command buffer uses the high-loader workspace only while the CCP
; runs. It is abandoned before entering a transient and reinitialized on
; return. Interrupts use a separate persistent stack above the BDOS boundary.
        defs    080h-($-page_zero_template),0
command_buffer equ 0f401h
command_buffer_end equ command_buffer+66
resident_boot_banner_prefix:
        ; Cold native initialisation prints this before interrupts are enabled.
        ; The native-service stack may reuse this cold-only source later.
        db      12,13,10
        db      'OpenPCW-OS  (MIT-licensed)',13,10,13,10
        db      'v 0.2, 61K TPA, 1 disc dr',0
        ; Preserve the following fixed cold-source and shell-stack addresses.
        defs    5,0

; The resident shell blocks inside console calls with interrupts enabled.
; Giving it a separate stack prevents an interrupt's private register frame
; from overwriting the shell CALL/return words when a 300 Hz tick arrives.
; The shell is abandoned before a transient publishes its independent stack,
; and WBOOT may reuse this shell stack only after that transient is finished.
shell_stack_bottom:
        defs    32,0
shell_stack_top:

; The PCW exposes a low system-bank BIOS jumpblock beginning at 00E9h. Native
; programs copy or call this block as a unit, so publish its leading complete
; vectors rather than isolated CONST/CONIN entries. Both boot slots implement
; the same safe warm lifecycle in this independently authored fallback.
        defs    0e9h-($-page_zero_template),0
        jp      0fc03h
        jp      0fc03h
        jp      0fc06h
        jp      0fc09h
        jp      0fc0ch

page_zero_template_end:

; CP/M 3 exposes each resident module through byte 6 of a page-aligned prefix.
; The public F606h jump is also the first persistent byte: native applications
; may use the complete F400h-F5FFh loader workspace without overwriting a
; private dispatcher. Selection runs in protected native RAM, then this bridge
; restores the transient mapping and tail-calls the chosen common handler.
        defs    0f606h-$,0
bdos_public_entry:
        jp      bdos_entry
bdos_entry:
        ; CP/M's BDOS result is returned in A/HL. Real applications also rely
        ; on the other half of AF surviving calls, even though dispatch uses
        ; flags. Save it before moving to the private service stack.
        push    af
        pop     hl
        ld      (native_bdos_saved_af),hl
        ld      a,c
        call    native_begin
        call    native_map
        call    OPENPCW_NATIVE_BDOS_SELECT
        ld      (native_bdos_result_hl),hl
        call    native_restore_tpa
        ld      sp,(native_saved_sp)
        ld      a,(native_saved_iff)
        or      a
        jr      z,.bdos_mapping_restored
        ei
.bdos_mapping_restored:
        ld      hl,bdos_native_return
        push    hl
        ld      hl,(native_bdos_result_hl)
        jp      (hl)

; Functions 0..59 and 98..112 are selected by the protected native table.
; Guest-waiting console calls remain in common code so the frontend continues
; to advance frames while input is pending.
.version:
        ld      a,031h
        ld      l,a
        ld      h,0
        ret

; All returning native functions arrive here through bdos_native's CALL.  Use
; memory temporaries so restoring F cannot clobber BC/DE/IX/IY, and load A/HL
; only with flag-neutral instructions after POP AF.
bdos_native_return:
        ld      (native_bdos_result_hl),hl
        ld      (native_bdos_result_a),a
        ld      hl,(native_bdos_saved_af)
        push    hl
        pop     af
        ld      a,(native_bdos_result_a)
        ld      hl,(native_bdos_result_hl)
        ret
.select_disk:
        ; A: is bit 0 of the low login-vector byte and M: is bit 4 of
        ; the high byte. Recording either directly keeps the public state
        ; conventional without needing a transient-bank helper.
        ld      a,e
        or      a
        jr      z,.select_disk_a
        cp      12
        jr      nz,.invalid_drive
        ld      hl,native_login_vector+1
        set     4,(hl)
        jr      .select_disk_store
.select_disk_a:
        ld      hl,native_login_vector
        set     0,(hl)
.select_disk_store:
        ld      a,e
        ld      (native_current_disk),a
        xor     a
        ld      l,a
        ld      h,a
        ret
.invalid_drive:
        jp      native_invalid_drive_result
.current_disk:
        ld      a,(native_current_disk)
        ld      l,a
        ld      h,0
        ret

; BDOS Function 11 has a distinct result contract from the raw BIOS status
; vector, so keep its register-preserving native bridge explicit.
native_bdos_status_impl:
        call    native_begin
        push    bc
        push    de
        push    hl
        push    ix
        push    iy
        call    native_map
        call    0136h
        ld      (native_result_a),a
        jp      native_preserved_finish
native_bdos_status_impl_end:
command_dispatch:
        ; CP/M Plus SUBMIT/GET command files commonly keep disabled commands
        ; and notes as apostrophe (or semicolon) comment lines. They belong
        ; to the CCP language and must never be resolved as .COM filenames.
        ld      a,(command_buffer+2)
        cp      027h
        jp      z,warm_boot_prepare
        cp      ';'
        jp      z,warm_boot_prepare
        call    shell_select_drive
        jp      native_shell_dispatch

.set_dma:
        ld      (native_dma),de
        xor     a
        ld      l,a
        ld      h,a
        ret
.set_multisector:
        ld      a,e
        dec     a
        cp      128
        jp      nc,.unsupported
        ld      a,e
.set_multisector_valid:
        ld      (native_multisector),a
        xor     a
        ld      l,a
        ld      h,a
        ret
.set_error_mode:
        ld      a,e
        cp      0ffh
        jr      z,.set_error_mode_store
        cp      0feh
        jr      z,.set_error_mode_store
        xor     a
.set_error_mode_store:
        ld      (native_error_mode),a
        xor     a
        ld      l,a
        ld      h,a
        ret

; Function 49 copies its four-byte request to common scratch before the native
; module replaces the caller's low banks. The protected implementation reads
; that stable copy and returns the documented value in A/HL.
.scb:
        push    bc
        push    de
        ex      de,hl
        ld      de,native_bdos_saved_hl
        ld      bc,4
        ldir
        pop     de
        pop     bc
        push    de
        ld      de,native_bdos_saved_hl
        call    native_m_bdos_call
        pop     de
        ret

bdos_wait_character:
        ld      a,1
        jp      native_m_bdos_call

; Functions 15 and 16 share the complete banked A:/M: directory path.  Their
; common handler lives outside every published transient/GENCOM workspace, so
; a program may use F580h-F59Dh while retaining fully operational file I/O.
.open_file:
.close_file:
        call    native_m_bdos_call
        ; OpenPCW defines otherwise unspecified scratch outputs as zero.
        ; Keep the documented A/HL result from the filesystem service.
        ld      bc,0
        ld      de,0
        ret

; Resume the shell after WBOOT. This exact nine-byte continuation lives in an
; otherwise unused common-memory gap, leaving room beside the terminal bridge
; for the physical-screen bank switch.
warm_shell_continue:
        ; Ask the resident native shell to emit the optional CP/M user-number
        ; prefix before the ordinary drive prompt.  DE=0 is a private shell
        ; presentation request and never enters command parsing.
        ld      de,0
        call    native_shell_dispatch
        ld      hl,prompt
        call    put_string
        jp      OPENPCW_RESIDENT_SHELL_ENTRY

; CP/M Plus function 10. The native page-one editor implements the banked
; editing contract, including an initialized DMA buffer and previous-line
; recall. Keeping the wait in guest execution lets a frontend continue to
; deliver frames and keyboard events while a program is blocked for input.
bdos_read_line:
        jp      .line_native
        ; Preserve the address of the native editor bridge below.
        defs    11,0
.line_native:
        call    native_begin
        call    native_map
        call    0139h               ; native_read_line jump-table entry
        cp      0ffh
        jr      z,.line_native_abort
        ld      (native_result_a),a
        call    native_restore_tpa
        ld      hl,0
        jp      native_finish
.line_native_abort:
native_physical_error_abort:
        call    native_restore_tpa
        jp      warm_boot_prepare

; Recognise exact A: and M: commands before either command loader sees them.
; Adding 'A' to the CP/M drive number also updates the writable prompt text.
shell_select_drive:
        push    de
        push    de
        pop     hl
        ld      a,(hl)
        and     05fh
        sub     'A'
        jr      z,.shell_drive_valid
        cp      12
        jr      nz,.shell_not_drive
.shell_drive_valid:
        ld      e,a
        inc     hl
        ld      a,(hl)
        cp      ':'
        jr      nz,.shell_not_drive
        inc     hl
        ld      a,(hl)
        or      a
        jr      nz,.shell_not_drive
        pop     hl
        ld      a,e
        add     a,'A'
        ld      (prompt),a
        ld      a,(0004h)
        and     0f0h
        or      e
        ld      (0004h),a
        ld      c,14
        call    0040h
        jp      warm_boot_prepare
.shell_not_drive:
        pop     de
        ret

; Low Screen/BIOS-bank console calls must return with the three physical
; screen pages still selected. Keep this correction in resident OS space:
; F5xx is part of the conventional loader/stack workspace and programs such
; as ACE legitimately replace it after their initial transient has exited.
; The low veneers save AF around this routine so the console result survives.
native_restore_screen_mapping:
        ld      a,080h
        out     (0f0h),a
        inc     a
        out     (0f1h),a
        inc     a
        out     (0f2h),a
        ret

put_string:
        ld      a,(hl)
        or      a
        ret     z
        push    hl
        call    console_put
        pop     hl
        inc     hl
        jr      put_string

console_put:
        jp      native_put_call

; Select the Page Zero BDOS head from protected common memory.  Housing this
; WBOOT helper in the established thirteen-byte resident gap keeps it live
; while an attached module owns common memory through EFFFh.
warm_bdos_head:
        ld      a,(native_gencom_mode)
        or      a
        ld      hl,bdos_public_entry
        ret     z
        ld      hl,(native_gencom_chain)
        ret
        ; Preserve the resident strings and command-buffer ABI addresses.
        defs    1,0

prompt:
        db      'A>',0
newline:
        db      13,10,0
not_found:
        db      'No such command',13,10,0
; Keep the IRQ frame wholly above the public F606h allocation boundary.
; The remaining 34 bytes provide the SCR RUN callback's separate stack:
; one callback return word plus sixteen levels of application calls.
interrupt_stack_bottom:
        defs    64,0
interrupt_stack_top:
userf_screen_stack_bottom:
        ; Native page-one services publish this state through fixed common
        ; addresses. Preserve the established F7F5h boundary even when the
        ; resident line-editor trampoline changes size.
        defs    0f7f5h-$,0
userf_screen_stack_top:
cold_start_state:
        ; FFh means the bootstrap entered through WBOOT before the cold entry.
        ; The first warm preparation redirects through kernel_cold_start once.
        db      0ffh
native_dma:
        dw      0080h
native_multisector:
        db      1
        defs    0f7fah-$,0
; Keep the full invalid-drive policy above the public BDOS front end. The
; dispatcher reaches it with the caller's TPA still mapped; only
; native page-one failures use native_physical_error_abort above.
native_invalid_drive_result:
        ld      hl,04ffh
        jr      native_physical_error_result
native_physical_error_result:
        ld      a,(native_error_mode)
        or      a
        jp      z,warm_boot_prepare
        ld      a,l
        ret
        defs    0f808h-$,0
native_current_disk:
        db      0
native_error_mode:
        db      0
native_bdos_saved_af:
        dw      0
native_bdos_saved_hl:
        dw      0
native_bdos_result_hl:
        dw      0
native_bdos_result_a:
        db      0
native_saved_sp:
        dw      0
native_saved_hl:
        dw      0
native_saved_iff:
        db      0
native_argument_a:
        db      0
native_result_a:
        db      0
native_gencom_mode:
        db      0
native_gencom_chain:
        dw      bdos_public_entry
        defs    0f81bh-$,0
; Independently authored CP/M 3 System Control Block. Only published fields
; have nonzero defaults; the trailing byte makes the word read at offset 99
; deterministic without extending the public 100-byte range.
native_scb:
        defs    05h,0
        db      031h                       ; 05: BDOS version
        defs    01ah-06h,0
        db      89                         ; 1A: console width minus one
        db      0                          ; 1B: console column
        db      32                         ; 1C: console lines
        defs    02eh-01dh,0
        db      0,0ffh                     ; 2E/2F: backspace/delete
        defs    037h-030h,0
        db      '$'                        ; 37: string delimiter
        defs    03ah-038h,0
        db      09ch,0fbh                  ; 3A/3B: loader compatibility anchor
        defs    04ah-03ch,0
        db      1                          ; 4A: multisector count
        db      0                          ; 4B: error mode
        db      0,0ffh                     ; 4C/4D: drive search chain
        defs    058h-04eh,0
        db      1,0                        ; 58/59: day 1 = 1978-01-01
        db      0,0,0                      ; 5A-5C: BCD hour/minute/second
        db      0,0c0h                     ; 5D/5E: common base C000h
        defs    064h-05fh,0
native_scb_end:
        db      0

native_scb_sync:
        ld      hl,(native_dma)
        ld      (native_scb+03ch),hl
        ld      a,(native_current_disk)
        ld      (native_scb+03eh),a
        ld      a,(native_multisector)
        ld      (native_scb+04ah),a
        ld      a,(native_error_mode)
        ld      (native_scb+04bh),a
        ret

native_scb_apply:
        ld      hl,(native_scb+03ch)
        ld      (native_dma),hl
        ld      a,(native_scb+04ah)
        or      a
        jr      nz,.native_scb_count_ready
        inc     a
.native_scb_count_ready:
        ld      (native_multisector),a
        ld      a,(native_scb+03eh)
        ld      (native_current_disk),a
        ld      a,(native_scb+04bh)
        ld      (native_error_mode),a
        ret
userf_function:
        dw      0
userf_saved_sp:
        dw      0
; Published PCW terminal state. Applications may write F7 directly to blank
; the display while loading; the OS ticker periodically restores this owned
; value, as the documented terminal environment requires.
terminal_f7_value:
        db      05fh

; Map the independently loaded native module (physical blocks 0, the final RAM
; block, and 2) while keeping this common kernel in block 7, then restore the
; conventional 48K transient bank (physical blocks 4,5,6). These helpers
; preserve the registers that a BDOS/BIOS caller is entitled to keep.
native_map:
        ld      a,080h
        ; An interrupt may arrive while the private low page is executing.
        ; Its common-memory epilogue must resume that same page; restoring the
        ; foreground page here would continue at the program byte sharing the
        ; interrupted logical address and skip the service's cleanup.
        ld      (interrupt_restore_page),a
        nop
        out     (0f0h),a
        ld      a,OPENPCW_RUNTIME_PAGE
        out     (0f1h),a
        ld      a,082h
        out     (0f2h),a
        ld      a,087h
        out     (0f3h),a
        ret

native_restore_tpa:
        ; The banked disk engine uses the Screen/BIOS shadows as temporary DMA
        ; selectors. Amstrad CP/M Plus republishes the ordinary bank-one
        ; mapping before returning to a transient; leaving the final target
        ; bank here makes a multi-file loader start its next stage against the
        ; preceding file's RAM page.
        ld      a,085h
        ld      (0061h),a
        out     (0f1h),a
        inc     a
        ld      (0062h),a
        out     (0f2h),a
        nop
        ld      a,084h
        ld      (interrupt_restore_page),a
        out     (0f0h),a
        ret

; Establish the ordinary application mapping in the independently owned
; system-bank shadows. The public TPA page zero has a default FCB at the same
; logical addresses, so initialise these bytes only while physical block 0 is
; visible; never bake them into page_zero_template.
native_reset_tpa:
        di
        call    native_map
        ; The protected native page reconstructs Page Zero through the F2
        ; paging window.  5AD2h is pinned as native_warm_reset, so WBOOT has
        ; no dependency on code or templates inside an RSX-owned page.
        call    05ad2h
        ld      a,085h
        out     (0f1h),a
        ld      a,086h
        out     (0f2h),a
        ld      a,084h
        ld      (interrupt_restore_page),a
        ld      (interrupt_resume_page),a
        out     (0f0h),a
        ret

native_init_call:
        call    native_map
        ; Physical block 0 is the PCW Screen/BIOS low bank.  SCR RUN ROUTINE
        ; makes it readable at 0000h, including while IM 1 interrupts remain
        ; enabled, so it needs the same independently authored restart and
        ; CP/M entry vectors as the ordinary TPA low page.  The native module
        ; is loaded at 0100h and therefore deliberately leaves this page for
        ; the resident kernel to initialise.
        ld      hl,page_zero_template
        ld      de,0000h
        ld      bc,page_zero_template_end-page_zero_template
        ldir
        call    0100h
        jp      native_reset_tpa

native_put_call:
        jp      native_put_impl

native_status_call:
        jp      native_status_impl

native_get_call:
        jp      native_get_impl

bios_console_status:
        jp      native_status_call

bios_console_input:
        jp      native_get_call

; Compact BDOS console handlers occupy the former alignment interval before
; BIOS CONOUT. Their addresses are exported to the separately assembled
; protected selector; both return the conventional A/HL result.
.console_output:
        ld      a,e
        call    console_put
        ld      a,e
        ld      l,a
        ld      h,0
        ret
.console_status:
        call    native_bdos_status_impl
        ld      l,a
        ld      h,0
        ret

bios_console_output:
        ld      a,c
        jp      console_put

bios_no_device:
        xor     a
        ret

bios_disk_stub:
        xor     a
        ret

bios_sector_translate:
        ld      a,13
        jp      bios_disk_call

; USERF/XBIOS calls carry a documented two-byte service address immediately
; after CALL.  EX (SP),HL consumes it while leaving the caller's HL intact.
bios_userf:
        ; USERF dispatch necessarily uses AF, but several published services
        ; preserve it and others consume caller A as an argument. Save the
        ; complete original pair in an existing fixed common scratch word.
        push    hl
        push    af
        pop     hl
        ld      (native_bdos_saved_af),hl
        pop     hl
        ex      (sp),hl
        ld      a,(hl)
        ld      (userf_function),a
        inc     hl
        ld      a,(hl)
        ld      (userf_function+1),a
        inc     hl
        ex      (sp),hl
        ld      a,(userf_function+1)
        or      a
        jr      nz,.userf_unknown
        ld      a,(userf_function)
        cp      0e9h                     ; SCR RUN ROUTINE
        jr      z,.userf_screen_run
        jp      native_userf_call
.userf_unknown:
        ld      a,0ffh
        ret
.userf_screen_run:
        ; SCR RUN executes a common-memory callback with the three PCW screen
        ; blocks visible at 0000h-BFFFh.  Keep the caller's stack and register
        ; file intact while switching to an OS-owned common-memory stack. The
        ; callback has a separate 16-level stack above the private interrupt
        ; frame; neither stack overlaps the GENCOM entry stack.
        ld      a,b
        cp      0c0h
        jr      c,.userf_unknown
        push    hl
        ld      hl,(native_bdos_saved_af)
        push    hl
        pop     af                       ; callback receives caller's AF
        pop     hl
        ld      (userf_screen_jump+1),bc
        di
        ld      (userf_saved_sp),sp
        ld      sp,userf_screen_stack_top
        push    af
        push    bc
        push    de
        push    hl
        push    ix
        push    iy
        ld      a,080h
        ld      (interrupt_restore_page),a
        ld      (interrupt_resume_page),a
        out     (0f0h),a
        inc     a
        out     (0f1h),a
        ld      a,082h                    ; screen blocks are 0, 1 and 2
        out     (0f2h),a
        ld      a,087h
        out     (0f3h),a
        pop     iy
        pop     ix
        pop     hl
        pop     de
        pop     bc
        pop     af
        ei
        call    userf_screen_jump
        di
        push    af
        ld      a,084h
        ld      (interrupt_resume_page),a
        out     (0f0h),a
        inc     a
        out     (0f1h),a
        inc     a
        out     (0f2h),a
        ld      a,087h
        out     (0f3h),a
        ld      a,084h
        ld      (interrupt_restore_page),a
        pop     af
        ld      sp,(userf_saved_sp)
        ei
        ret
userf_screen_jump:
        jp      0000h

; All ordinary XBIOS services run inside the independent native module. Save
; its complete register result while restoring the caller's TPA mapping, then
; restore the original interrupt state without changing the returned AF.
native_userf_call:
        call    native_stage_disk_setup
        call    native_begin
        call    native_map
        call    013ch
        push    af
        push    bc
        push    de
        push    hl
        push    ix
        push    iy
        call    native_restore_tpa
        ld      a,(native_saved_iff)
        or      a
        jr      z,.native_userf_iff_off
        pop     iy
        pop     ix
        pop     hl
        pop     de
        pop     bc
        pop     af
        ld      sp,(native_saved_sp)
        ei
        ret
.native_userf_iff_off:
        pop     iy
        pop     ix
        pop     hl
        pop     de
        pop     bc
        pop     af
        ld      sp,(native_saved_sp)
        ret

; A transient may put its stack anywhere in the low 48K. Mapping the native
; module at 0000h would then hide CALL's return addresses. Move native-service
; calls to a private common-memory stack first, with interrupts disabled, and
; restore both the caller's stack and its interrupt state on the way out.
; This is a normal banked-OS trampoline: no program-specific bytes or
; assumptions are involved.
native_begin:
        ld      (native_argument_a),a
        ld      a,i
        jp      po,.native_begin_iff_off
        ld      a,1
        jr      .native_begin_iff_saved
.native_begin_iff_off:
        xor     a
.native_begin_iff_saved:
        ld      (native_saved_iff),a
        di
        ld      (native_saved_hl),hl
        pop     hl
        ld      (native_saved_sp),sp
        ld      sp,0f390h
        push    hl
        ld      hl,(native_saved_hl)
        ld      a,(native_argument_a)
        ret

native_finish:
        ld      a,(native_saved_iff)
        or      a
        jr      z,.native_finish_iff_off
        ld      a,(native_result_a)
        ld      sp,(native_saved_sp)
        ei
        ret
.native_finish_iff_off:
        ld      a,(native_result_a)
        ld      sp,(native_saved_sp)
        ret

; BDOS Function 9 scans the caller's visible string while native memory is not
; mapped, emitting through the ordinary bank-safe terminal bridge.
.print_string:
        push    bc
        push    de
        pop     hl
.print_next:
        ld      a,(hl)
        ld      c,a
        ld      a,(native_scb+037h)
        cp      c
        jr      z,.print_done
        ld      a,c
        push    hl
        call    console_put
        pop     hl
        inc     hl
        jr      .print_next
.print_done:
        pop     bc
        ret
        defs    1,0

native_put_impl:
        call    native_begin
        push    bc
        push    de
        push    hl
        push    ix
        push    iy
        call    native_map
        ld      a,(native_argument_a)
        call    0103h
        ld      (native_result_a),a
        jp      native_preserved_finish

native_status_impl:
        call    native_begin
        push    bc
        push    de
        push    hl
        push    ix
        push    iy
        call    native_map
        call    0106h
        ld      (native_result_a),a
        jp      native_preserved_finish

native_get_impl:
        call    native_begin
        push    bc
        push    de
        push    hl
        push    ix
        push    iy
        call    native_map
        call    0109h
        ld      (native_result_a),a
        jp      native_preserved_finish

; Entry 010Ch of the native module is the physical-disk COM loader. It writes
; the transient bank itself and returns only a success flag to common memory.
native_execute_call:
        call    native_begin
        call    native_map
        call    010ch
        ld      (native_result_a),a
        call    native_restore_tpa
        jp      native_finish

; BDOS Function 13 resets native media state and the public DMA/count/login
; state. It fits the former file-service alignment interval exactly.
.reset_disk:
        call    native_disk_reset_call
        ld      hl,0080h
        ld      (native_dma),hl
        ld      a,1
        ld      (native_multisector),a
        call    .reset_all_drive_state
        xor     a
        ld      l,a
        ld      h,a
        ret
        defs    1,0

; Shared tail for services which saved the complete public register set on
; native_begin's private stack.
native_preserved_finish:
        call    native_restore_tpa
        pop     iy
        pop     ix
        pop     hl
        pop     de
        pop     bc
        jp      native_finish

.return_code:
        ld      a,d
        and     e
        inc     a
        jr      nz,.return_code_set
        ld      hl,(native_scb+010h)
        ld      a,l
        ret
.return_code_set:
        ld      (native_scb+010h),de
        jp      .zero_result

; Functions 99..112. Function 98 is handled directly before indexing this
; table because committed writes leave no temporary allocation blocks.
.extended_table:
        dw      native_m_bdos_call,native_m_bdos_call
        dw      native_m_bdos_call,native_m_bdos_call
        dw      native_m_bdos_call,native_m_bdos_call
        dw      native_m_bdos_call,native_m_bdos_call
        dw      native_m_bdos_call,.return_code
        dw      native_m_bdos_call,native_m_bdos_call
        dw      native_m_bdos_call,native_m_bdos_call

; FB00h-FC5Ch is the conventional CP/M Plus compatibility workspace used by
; command FCBs, loader anchors and BIOS-vector aliases. Keep *all* executable
; code out of it: GENCOM and resident extensions may rewrite every byte.
        defs    0fc5dh-$,0

; The public FC03h WBOOT vector must target resident code in the FCxx page.
; CP/M Plus software uses that placement as a consistency check before
; installing an RSX. Keep the real implementation at F22Eh and expose this
; independently authored, stable trampoline at the compatibility boundary.
compat_warm_boot_call:
        jp      warm_boot_prepare

; BDOS Function 6 keeps its four documented modes in common memory. The input
; wait and status leaves follow the shared restore tail closely enough for the
; selector's compact relative branches.
.direct_console:
        ld      a,e
        cp      0ffh
        jr      z,.direct_input
        cp      0feh
        jr      z,.direct_status
        cp      0fdh
        jp      z,.direct_input_wait
        call    console_put
        xor     a
        ld      l,a
        ld      h,0
        ret
        defs    1,0

; Common tail for banked services which have no registers left to restore on
; the private stack.  Sharing it keeps the fixed FC5Dh-FDBAh resident window
; large enough for the complete CP/M-compatible bridge set.
native_restore_and_finish:
        call    native_restore_tpa
        jp      native_finish

; The nonblocking/status modes of Function 6 share this former seek-bridge
; island and preserve its surrounding common ABI addresses.
.direct_status:
        jp      native_status_call
.direct_input:
        call    native_status_call
        or      a
        ret     z
        call    native_get_call
        ret
        defs    3,0

; Entry 0127h owns the volatile M: filesystem. DE remains the caller's FCB,
; HL is its DMA and B is the CP/M Plus multisector count. Moving directory,
; extent and sparse-record policy into the native bank leaves the public
; GENCOM workspace genuinely writable and gives every PCW machine model the
; same implementation.
native_m_bdos_call:
        ld      a,c
        call    native_begin
        push    bc
        push    de
        push    ix
        push    iy
        ld      a,(native_multisector)
        ld      b,a
        ld      hl,(native_dma)
        call    native_map
        ld      a,(native_argument_a)
        call    0127h
        push    hl
        ld      (native_result_a),a
        call    native_restore_tpa
        pop     hl
        pop     iy
        pop     ix
        pop     de
        pop     bc
        ld      a,(native_result_a)
        jp      native_finish

; Entry 011Eh decodes a standard CP/M Plus GENCOM header and relocates any
; attached RSXs entirely on the Z80. It returns zero for a plain COM, one plus
; the chain head in HL for GENCOM, or FFh for an invalid container.
native_prepare_call:
        call    native_begin
        call    native_map
        call    011eh
        ld      (native_gencom_chain),hl
        jp      native_result_restore

; Entry 012Ah invalidates physical-media state after BDOS 13. This is the
; ordinary CP/M disk-change boundary and therefore works identically in an
; emulator and on a real drive through the same guest-visible media state.
native_disk_reset_call:
        call    native_begin
        call    native_map
        call    012ah
        xor     a
native_result_restore:
        ld      (native_result_a),a
        jp      native_restore_and_finish

; Small no-device/direct-console results live in otherwise unused resident
; space after the banked-service bridges. Keeping them here preserves the
; fixed F600h stack boundary used by plain transient programs.
.auxiliary_input:
        ld      a,01ah
        ld      l,a
        ld      h,0
        ret
.no_device_status:
        xor     a
        ld      l,a
        ld      h,a
        ret
.direct_input_wait:
        call    native_get_call
        ret

; BDOS Function 50 consumes an eight-byte parameter block in the transient
; bank and returns the called BIOS register result directly. BIOS WBOOT is the
; one non-returning case and is handled before mapping out the caller. All
; other functions run through the native module's fixed 0133h entry without
; saving BC/DE/HL, because those registers are part of the BIOS return ABI.
native_direct_bios_call:
        ld      a,(de)
        cp      1
        jp      z,warm_boot_prepare
        call    native_begin
        call    native_map
        call    0133h
        jp      native_result_restore

; CP/M Plus process/disk state --------------------------------------------
;
; These calls are intentionally resident in common memory. They manipulate
; only the public per-program state while the native service bank remains
; protected.
.reset_all_drive_state:
        xor     a
        ld      (native_current_disk),a
        ld      hl,0
        ld      (native_login_vector),hl
        ld      (native_ro_vector),hl
        ret

.user_code:
        ld      a,e
        cp      0ffh
        jr      z,.user_code_get
        and     00fh
        ld      (native_scb+044h),a
        jr      .zero_result
.user_code_get:
        ld      a,(native_scb+044h)
        ld      l,a
        ld      h,0
        ret

; PCW applications conventionally enter this public mapper at FD21h while
; running a callback against screen memory. A=0 selects the ordinary CP/M
; application set (physical pages 0, 1 and 2); A<>0 selects the alternate
; screen-work set (pages 4, 5 and 6). HL is preserved, and the final A value
; is the complete page byte last written to a paging port. The implementation
; follows the documented PCW paging-port contract directly.
        defs    0fd21h-$,0
pcw_public_bank_mapper:
        push    hl
        or      a
        jr      z,.pcw_public_bank_mapper_application
        ld      hl,08685h
        ld      a,084h
        jr      .pcw_public_bank_mapper_apply
.pcw_public_bank_mapper_application:
        ld      hl,08281h
        ld      a,080h
.pcw_public_bank_mapper_apply:
        out     (0f0h),a
        ld      a,l
        out     (0f1h),a
        ld      a,h
        out     (0f2h),a
        pop     hl
        ret

.reset_drives:
        push    bc
        push    de
        ld      hl,(native_login_vector)
        ld      a,e
        cpl
        and     l
        ld      l,a
        ld      a,d
        cpl
        and     h
        ld      h,a
        ld      (native_login_vector),hl
        ld      hl,(native_ro_vector)
        ld      a,e
        cpl
        and     l
        ld      l,a
        ld      a,d
        cpl
        and     h
        ld      h,a
        ld      (native_ro_vector),hl
        bit     0,e
        call    nz,native_disk_reset_call
        pop     de
        pop     bc
.zero_result:
        xor     a
        ld      l,a
        ld      h,a
        ret

.unsupported:
        ld      a,0ffh
        ld      l,a
        ld      h,0
        ret

; CP/M Plus Function 47 replaces the calling transient with the command in
; the current DMA. The native loader distinguishes a transient-bank pointer
; from the shell's common-memory pointer and success never returns here.
.chain_program:
        ld      de,(native_dma)
        call    native_execute_call
        jp      resident_shell_execute_result

; DD L T OFF MOTOR counts in tenths of a second, while the PCW hardware tick
; runs at 300Hz. A zero countdown means "leave the motor on indefinitely".
; This routine occupies the deliberate gap before the fixed interrupt ABI.
native_motor_advance:
        ld      hl,(native_motor_off_ticks)
        ld      a,h
        or      l
        ret     z
        dec     hl
        ld      (native_motor_off_ticks),hl
        ld      a,h
        or      l
        ret     nz
        ld      a,10                     ; PCW system command: motor off
        out     (0f8h),a
        xor     a
        ld      (native_motor_ready),a
        ret

; Increment one packed-BCD field at HL. C is the exclusive limit (60h or
; 24h). Carry means that the field wrapped and its parent must be advanced.
native_clock_increment_bcd:
        ld      a,(hl)
        inc     a
        daa
        cp      c
        jr      c,.native_clock_bcd_store
        xor     a
        ld      (hl),a
        scf
        ret
.native_clock_bcd_store:
        ld      (hl),a
        or      a
        ret

; The public-vector page is full, while the FAxx/FBxx records are writable
; compatibility data. Keep the WBOOT continuation in the deliberate resident
; gap immediately before the fixed interrupt ABI instead.
warm_boot_publish_vectors:
        ; GET observes the CCP continuation state before Page Zero is rebuilt.
        ld      a,020h
        ld      (0fbb4h),a
        ld      sp,shell_stack_top
        call    native_reset_tpa
        ; A transient may overwrite either public Page Zero vector. WBOOT
        ; republishes both while preserving the caller-visible IOBYTE and
        ; current-drive bytes at 0003h/0004h.
        ld      hl,0fc03h
        ld      (0001h),hl
        ; An attached RSX remains the public BDOS head across WBOOT.
        call    warm_bdos_head
        ld      (0006h),hl
        ; A transient may leave a private DMA behind.  The CCP begins every
        ; new command with the conventional 0080h record; utilities such as
        ; XCK rely on that WBOOT boundary before their next invocation.
        ld      hl,0080h
        ld      (native_dma),hl
        ; native_reset_tpa changes executable banks with interrupts disabled.
        ; The CCP and any resident ticker extensions run in the ordinary
        ; interrupt-enabled CP/M environment once Page Zero is coherent.
        ei
        jp      warm_shell_continue

; PCW interrupt dispatcher -------------------------------------------------
;
; Some native PCW programs extend the system ticker by replacing the
; three-byte query instruction at FDCCh.  The query must leave the address of
; the actual tick routine in HL; programs commonly replace the default load
; with CALL <wrapper>, do their own periodic work there, and return the same
; default address.  FEA7h is the corresponding public default-handler word.
; These fixed data/code locations form the compatibility ABI. The surrounding
; dispatcher implements the OpenPCW-OS design in DES-IRQ-001.
;
; The code is deliberately placed in the conventional high system area so a
; program may occupy the complete 0100h-F1FFh transient area without
; destroying its interrupt path.
        defs    0fdbbh-$,0

interrupt_entry:
interrupt_system_wrapper:
        ; Physical block 0 supplies this vector while Screen/BIOS memory is
        ; selected.  Preserve the interrupted AF while publishing the mapping
        ; that the common epilogue must restore, then abandon the foreground
        ; stack in interrupt_system_entry.
        push    af
        ld      a,080h
        ld      (interrupt_restore_page),a
        pop     af
        jp      interrupt_system_entry
        defs    0fdcbh-$,0
interrupt_dispatch:
        ; FDCBh is the replaceable byte immediately before the fixed FDCCh
        ; query.  The outer private frame already preserves foreground HL.
        nop
interrupt_query:
        ld      hl,(interrupt_default_handler)
        ; Invoke the selected handler without rewriting the low-page IM 1
        ; vector. Native programs can use PCW split read/write paging, where
        ; a store through 0039h and the following RST 38h see different RAM
        ; banks; in that state a self-modifying trampoline recurses into the
        ; dispatcher instead of reaching the handler.
        ; HL is necessarily the queried handler and DE is necessarily used as
        ; its synthetic return address.  The private outer frame restores both
        ; foreground registers after dispatch, so duplicating them here would
        ; only consume resident bytes and private stack.
        ld      de,interrupt_handler_return
        push    de
        jp      (hl)
interrupt_handler_return:
        di
        ret

; Public CP/M Plus disk BIOS bridge.  The direct vectors must remain ordinary
; guest code on a physical PCW, so each tiny entry assigns an independently
; defined operation number and calls the hidden native disk engine through its
; stable 0130h jump-table slot.  native_begin moves away from an arbitrary
; transient stack before the low 48K is banked out; native_finish restores the
; caller's interrupt state and returns the BIOS result in A/HL.
bios_disk_home:
        xor     a
        jr      bios_disk_call
bios_disk_select:
        ld      a,1
        jr      bios_disk_call
bios_disk_set_track:
        ld      a,2
        jr      bios_disk_call
bios_disk_set_sector:
        ld      a,3
        jr      bios_disk_call
bios_disk_set_dma:
        ld      a,4
        jr      bios_disk_call
bios_disk_read:
        ld      a,5
        jr      bios_disk_call
bios_disk_write:
        ld      a,6
        jr      bios_disk_call
bios_disk_multio:
        ld      a,7
        jr      bios_disk_call
bios_disk_flush:
        ld      a,8
        jr      bios_disk_call
bios_disk_move:
        ld      a,10
        jr      bios_disk_call
bios_disk_time:
        ld      a,11
        jr      bios_disk_call
bios_disk_xmove:
        ; The five-byte implementation fits the otherwise unused tail of the
        ; FE20h compatibility gap.  This three-byte veneer releases the byte
        ; needed for remapping the private interrupt stack on handler return.
        jp      bios_disk_xmove_impl
bios_disk_set_bank:
        ld      c,a                     ; operation A must not hide bank A
        ld      a,9
bios_disk_call:
        call    native_begin
        call    native_map
        ld      a,(native_argument_a)
        call    0130h
        ld      (native_result_a),a
        call    native_restore_tpa
        jp      native_finish

; Keep the compatibility helper at its stable common-memory address.  Native
; code may temporarily map another low page and chain here to acknowledge the
; hardware tick before returning to the program environment.
        defs    0fe20h-$,0
interrupt_compat_chain:
        jp      interrupt_default_tick
bios_disk_xmove_impl:
        ld      a,12
        jp      bios_disk_call

; Begin the Screen/BIOS-bank entry in the otherwise unused compatibility gap.
; Saving the foreground SP here leaves enough contiguous common space for the
; complete register frame and its final mapping restore below FE68h.
interrupt_system_entry:
        ex      af,af'
        ld      (interrupt_saved_sp),sp
        jp      interrupt_system_entry_continue
        defs    0fe31h-$,0
interrupt_restore_page:
        ; Store the complete paging-port byte, not merely the bank number.
        ; This keeps every interrupt transition both smaller and explicit.
        db      084h

interrupt_system_entry_continue:
        ; Interrupt acceptance has already placed the foreground PC on the
        ; foreground stack.  Move away from that stack before saving even one
        ; register: applications may put SP anywhere in their complete TPA,
        ; including the low bank which an interrupt handler must page out.
        ; The matching EX preserves both AF banks around the saved-SP prefix.
        ld      sp,interrupt_stack_top
        ex      af,af'
interrupt_body:
        ; Save the complete primary and alternate register files on the
        ; common-memory stack. Keeping the dispatcher wholly in common block 7
        ; is essential: takeover programs legitimately reuse every non-common
        ; physical block, including blocks 3 and 8.
        push    af
interrupt_body_after_af:
        push    bc
        push    de
        push    hl
        push    ix
        push    iy
        ex      af,af'
        push    af
        ex      af,af'
        exx
        push    bc
        push    de
        push    hl
        exx
        call    interrupt_dispatch
        di
        ; Complete a replacement dispatcher's low-page trampoline before the
        ; saved register file is exposed again.
        call    interrupt_restore_mapping
        exx
        pop     hl
        pop     de
        pop     bc
        exx
        ex      af,af'
        pop     af
        ex      af,af'
        pop     iy
        pop     ix
        pop     hl
        pop     de
        pop     bc
        pop     af
        ld      sp,(interrupt_saved_sp)
interrupt_reti_epilogue:
        ei
        reti
        defs    0fe68h-$,0

; The common ticker is callable both by the central dispatcher and directly
; through FE20h.  It therefore neither depends on the private interrupt stack
; nor maps any application page while executing.
interrupt_tick_common:
        push    af
        push    bc
        push    hl
        in      a,(0f4h)
        call    native_clock_advance
        ld      a,(terminal_f7_value)
        out     (0f7h),a
        pop     hl
        pop     bc
        pop     af
        ret

native_clock_advance:
        ld      hl,(native_clock_subticks)
        dec     hl
        ld      (native_clock_subticks),hl
        ld      a,h
        or      l
        ret     nz
        ld      hl,300
        ld      (native_clock_subticks),hl
        jp      native_clock_increment_second

        defs    0fe90h-$,0
interrupt_default_tick:
        ; A program may replace the FDCBh dispatcher and chain straight to
        ; this public handler, so it must be register-transparent without
        ; relying on interrupt_body having saved the caller first.
        push    af
        push    bc
        push    hl
        call    native_motor_advance
        pop     hl
        pop     bc
        pop     af
        jp      interrupt_tick_common

interrupt_restore_mapping:
        ld      hl,interrupt_restore_page
        ld      a,(hl)
        out     (0f0h),a
        ; The selected entry owns this persistent shadow. A replacement 0038h
        ; may jump straight to the public default handler on later ticks, so
        ; clearing the bank bit here would lose its foreground mapping.
        ret

        defs    0fea7h-$,0
interrupt_default_handler:
        dw      interrupt_default_tick

native_program_start:
        ; CP/M 3 Page Zero identifies the program's source drive at 0050h and
        ; reserves 0051h-005Bh for command-operand password metadata.
        ld      a,(native_current_disk)
        inc     a
        ld      (0050h),a
        xor     a
        ld      hl,0051h
        ld      de,0052h
        ld      (hl),a
        ld      bc,10
        ldir
        ld      a,(native_gencom_mode)
        or      a
        jr      z,.plain
        ld      a,0c3h
        ld      (0005h),a
        ld      hl,(native_gencom_chain)
        ld      (0006h),hl
        ; The published CP/M 3 loader contract supplies a 32-byte (16-level)
        ; entry stack terminated by address 0000h. This dedicated window also
        ; matches the loader boundary observed by standard attached RSXs.
        ld      hl,0
        ld      (gencom_transient_stack_top),hl
        ld      sp,gencom_transient_stack_top
        im      1
        ei
        jp      0100h
.plain:
        ; FF98h is a conventional loader pointer used by a small number of
        ; CP/M Plus commands. Keep it data, not executable code, and branch
        ; over it in the plain-COM path. GENCOM preparation builds the FCB it
        ; references at FB00h from the command actually being launched.
        jp      .plain_after_loader_pointer
; DD SETUP accepts its seven-byte table in ordinary transient memory. The
; hidden native module temporarily replaces that memory with its own physical
; pages, so stage the bytes in common RAM before changing the mapping. Other
; USERF calls pass through with every input register and flag untouched.
native_stage_disk_setup:
        push    af
        ld      a,(userf_function+1)
        or      a
        jr      nz,.stage_not_setup
        ld      a,(userf_function)
        cp      083h
        jr      nz,.stage_not_setup
        ld      a,h
        or      l
        jr      z,.stage_modern
        call    .stage_pointer_valid
        jr      nc,.stage_invalid_legacy
        push    bc
        push    de
        ld      de,native_disk_parameter_staging
        ld      bc,7
        ldir
        pop     de
        pop     bc
        ld      hl,native_disk_parameter_staging
        pop     af
        ret
.stage_modern:
        ex      de,hl
        call    .stage_pointer_valid
        jr      nc,.stage_invalid_modern
        push    bc
        ld      de,native_disk_parameter_staging
        ld      bc,7
        ldir
        pop     bc
        ld      de,native_disk_parameter_staging
        ld      hl,0
        pop     af
        ret
.stage_invalid_modern:
        ld      de,0fffah
        ld      hl,0
        pop     af
        ret
.stage_invalid_legacy:
        ld      hl,0fffah
.stage_not_setup:
        pop     af
        ret
.stage_pointer_valid:
        ld      a,h
        cp      0ffh
        scf
        ret     nz
        ld      a,l
        cp      0fah                    ; seven bytes may end at FFFFh
        ret

; A retained GET/SUBMIT module observes this conventional CCP continuation
; flag before it supplies the next redirected command. Keep the crowded WBOOT
; vector path small by finishing the shell transition in this otherwise unused
; common-memory gap.
warm_boot_prepare:
        ld      a,(cold_start_state)
        inc     a
        jp      z,kernel_cold_start
        jp      warm_boot_publish_vectors

; The native shell keeps its resident commands in protected page one. This
; bridge passes the command line, then restores the ordinary transient mapping
; before command_loop decides whether the command was handled (nonzero) or
; needs a .COM lookup (zero).
; 5937h is pinned by native_kernel.asm as native_shell_command.
native_shell_dispatch:
        jp      native_shell_command_call
        defs    2,0
native_shell_command_call:
        call    native_begin
        call    native_map
        call    05937h
        ld      (native_result_a),a
        call    native_restore_tpa
        jp      native_finish

; The documented seven-byte DD SETUP record for each possible floppy unit.
; Keeping it in ordinary common RAM makes the current timings part of a normal
; machine save state. DD INIT restores these independently authored defaults
; before issuing uPD765 SPECIFY.
        defs    0ff65h-$,0
; The documented XDPB workspace ends at FF64h. Keep the legacy native-service
; paging shadow immediately after it; the common-only ISR no longer treats
; zero as a private sentinel, but native call paths still publish the byte.
interrupt_resume_page:
        db      084h
; The TPA owns a distinct IM 1 vector.  Entering through it means physical
; block 4 was visible at 0000h: publish that as the post-interrupt mapping and
; expose the system low bank while the resident dispatcher runs.  This is an
; independently authored implementation of the observable banked-PCW ABI;
; no CP/M resident bytes are embedded here.
interrupt_tpa_entry:
        ; Preserve both AF banks while abandoning the foreground stack before
        ; paging its low bank out.  This is what makes low-stack programs safe.
        ex      af,af'
        ld      (interrupt_saved_sp),sp
        ld      sp,interrupt_stack_top
        ex      af,af'
        push    af
        ld      a,084h
        ld      (interrupt_restore_page),a
        ld      a,080h
        out     (0f0h),a
        jp      interrupt_body_after_af
        defs    0ff7eh-$,0
; Foreground stack saved by either low-page IM 1 entry. Interrupts remain
; disabled until the matching epilogue restores it, so one common word is
; sufficient and is also naturally covered by save states.
interrupt_saved_sp:
        dw      0
native_disk_parameters:
        db      10,50,175,30,12,15,3
        db      10,50,175,30,12,15,3
native_motor_off_ticks:
        dw      0
native_motor_ready:
        db      0
native_disk_parameter_staging:
        defs    7,0
        defs    0ff98h-$,0
gencom_default_fcb_pointer:
        dw      0fb00h
.plain_after_loader_pointer:
plain_transient_entry:
        ; DES-ENTRY-001: OpenPCW defines a neutral plain-COM entry state.
        ; The ordinary and alternate register sets start at zero, with a
        ; warm-boot return word on the published stack.
        ld      hl,0
        ld      (plain_transient_stack_top),hl ; RET from COM is a warm boot
        ld      sp,plain_transient_stack_top
        push    hl
        pop     af
        ex      af,af'
        ld      bc,0
        ld      de,0
        ld      hl,0
        exx
        ld      hl,0
        push    hl
        pop     af
        ld      bc,0
        ld      de,0
        ld      hl,0
        ld      ix,0
        ld      iy,0
        im      1
        ei
        jp      0100h

.get_dpb:
        ; native_init and GENCOM preparation refresh this public DPB directly
        ; from the mounted medium through the independent XBIOS login routine.
        ld      hl,0fb9ch
        ret

        defs    0ffd3h-$,0
native_login_vector:
        dw      1
native_ro_vector:
        dw      0

; Advance the public BCD clock once per 300 hardware ticks. Day zero is
; skipped on 16-bit wrap because CP/M defines day 1 as 1978-01-01.
native_clock_increment_second:
        ld      hl,native_scb+05ch
        ld      c,060h
        call    native_clock_increment_bcd
        ret     nc
        dec     hl
        call    native_clock_increment_bcd
        ret     nc
        dec     hl
        ld      c,024h
        call    native_clock_increment_bcd
        ret     nc
        ld      hl,(native_scb+058h)
        inc     hl
        ld      a,h
        or      l
        jr      nz,.native_clock_day_ready
        inc     hl
.native_clock_day_ready:
        ld      (native_scb+058h),hl
        ret

        defs    0fffch-$,0
native_clock_subticks:
        dw      300

kernel_end:

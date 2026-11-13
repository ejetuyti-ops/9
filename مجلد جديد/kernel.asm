bits 32
org 0x10000

VIDEO_MEMORY equ 0xA0000
SCREEN_WIDTH equ 320

%macro RECT 5
    mov dword [rect_x], %1
    mov dword [rect_y], %2
    mov dword [rect_w], %3
    mov dword [rect_h], %4
    mov byte [rect_color], %5
    call draw_rect
%endmacro

%macro TEXT 4
    mov dword [text_x], %1
    mov dword [text_y], %2
    mov byte [text_color], %3
    mov esi, %4
    call draw_text
%endmacro

start:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, 0x90000
    cld

    call set_palette
    call fs_init
    call sha256_self_test
    call auth_load
    call scan_network_adapter
    mov dword [mouse_x], 160
    mov dword [mouse_y], 100
    call init_mouse
    mov byte [active_window], 6
    call redraw_active

event_loop:
    call e1000_poll_receive
    call dhcp_tick
    in al, 0x64
    test al, 1
    jz event_loop
    test al, 0x20
    jnz mouse_data_ready
    in al, 0x60

keyboard_data_ready:
    test al, 0x80
    jnz event_loop
    cmp byte [user_logged_in], 1
    jne auth_key
    cmp byte [terminal_open], 0
    jne terminal_key
    cmp byte [active_window], 4
    jne .desktop_keys
    cmp al, 0x01
    je close_window
    cmp al, 0x14
    je show_terminal
    cmp al, 0x02
    je show_info_window
    cmp al, 0x3B
    je show_help_window
    jmp event_loop
.desktop_keys:
    cmp al, 0x01
    je close_window
    cmp al, 0x21
    je show_files_window
    cmp al, 0x3B
    je show_help_window
    cmp al, 0x02
    je show_info_window
    cmp al, 0x14
    je show_terminal
    jmp event_loop

mouse_data_ready:
    in al, 0x60
    call handle_mouse_byte
    jmp event_loop

close_window:
    mov byte [terminal_open], 0
    mov byte [active_window], 0
    call redraw_active
    jmp event_loop

show_help_window:
    mov byte [terminal_open], 0
    mov byte [active_window], 1
    call redraw_active
    jmp event_loop

show_info_window:
    mov byte [terminal_open], 0
    mov byte [active_window], 2
    call redraw_active
    jmp event_loop

auth_load:
    mov byte [user_logged_in], 0
    cmp byte [sha_ready], 1
    jne .crypto_error
    mov eax, 20
    mov edi, auth_sector
    call ata_read_sector
    jc .first_run
    cmp dword [auth_sector], 0x554E574F
    jne .first_run
    cmp dword [auth_sector + 4], 1
    jne .first_run
    mov esi, auth_sector + 8
    mov edi, auth_username
    mov ecx, 16
    rep movsb
    mov esi, auth_sector + 24
    mov edi, auth_salt
    mov ecx, 16
    rep movsb
    mov esi, auth_sector + 40
    mov edi, auth_saved_hash
    mov ecx, 32
    rep movsb
    mov byte [auth_state], 4
    mov dword [auth_message], auth_login_prompt
    ret
.first_run:
    mov byte [auth_state], 1
    mov dword [auth_message], auth_user_prompt
    ret
.crypto_error:
    mov byte [auth_state], 5
    mov dword [auth_message], auth_crypto_error
    ret

auth_key:
    cmp al, 0x1C
    je auth_submit
    cmp al, 0x0E
    je auth_backspace
    movzx ebx, al
    mov al, [keymap + ebx]
    test al, al
    jz event_loop
    movzx ebx, byte [terminal_length]
    cmp ebx, 43
    jae event_loop
    mov [terminal_input + ebx], al
    inc byte [terminal_length]
    movzx ebx, byte [terminal_length]
    mov byte [terminal_input + ebx], 0
    call redraw_active
    jmp event_loop

auth_backspace:
    cmp byte [terminal_length], 0
    je event_loop
    dec byte [terminal_length]
    movzx ebx, byte [terminal_length]
    mov byte [terminal_input + ebx], 0
    call redraw_active
    jmp event_loop

auth_submit:
    cmp byte [terminal_length], 0
    je .empty
    cmp byte [auth_state], 1
    je .username
    cmp byte [auth_state], 2
    je .new_password
    cmp byte [auth_state], 3
    je .confirm_password
    cmp byte [auth_state], 4
    je .login
    jmp .clear
.username:
    cmp byte [terminal_length], 8
    ja .bad_username
    mov esi, terminal_input
    mov edi, auth_username
    movzx ecx, byte [terminal_length]
    rep movsb
    mov byte [edi], 0
    mov byte [auth_state], 2
    mov dword [auth_message], auth_new_password_prompt
    jmp .clear
.new_password:
    cmp byte [terminal_length], 6
    jb .weak_password
    mov al, [terminal_length]
    mov [auth_password_length], al
    mov esi, terminal_input
    mov edi, auth_password
    movzx ecx, byte [terminal_length]
    rep movsb
    mov byte [edi], 0
    mov byte [auth_state], 3
    mov dword [auth_message], auth_confirm_prompt
    jmp .clear
.confirm_password:
    movzx ecx, byte [auth_password_length]
    cmp cl, [terminal_length]
    jne .password_mismatch
    mov esi, auth_password
    mov edi, terminal_input
    repe cmpsb
    jne .password_mismatch
    call auth_create_user
    jc .storage_error
    mov byte [user_logged_in], 1
    mov byte [active_window], 0
    mov dword [terminal_result], auth_welcome
    call redraw_active
    jmp event_loop
.login:
    call auth_check_password
    jc .bad_login
    mov byte [user_logged_in], 1
    mov byte [active_window], 0
    mov dword [terminal_result], auth_welcome
    call redraw_active
    jmp event_loop
.bad_username:
    mov dword [auth_message], auth_username_error
    jmp .clear
.weak_password:
    mov dword [auth_message], auth_password_error
    jmp .clear
.password_mismatch:
    mov dword [auth_message], auth_mismatch_error
    mov byte [auth_state], 2
    jmp .clear
.bad_login:
    mov dword [auth_message], auth_login_error
    jmp .clear
.storage_error:
    mov dword [auth_message], auth_storage_error
.clear:
    mov byte [terminal_length], 0
    mov byte [terminal_input], 0
    call redraw_active
    jmp event_loop
.empty:
    mov dword [auth_message], auth_empty_error
    jmp .clear

auth_create_user:
    call auth_make_salt
    mov esi, auth_password
    movzx ecx, byte [auth_password_length]
    call auth_hash_password
    mov edi, auth_sector
    xor eax, eax
    mov ecx, 128
    rep stosd
    mov dword [auth_sector], 0x554E574F
    mov dword [auth_sector + 4], 1
    mov esi, auth_username
    mov edi, auth_sector + 8
    mov ecx, 16
    rep movsb
    mov esi, auth_salt
    mov edi, auth_sector + 24
    mov ecx, 16
    rep movsb
    mov esi, sha_digest
    mov edi, auth_sector + 40
    mov ecx, 32
    rep movsb
    mov esi, sha_digest
    mov edi, auth_saved_hash
    mov ecx, 32
    rep movsb
    mov eax, 20
    mov esi, auth_sector
    call ata_write_sector
    setc [auth_operation_error]
    call auth_wipe_secrets
    cmp byte [auth_operation_error], 0
    jne .failed
    clc
    ret
.failed:
    stc
    ret

auth_wipe_secrets:
    pushad
    xor eax, eax
    mov edi, terminal_input
    mov ecx, 44
    rep stosb
    mov edi, auth_password
    mov ecx, 44
    rep stosb
    mov edi, sha_input
    mov ecx, 64
    rep stosb
    mov edi, sha_padded
    mov ecx, 128
    rep stosb
    mov edi, sha_digest
    mov ecx, 32
    rep stosb
    mov byte [terminal_length], 0
    mov byte [auth_password_length], 0
    popad
    ret

auth_check_password:
    mov esi, terminal_input
    movzx ecx, byte [terminal_length]
    call auth_hash_password
    mov esi, sha_digest
    mov edi, auth_saved_hash
    mov ecx, 32
    repe cmpsb
    setne [auth_operation_error]
    call auth_wipe_secrets
    cmp byte [auth_operation_error], 0
    jne .failed
    clc
    ret
.failed:
    stc
    ret

auth_make_salt:
    rdtsc
    mov [auth_salt], eax
    mov [auth_salt + 4], edx
    mov esi, nic_mac
    mov edi, auth_salt + 8
    mov ecx, 6
    rep movsb
    mov al, [terminal_length]
    mov [auth_salt + 14], al
    xor al, [auth_salt]
    xor al, [auth_salt + 5]
    mov [auth_salt + 15], al
    ret

auth_hash_password:
    pushad
    mov edi, sha_input
    rep movsb
    mov esi, auth_salt
    mov ecx, 16
    rep movsb
    mov eax, edi
    sub eax, sha_input
    mov [sha_input_length], eax
    mov esi, sha_input
    mov ecx, eax
    call sha256_hash
    mov dword [sha_rounds], 255
.round:
    mov esi, sha_digest
    mov edi, sha_input
    mov ecx, 32
    rep movsb
    mov esi, auth_salt
    mov ecx, 16
    rep movsb
    mov esi, sha_input
    mov ecx, 48
    call sha256_hash
    dec dword [sha_rounds]
    jnz .round
    popad
    ret

sha256_hash:
    pushad
    mov [sha_input_length], ecx
    mov edi, sha_padded
    xor eax, eax
    mov ecx, 32
    rep stosd
    mov esi, [esp + 4]
    mov ecx, [sha_input_length]
    mov edi, sha_padded
    rep movsb
    mov byte [edi], 0x80
    mov eax, [sha_input_length]
    cmp eax, 56
    jb .one_block
    mov dword [sha_block_count], 2
    mov dword [sha_length_offset], 124
    jmp .length_ready
.one_block:
    mov dword [sha_block_count], 1
    mov dword [sha_length_offset], 60
.length_ready:
    mov eax, [sha_input_length]
    shl eax, 3
    bswap eax
    mov edx, [sha_length_offset]
    mov [sha_padded + edx], eax
    mov edx, [sha_length_offset]
    sub edx, 4
    mov dword [sha_padded + edx], 0

    mov dword [sha_state], 0x6A09E667
    mov dword [sha_state + 4], 0xBB67AE85
    mov dword [sha_state + 8], 0x3C6EF372
    mov dword [sha_state + 12], 0xA54FF53A
    mov dword [sha_state + 16], 0x510E527F
    mov dword [sha_state + 20], 0x9B05688C
    mov dword [sha_state + 24], 0x1F83D9AB
    mov dword [sha_state + 28], 0x5BE0CD19
    mov dword [sha_block_offset], 0
.block:
    call sha256_compress
    dec dword [sha_block_count]
    jz .output
    mov dword [sha_block_offset], 64
    jmp .block
.output:
    mov esi, sha_state
    mov edi, sha_digest
    mov ecx, 8
.write_digest:
    lodsd
    bswap eax
    stosd
    loop .write_digest
    popad
    ret

sha256_compress:
    xor ebx, ebx
.load_words:
    cmp ebx, 16
    jae .expand_words
    mov edx, [sha_block_offset]
    lea esi, [sha_padded + edx]
    mov eax, [esi + ebx * 4]
    bswap eax
    mov [sha_schedule + ebx * 4], eax
    inc ebx
    jmp .load_words
.expand_words:
    cmp ebx, 64
    jae .rounds_start
    mov eax, [sha_schedule + ebx * 4 - 60]
    mov edx, eax
    ror eax, 7
    ror edx, 18
    xor eax, edx
    mov edx, [sha_schedule + ebx * 4 - 60]
    shr edx, 3
    xor eax, edx
    mov [sha_temp0], eax
    mov eax, [sha_schedule + ebx * 4 - 8]
    mov edx, eax
    ror eax, 17
    ror edx, 19
    xor eax, edx
    mov edx, [sha_schedule + ebx * 4 - 8]
    shr edx, 10
    xor eax, edx
    add eax, [sha_schedule + ebx * 4 - 64]
    add eax, [sha_schedule + ebx * 4 - 28]
    add eax, [sha_temp0]
    mov [sha_schedule + ebx * 4], eax
    inc ebx
    jmp .expand_words
.rounds_start:
    mov eax, [sha_state]
    mov [sha_a], eax
    mov eax, [sha_state + 4]
    mov [sha_b], eax
    mov eax, [sha_state + 8]
    mov [sha_c], eax
    mov eax, [sha_state + 12]
    mov [sha_d], eax
    mov eax, [sha_state + 16]
    mov [sha_e], eax
    mov eax, [sha_state + 20]
    mov [sha_f], eax
    mov eax, [sha_state + 24]
    mov [sha_g], eax
    mov eax, [sha_state + 28]
    mov [sha_h], eax
    mov dword [sha_round_index], 0
.round:
    cmp dword [sha_round_index], 64
    jae .add_state
    mov eax, [sha_e]
    mov edx, eax
    ror eax, 6
    ror edx, 11
    xor eax, edx
    mov edx, [sha_e]
    ror edx, 25
    xor eax, edx
    add eax, [sha_h]
    mov edx, [sha_e]
    mov ebx, [sha_f]
    and ebx, edx
    not edx
    mov edi, [sha_g]
    and edi, edx
    xor ebx, edi
    add eax, ebx
    mov ebx, [sha_round_index]
    add eax, [sha_constants + ebx * 4]
    add eax, [sha_schedule + ebx * 4]
    mov [sha_t1], eax

    mov eax, [sha_a]
    mov edx, eax
    ror eax, 2
    ror edx, 13
    xor eax, edx
    mov edx, [sha_a]
    ror edx, 22
    xor eax, edx
    mov [sha_t2], eax
    mov edx, [sha_a]
    mov ebx, [sha_b]
    and ebx, edx
    mov edi, [sha_c]
    and edi, edx
    xor ebx, edi
    mov edx, [sha_b]
    mov edi, [sha_c]
    and edx, edi
    xor ebx, edx
    add [sha_t2], ebx

    mov eax, [sha_g]
    mov [sha_h], eax
    mov eax, [sha_f]
    mov [sha_g], eax
    mov eax, [sha_e]
    mov [sha_f], eax
    mov eax, [sha_d]
    add eax, [sha_t1]
    mov [sha_e], eax
    mov eax, [sha_c]
    mov [sha_d], eax
    mov eax, [sha_b]
    mov [sha_c], eax
    mov eax, [sha_a]
    mov [sha_b], eax
    mov eax, [sha_t1]
    add eax, [sha_t2]
    mov [sha_a], eax
    inc dword [sha_round_index]
    jmp .round
.add_state:
    mov eax, [sha_a]
    add [sha_state], eax
    mov eax, [sha_b]
    add [sha_state + 4], eax
    mov eax, [sha_c]
    add [sha_state + 8], eax
    mov eax, [sha_d]
    add [sha_state + 12], eax
    mov eax, [sha_e]
    add [sha_state + 16], eax
    mov eax, [sha_f]
    add [sha_state + 20], eax
    mov eax, [sha_g]
    add [sha_state + 24], eax
    mov eax, [sha_h]
    add [sha_state + 28], eax
    ret

sha256_self_test:
    pushad
    mov esi, sha_test_input
    mov ecx, 3
    call sha256_hash
    mov esi, sha_digest
    mov edi, sha_test_digest
    mov ecx, 32
    repe cmpsb
    jne .failed
    mov byte [sha_ready], 1
    jmp .done
.failed:
    mov byte [sha_ready], 0
.done:
    popad
    ret

ata_wait_not_busy:
    mov dx, 0x1F7
    mov ecx, 0x100000
.wait:
    in al, dx
    cmp al, 0xFF
    je .failed
    test al, 0x80
    jz .ready
    loop .wait
    stc
    ret
.ready:
    test al, 1
    jnz .failed
    clc
    ret
.failed:
    stc
    ret

ata_wait_data:
    mov dx, 0x1F7
    mov ecx, 0x100000
.wait:
    in al, dx
    cmp al, 0xFF
    je .failed
    test al, 0x80
    jnz .retry
    test al, 1
    jnz .failed
    test al, 8
    jnz .ready
.retry:
    loop .wait
    stc
    ret
.ready:
    clc
    ret
.failed:
    stc
    ret

ata_read_sector:
    pushad
    mov [ata_lba], eax
    mov [ata_buffer], edi
    call ata_wait_not_busy
    jc .failed
    mov dx, 0x1F6
    mov al, 0xF0
    out dx, al
    mov dx, 0x3F6
    in al, dx
    in al, dx
    in al, dx
    in al, dx
    call ata_wait_not_busy
    jc .failed
    mov dx, 0x1F2
    mov al, 1
    out dx, al
    mov eax, [ata_lba]
    mov dx, 0x1F3
    out dx, al
    mov eax, [ata_lba]
    shr eax, 8
    mov dx, 0x1F4
    out dx, al
    mov eax, [ata_lba]
    shr eax, 16
    mov dx, 0x1F5
    out dx, al
    mov dx, 0x1F7
    mov al, 0x20
    out dx, al
    call ata_wait_data
    jc .failed
    mov edi, [ata_buffer]
    mov dx, 0x1F0
    mov ecx, 256
    rep insw
    call ata_wait_not_busy
    jc .failed
    mov byte [ata_result], 0
    jmp .return
.failed:
    mov byte [ata_result], 1
.return:
    popad
    cmp byte [ata_result], 0
    jne .error
    clc
    ret
.error:
    stc
    ret

ata_write_sector:
    pushad
    mov [ata_lba], eax
    mov [ata_buffer], esi
    call ata_wait_not_busy
    jc .failed
    mov dx, 0x1F6
    mov al, 0xF0
    out dx, al
    mov dx, 0x3F6
    in al, dx
    in al, dx
    in al, dx
    in al, dx
    call ata_wait_not_busy
    jc .failed
    mov dx, 0x1F2
    mov al, 1
    out dx, al
    mov eax, [ata_lba]
    mov dx, 0x1F3
    out dx, al
    mov eax, [ata_lba]
    shr eax, 8
    mov dx, 0x1F4
    out dx, al
    mov eax, [ata_lba]
    shr eax, 16
    mov dx, 0x1F5
    out dx, al
    mov dx, 0x1F7
    mov al, 0x30
    out dx, al
    call ata_wait_data
    jc .failed
    mov esi, [ata_buffer]
    mov dx, 0x1F0
    mov ecx, 256
    rep outsw
    call ata_wait_not_busy
    jc .failed
    mov dx, 0x1F7
    mov al, 0xE7
    out dx, al
    call ata_wait_not_busy
    jc .failed
    mov byte [ata_result], 0
    jmp .return
.failed:
    mov byte [ata_result], 1
.return:
    popad
    cmp byte [ata_result], 0
    jne .error
    clc
    ret
.error:
    stc
    ret

fs_init:
    mov byte [fs_ready], 0
    xor eax, eax
    mov edi, fs_sector_buffer
    call ata_read_sector
    jc .done
    cmp dword [fs_sector_buffer], 0x464E574F
    jne .format
    cmp word [fs_sector_buffer + 4], 0x3153
    jne .format
    mov eax, 1
    mov edi, fs_directory_buffer
    call ata_read_sector
    jc .done
    mov byte [fs_ready], 1
    ret
.format:
    mov edi, fs_sector_buffer
    xor eax, eax
    mov ecx, 512
    rep stosb
    mov dword [fs_sector_buffer], 0x464E574F
    mov word [fs_sector_buffer + 4], 0x3153
    xor eax, eax
    mov esi, fs_sector_buffer
    call ata_write_sector
    jc .done
    mov edi, fs_sector_buffer
    xor eax, eax
    mov ecx, 512
    rep stosb
    mov eax, 1
    mov esi, fs_sector_buffer
    call ata_write_sector
    jc .done
    mov byte [fs_ready], 1
.done:
    ret

scan_network_adapter:
    cmp byte [network_service_enabled], 1
    jne .disabled
    mov dword [network_status], network_missing
    mov byte [nic_ready], 0
    mov byte [network_adapter_kind], 0
    xor ecx, ecx
.device:
    mov eax, 0x80000000
    mov edx, ecx
    shl edx, 11
    or eax, edx
    mov dx, 0x0CF8
    out dx, eax
    mov dx, 0x0CFC
    in eax, dx
    cmp ax, 0x8086
    jne .next
    shr eax, 16
    cmp ax, 0x100E
    je .found
    cmp ax, 0x100F
    je .found
    cmp ax, 0x24FD
    je .wifi_found
.next:
    inc ecx
    cmp ecx, 8192
    jb .device
    ret
.wifi_found:
    mov [network_pci_device], ecx
    mov byte [network_adapter_kind], 2
    call inspect_iwlwifi_8265
    ret
.found:
    mov [network_pci_device], ecx
    mov byte [network_adapter_kind], 1
    call init_e1000
    ret
.disabled:
    mov dword [network_status], network_service_stopped
    mov byte [nic_ready], 0
    ret

inspect_iwlwifi_8265:
    pushad
    mov eax, 0x80000000
    mov edx, [network_pci_device]
    shl edx, 11
    or eax, edx
    add eax, 0x10
    mov dx, 0x0CF8
    out dx, eax
    mov dx, 0x0CFC
    in eax, dx
    test eax, 1
    jnz .unsupported
    mov edx, eax
    and edx, 6
    cmp edx, 4
    jne .bar_type_checked
    mov eax, 0x80000000
    mov edx, [network_pci_device]
    shl edx, 11
    or eax, edx
    add eax, 0x14
    mov dx, 0x0CF8
    out dx, eax
    mov dx, 0x0CFC
    in eax, dx
    test eax, eax
    jnz .unsupported
.bar_type_checked:
    mov eax, 0x80000000
    mov edx, [network_pci_device]
    shl edx, 11
    or eax, edx
    add eax, 0x10
    mov dx, 0x0CF8
    out dx, eax
    mov dx, 0x0CFC
    in eax, dx
    and eax, 0xFFFFFFF0
    test eax, eax
    jz .unsupported
    mov [wifi_mmio_base], eax

    mov eax, 0x80000000
    mov edx, [network_pci_device]
    shl edx, 11
    or eax, edx
    add eax, 4
    mov dx, 0x0CF8
    out dx, eax
    mov dx, 0x0CFC
    in ax, dx
    or ax, 2
    out dx, ax
    mov dword [network_status], network_wifi_mmio_ready
    popad
    ret
.unsupported:
    mov dword [network_status], network_wifi_bar_unsupported
    popad
    ret

init_e1000:
    pushad

    mov eax, 0x80000000
    mov edx, [network_pci_device]
    shl edx, 11
    or eax, edx
    add eax, 0x10
    mov dx, 0x0CF8
    out dx, eax
    mov dx, 0x0CFC
    in eax, dx
    test eax, 1
    jnz .failed
    and eax, 0xFFFFFFF0
    test eax, eax
    jz .failed
    mov [nic_mmio], eax

    mov eax, 0x80000000
    mov edx, [network_pci_device]
    shl edx, 11
    or eax, edx
    add eax, 4
    mov dx, 0x0CF8
    out dx, eax
    mov dx, 0x0CFC
    in eax, dx
    or eax, 6
    out dx, eax

    mov ebx, [nic_mmio]
    mov eax, [ebx]
    or eax, 0x04000000
    mov [ebx], eax
    mov ecx, 0x100000
.reset_wait:
    loop .reset_wait

    mov dword [ebx + 0x00D8], 0xFFFFFFFF
    mov dword [ebx + 0x0100], 0
    mov dword [ebx + 0x0400], 0

    xor ecx, ecx
.rx_descriptors:
    cmp ecx, 8
    jae .configure_rings
    mov eax, ecx
    shl eax, 11
    add eax, rx_buffers
    mov edx, ecx
    shl edx, 4
    mov [rx_ring + edx], eax
    mov dword [rx_ring + edx + 4], 0
    mov dword [rx_ring + edx + 8], 0
    inc ecx
    jmp .rx_descriptors

.configure_rings:
    mov ebx, [nic_mmio]
    mov eax, rx_ring
    mov [ebx + 0x2800], eax
    mov dword [ebx + 0x2804], 0
    mov dword [ebx + 0x2808], 128
    mov dword [ebx + 0x2810], 0
    mov dword [ebx + 0x2818], 7

    mov eax, tx_ring
    mov [ebx + 0x3800], eax
    mov dword [ebx + 0x3804], 0
    mov dword [ebx + 0x3808], 128
    mov dword [ebx + 0x3810], 0
    mov dword [ebx + 0x3818], 0

.initialize_tx:
    xor ecx, ecx
.tx_descriptor:
    cmp ecx, 8
    jae .enable_device
    mov eax, ecx
    shl eax, 11
    add eax, tx_buffers
    mov edx, ecx
    shl edx, 4
    mov [tx_ring + edx], eax
    mov dword [tx_ring + edx + 4], 0
    mov dword [tx_ring + edx + 8], 0
    mov byte [tx_ring + edx + 12], 1
    inc ecx
    jmp .tx_descriptor

.enable_device:
    mov eax, [ebx + 0x5400]
    mov [nic_mac], eax
    mov eax, [ebx + 0x5404]
    mov [nic_mac + 4], ax
    mov dword [ebx + 0x0410], 0x0060200A
    mov dword [ebx + 0x0400], 0x0004010A
    mov dword [ebx + 0x0100], 0x04008002

    mov eax, [ebx + 0x0008]
    test eax, 2
    jz .link_down
    mov dword [network_status], network_driver_ready
    mov byte [network_link_up], 1
    mov byte [nic_ready], 1
    jmp .ready
.link_down:
    mov dword [network_status], network_link_down
    mov byte [network_link_up], 0
.ready:
    mov byte [nic_ready], 1
    popad
    ret
.failed:
    mov dword [network_status], network_init_failed
    popad
    ret

e1000_stop:
    pushad
    cmp byte [nic_ready], 1
    jne .done
    cmp byte [network_adapter_kind], 1
    jne .disable_bus_master
    mov ebx, [nic_mmio]
    mov eax, [ebx + 0x0100]
    and eax, 0xFFFFFFFE
    mov [ebx + 0x0100], eax
    mov eax, [ebx + 0x0400]
    and eax, 0xFFFFFFFD
    mov [ebx + 0x0400], eax
.disable_bus_master:
    mov eax, 0x80000000
    mov edx, [network_pci_device]
    shl edx, 11
    or eax, edx
    add eax, 4
    mov dx, 0x0CF8
    out dx, eax
    mov dx, 0x0CFC
    in ax, dx
    and ax, 0xFFFB
    out dx, ax
.done:
    popad
    ret

dhcp_send_discover:
    mov byte [dhcp_state], 1
    call dhcp_send_packet
    test eax, eax
    jnz .failed
    mov dword [network_status], network_dhcp_wait_offer
    ret
.failed:
    mov byte [dhcp_state], 0
    mov dword [network_status], network_dhcp_failed
    ret

dhcp_send_request:
    mov byte [dhcp_state], 2
    call dhcp_send_packet
    test eax, eax
    jnz .failed
    mov dword [network_status], network_dhcp_wait_ack
    ret
.failed:
    mov byte [dhcp_state], 0
    mov dword [network_status], network_dhcp_failed
    ret

dhcp_tick:
    cmp byte [nic_ready], 1
    jne .done
    cmp byte [dhcp_state], 0
    jne .done
    cmp byte [dhcp_started], 1
    je .done
    mov ebx, [nic_mmio]
    test dword [ebx + 8], 2
    jz .link_down
    mov byte [network_link_up], 1
    jmp .start
.link_down:
    mov byte [network_link_up], 0
.start:
    mov byte [dhcp_started], 1
    call dhcp_send_discover
    ret
.done:
    ret

dhcp_send_packet:
    pushad
    mov edi, dhcp_packet
    xor eax, eax
    mov ecx, 304
    rep stosb

    mov edi, dhcp_packet
    mov al, 0xFF
    mov ecx, 6
    rep stosb
    mov esi, nic_mac
    mov ecx, 6
    rep movsb
    mov word [edi], 0x0008

    mov byte [dhcp_packet + 14], 0x45
    mov byte [dhcp_packet + 23], 17
    mov byte [dhcp_packet + 22], 64
    mov word [dhcp_packet + 18], 0
    mov word [dhcp_packet + 20], 0x0040
    mov dword [dhcp_packet + 26], 0
    mov dword [dhcp_packet + 30], 0xFFFFFFFF

    mov word [dhcp_packet + 34], 0x4400
    mov word [dhcp_packet + 36], 0x4300
    mov word [dhcp_packet + 40], 0

    mov byte [dhcp_packet + 42], 1
    mov byte [dhcp_packet + 43], 1
    mov byte [dhcp_packet + 44], 6
    mov dword [dhcp_packet + 46], 0x4F574E53
    mov word [dhcp_packet + 52], 0x0080
    mov esi, nic_mac
    mov edi, dhcp_packet + 70
    mov ecx, 6
    rep movsb
    mov dword [dhcp_packet + 278], 0x63538263

    cmp byte [dhcp_state], 2
    je .request
    mov word [dhcp_packet + 16], 0x0116
    mov word [dhcp_packet + 24], 0xD839
    mov word [dhcp_packet + 38], 0x0201
    mov byte [dhcp_packet + 282], 53
    mov byte [dhcp_packet + 283], 1
    mov byte [dhcp_packet + 284], 1
    mov byte [dhcp_packet + 285], 55
    mov byte [dhcp_packet + 286], 4
    mov byte [dhcp_packet + 287], 1
    mov byte [dhcp_packet + 288], 3
    mov byte [dhcp_packet + 289], 6
    mov byte [dhcp_packet + 290], 15
    mov byte [dhcp_packet + 291], 0xFF
    mov ecx, 292
    jmp .send

.request:
    mov word [dhcp_packet + 16], 0x0122
    mov word [dhcp_packet + 24], 0xCC39
    mov word [dhcp_packet + 38], 0x0E01
    mov byte [dhcp_packet + 282], 53
    mov byte [dhcp_packet + 283], 1
    mov byte [dhcp_packet + 284], 3
    mov byte [dhcp_packet + 285], 50
    mov byte [dhcp_packet + 286], 4
    mov eax, [dhcp_offered_ip]
    mov [dhcp_packet + 287], eax
    mov byte [dhcp_packet + 291], 54
    mov byte [dhcp_packet + 292], 4
    mov eax, [dhcp_server_ip]
    mov [dhcp_packet + 293], eax
    mov byte [dhcp_packet + 297], 55
    mov byte [dhcp_packet + 298], 4
    mov byte [dhcp_packet + 299], 1
    mov byte [dhcp_packet + 300], 3
    mov byte [dhcp_packet + 301], 6
    mov byte [dhcp_packet + 302], 15
    mov byte [dhcp_packet + 303], 0xFF
    mov ecx, 304

.send:
    mov esi, dhcp_packet
    call e1000_send_frame
    mov [dhcp_send_result], eax
    popad
    mov eax, [dhcp_send_result]
    ret

dhcp_process_frame:
    pushad
    cmp ecx, 285
    jb .done
    cmp word [esi + 12], 0x0008
    jne .done
    cmp byte [esi + 14], 0x45
    jne .done
    cmp byte [esi + 23], 17
    jne .done
    cmp word [esi + 34], 0x4300
    jne .done
    cmp word [esi + 36], 0x4400
    jne .done
    cmp byte [esi + 42], 2
    jne .done
    cmp dword [esi + 46], 0x4F574E53
    jne .done
    cmp dword [esi + 278], 0x63538263
    jne .done

    mov byte [dhcp_message_type], 0
    mov byte [dhcp_server_seen], 0
    mov eax, ecx
    sub eax, 282
    mov [dhcp_options_left], eax
    lea edi, [esi + 282]
.option:
    cmp dword [dhcp_options_left], 0
    je .options_done
    mov al, [edi]
    inc edi
    dec dword [dhcp_options_left]
    cmp al, 0xFF
    je .options_done
    test al, al
    jz .option
    cmp dword [dhcp_options_left], 0
    je .done
    movzx ecx, byte [edi]
    inc edi
    dec dword [dhcp_options_left]
    cmp ecx, [dhcp_options_left]
    ja .done
    cmp al, 53
    jne .server_option
    cmp ecx, 1
    jne .skip_option
    mov al, [edi]
    mov [dhcp_message_type], al
    jmp .skip_option
.server_option:
    cmp al, 54
    jne .skip_option
    cmp ecx, 4
    jne .skip_option
    mov eax, [edi]
    mov [dhcp_server_ip], eax
    mov byte [dhcp_server_seen], 1
.skip_option:
    add edi, ecx
    sub [dhcp_options_left], ecx
    jmp .option

.options_done:
    cmp byte [dhcp_state], 1
    jne .check_ack
    cmp byte [dhcp_message_type], 2
    jne .done
    cmp byte [dhcp_server_seen], 1
    jne .done
    mov eax, [esi + 58]
    mov [dhcp_offered_ip], eax
    call dhcp_send_request
    jmp .done

.check_ack:
    cmp byte [dhcp_state], 2
    jne .done
    cmp byte [dhcp_message_type], 5
    jne .check_nak
    mov eax, [esi + 58]
    test eax, eax
    jz .keep_offered_ip
    mov [dhcp_offered_ip], eax
.keep_offered_ip:
    mov byte [dhcp_state], 3
    mov dword [network_status], network_dhcp_bound
    jmp .done
.check_nak:
    cmp byte [dhcp_message_type], 6
    jne .done
    mov byte [dhcp_state], 0
    mov dword [network_status], network_dhcp_failed
.done:
    popad
    ret

e1000_poll_receive:
    cmp byte [nic_ready], 1
    jne .not_ready
    pushad
    movzx ecx, byte [rx_head]
    mov edx, ecx
    shl edx, 4
    test byte [rx_ring + edx + 12], 1
    jz .done
    mov esi, [rx_ring + edx]
    movzx ecx, word [rx_ring + edx + 8]
    call dhcp_process_frame
    mov byte [rx_ring + edx + 12], 0
    inc dword [network_rx_packets]
    mov al, [rx_head]
    inc al
    and al, 7
    mov [rx_head], al
    mov ebx, [nic_mmio]
    movzx eax, byte [rx_head]
    dec eax
    and eax, 7
    mov [ebx + 0x2818], eax
.done:
    popad
    ret
.not_ready:
    ret

e1000_send_frame:
    cmp byte [nic_ready], 1
    jne .unavailable
    cmp ecx, 14
    jb .invalid
    cmp ecx, 2048
    ja .invalid
    pushad
    mov [tx_length], ecx
    mov eax, [tx_head]
    mov [tx_current], eax
    mov edx, eax
    shl edx, 4
    test byte [tx_ring + edx + 12], 1
    jz .busy
    mov eax, [tx_current]
    shl eax, 11
    add eax, tx_buffers
    mov [tx_buffer_pointer], eax
    mov edi, eax
    mov ecx, [tx_length]
    rep movsb
    mov eax, [tx_current]
    shl eax, 4
    mov edx, [tx_buffer_pointer]
    mov [tx_ring + eax], edx
    mov dword [tx_ring + eax + 4], 0
    mov edx, [tx_current]
    shl edx, 4
    mov eax, [tx_length]
    mov [tx_ring + edx + 8], ax
    mov byte [tx_ring + edx + 12], 0
    mov byte [tx_ring + edx + 13], 0x0B
    mov ebx, [nic_mmio]
    mov ecx, [tx_current]
    inc ecx
    and ecx, 7
    mov [ebx + 0x3818], ecx
    mov [tx_head], ecx
    mov ecx, 0x100000
.wait_complete:
    mov eax, [tx_current]
    shl eax, 4
    test byte [tx_ring + eax + 12], 1
    jnz .sent
    loop .wait_complete
    popad
    mov eax, -1
    ret
.busy:
    popad
    mov eax, -1
    ret
.sent:
    popad
    xor eax, eax
    ret
.unavailable:
.invalid:
    mov eax, -1
    ret

show_terminal:
    mov byte [terminal_open], 1
    mov byte [active_window], 3
    mov dword [terminal_result], terminal_ready
    mov byte [terminal_length], 0
    mov byte [terminal_input], 0
    call redraw_active
    jmp event_loop

show_files_window:
    mov byte [terminal_open], 0
    mov byte [active_window], 5
    call fs_list_files
    call redraw_active
    jmp event_loop

redraw_active:
    call restore_mouse_cursor
    cmp byte [user_logged_in], 1
    jne .auth
    cmp byte [active_window], 1
    je .help
    cmp byte [active_window], 2
    je .info
    cmp byte [active_window], 3
    je .terminal
    cmp byte [active_window], 4
    je .start_menu
    cmp byte [active_window], 5
    je .files
    call draw_desktop
    jmp .cursor
.help:
    call draw_help_window
    jmp .cursor
.info:
    call draw_info_window
    jmp .cursor
.terminal:
    call draw_terminal
    jmp .cursor
.start_menu:
    call draw_desktop
    call draw_start_menu
    jmp .cursor
.files:
    call draw_files_window
    jmp .cursor
.auth:
    call draw_auth_window
.cursor:
    call draw_mouse_cursor
    ret

init_mouse:
    mov al, 0xA8
    call wait_input_clear
    mov dx, 0x64
    out dx, al
    mov al, 0xF6
    call send_mouse_command
    mov al, 0xF4
    call send_mouse_command
    ret

wait_input_clear:
    push eax
    push ecx
    mov ecx, 0x10000
.wait:
    call e1000_poll_receive
    in al, 0x64
    test al, 2
    jz .done
    loop .wait
.done:
    pop ecx
    pop eax
    ret

send_mouse_command:
    push eax
    call wait_input_clear
    mov dx, 0x64
    mov al, 0xD4
    out dx, al
    call wait_input_clear
    pop eax
    mov dx, 0x60
    out dx, al
    push ecx
    mov ecx, 0x10000
.ack:
    in al, 0x64
    test al, 1
    jz .next
    test al, 0x20
    jz .discard
    mov dx, 0x60
    in al, dx
    jmp .done
.discard:
    mov dx, 0x60
    in al, dx
.next:
    loop .ack
.done:
    pop ecx
    ret

handle_mouse_byte:
    cmp byte [mouse_packet_index], 0
    jne .packet_byte
    test al, 8
    jz .done
    mov [mouse_packet], al
    mov byte [mouse_packet_index], 1
    ret
.packet_byte:
    cmp byte [mouse_packet_index], 1
    jne .packet_y
    mov [mouse_packet + 1], al
    mov byte [mouse_packet_index], 2
    ret
.packet_y:
    mov [mouse_packet + 2], al
    mov byte [mouse_packet_index], 0
    call restore_mouse_cursor
    call update_mouse_position
    call draw_mouse_cursor
    test byte [mouse_packet], 1
    jz .done
    call handle_mouse_click
.done:
    ret

update_mouse_position:
    test byte [mouse_packet], 0x40
    jnz .y
    movsx eax, byte [mouse_packet + 1]
    add [mouse_x], eax
    cmp dword [mouse_x], 0
    jge .x_max
    mov dword [mouse_x], 0
.x_max:
    cmp dword [mouse_x], 312
    jle .y
    mov dword [mouse_x], 312
.y:
    test byte [mouse_packet], 0x80
    jnz .done
    movsx eax, byte [mouse_packet + 2]
    neg eax
    add [mouse_y], eax
    cmp dword [mouse_y], 0
    jge .y_max
    mov dword [mouse_y], 0
.y_max:
    cmp dword [mouse_y], 190
    jle .done
    mov dword [mouse_y], 190
.done:
    ret

handle_mouse_click:
    cmp byte [user_logged_in], 1
    jne .done
    cmp byte [active_window], 4
    je .menu_click
    cmp byte [active_window], 0
    jne .close_check
    cmp dword [mouse_x], 34
    jb .taskbar_check
    cmp dword [mouse_x], 118
    ja .taskbar_check
    cmp dword [mouse_y], 66
    jb .taskbar_check
    cmp dword [mouse_y], 92
    jb .open_terminal
    cmp dword [mouse_y], 96
    jb .taskbar_check
    cmp dword [mouse_y], 122
    jb .open_files
    cmp dword [mouse_y], 126
    jb .taskbar_check
    cmp dword [mouse_y], 152
    jb .open_info
.taskbar_check:
    cmp dword [mouse_y], 180
    jb .done
    cmp dword [mouse_x], 8
    jb .done
    cmp dword [mouse_x], 55
    ja .done
    mov byte [active_window], 4
    call redraw_active
    ret
.menu_click:
    cmp dword [mouse_x], 8
    jb .dismiss_menu
    cmp dword [mouse_x], 140
    ja .dismiss_menu
    cmp dword [mouse_y], 98
    jb .dismiss_menu
    cmp dword [mouse_y], 117
    jb .open_terminal
    cmp dword [mouse_y], 118
    jb .dismiss_menu
    cmp dword [mouse_y], 137
    jb .open_files
    cmp dword [mouse_y], 138
    jb .dismiss_menu
    cmp dword [mouse_y], 157
    jb .open_info
    cmp dword [mouse_y], 158
    jb .dismiss_menu
    cmp dword [mouse_y], 177
    jb .open_help
.dismiss_menu:
    mov byte [active_window], 0
    call redraw_active
    ret
.open_terminal:
    mov byte [active_window], 3
    mov byte [terminal_open], 1
    mov dword [terminal_result], terminal_ready
    mov byte [terminal_length], 0
    mov byte [terminal_input], 0
    call redraw_active
    ret
.open_files:
    jmp show_files_window
.open_info:
    mov byte [active_window], 2
    call redraw_active
    ret
.open_help:
    mov byte [active_window], 1
    call redraw_active
    ret
.close_check:
    cmp dword [mouse_y], 28
    jb .dialog_close
    cmp dword [mouse_y], 44
    ja .dialog_close
    cmp dword [mouse_x], 263
    jb .done
    cmp dword [mouse_x], 285
    ja .done
    mov byte [terminal_open], 0
    mov byte [active_window], 0
    call redraw_active
    ret
.dialog_close:
    cmp dword [mouse_x], 257
    jb .done
    cmp dword [mouse_x], 269
    ja .done
    cmp dword [mouse_y], 53
    jb .done
    cmp dword [mouse_y], 68
    ja .done
    mov byte [terminal_open], 0
    mov byte [active_window], 0
    call redraw_active
.done:
    ret

draw_mouse_cursor:
    pushad
    call save_mouse_background
    xor ecx, ecx
.outline_row:
    cmp ecx, 10
    jae .inner_start
    mov al, [mouse_outline + ecx]
    mov [cursor_mask], al
    xor ebx, ebx
.outline_pixel:
    cmp ebx, 8
    jae .next_outline_row
    test byte [cursor_mask], 0x80
    jz .outline_skip
    call cursor_pixel_address
    jc .outline_skip
    mov byte [edi], 0
.outline_skip:
    shl byte [cursor_mask], 1
    inc ebx
    jmp .outline_pixel
.next_outline_row:
    inc ecx
    jmp .outline_row

.inner_start:
    xor ecx, ecx
.inner_row:
    cmp ecx, 8
    jae .done
    mov al, [mouse_inner + ecx]
    mov [cursor_mask], al
    xor ebx, ebx
.inner_pixel:
    cmp ebx, 6
    jae .next_inner_row
    test byte [cursor_mask], 0x80
    jz .inner_skip
    call cursor_pixel_address
    jc .inner_skip
    mov byte [edi], 15
.inner_skip:
    shl byte [cursor_mask], 1
    inc ebx
    jmp .inner_pixel
.next_inner_row:
    inc ecx
    jmp .inner_row
.done:
    mov byte [cursor_visible], 1
    popad
    ret

save_mouse_background:
    pushad
    xor ecx, ecx
.row:
    cmp ecx, 10
    jae .done
    xor ebx, ebx
.column:
    cmp ebx, 8
    jae .next_row
    call cursor_pixel_address
    jc .skip
    mov eax, ecx
    shl eax, 3
    add eax, ebx
    mov [cursor_save_index], eax
    mov al, [edi]
    mov edx, [cursor_save_index]
    mov [mouse_background + edx], al
.skip:
    inc ebx
    jmp .column
.next_row:
    inc ecx
    jmp .row
.done:
    popad
    ret

restore_mouse_cursor:
    cmp byte [cursor_visible], 0
    je .done
    pushad
    xor ecx, ecx
.row:
    cmp ecx, 10
    jae .done_inner
    xor ebx, ebx
.column:
    cmp ebx, 8
    jae .next_row
    call cursor_pixel_address
    jc .skip
    mov eax, ecx
    shl eax, 3
    add eax, ebx
    mov al, [mouse_background + eax]
    mov [edi], al
.skip:
    inc ebx
    jmp .column
.next_row:
    inc ecx
    jmp .row
.done_inner:
    mov byte [cursor_visible], 0
    popad
.done:
    ret

cursor_pixel_address:
    mov eax, [mouse_x]
    add eax, ebx
    cmp eax, 320
    jae .outside
    mov edx, [mouse_y]
    add edx, ecx
    cmp edx, 200
    jae .outside
    imul edx, SCREEN_WIDTH
    add eax, edx
    mov edi, VIDEO_MEMORY
    add edi, eax
    clc
    ret
.outside:
    stc
    ret

equals:
.compare:
    mov al, [esi]
    cmp al, [edi]
    jne .not_equal
    inc esi
    inc edi
    test al, al
    jnz .compare
    xor eax, eax
    ret
.not_equal:
    mov eax, 1
    ret

starts_with:
.compare:
    mov al, [edi]
    test al, al
    jz .matched
    cmp al, [esi]
    jne .not_matched
    inc esi
    inc edi
    jmp .compare
.matched:
    xor eax, eax
    ret
.not_matched:
    mov eax, 1
    ret

terminal_key:
    cmp al, 0x01
    je close_window
    cmp al, 0x1C
    je terminal_submit
    cmp al, 0x0E
    je terminal_backspace

    movzx ebx, al
    mov al, [keymap + ebx]
    test al, al
    jz event_loop
    movzx ebx, byte [terminal_length]
    cmp ebx, 43
    jae event_loop
    mov [terminal_input + ebx], al
    inc byte [terminal_length]
    movzx ebx, byte [terminal_length]
    mov byte [terminal_input + ebx], 0
    call redraw_active
    jmp event_loop

terminal_security_scan:
    cmp byte [security_scan_service_enabled], 1
    jne .disabled
    cmp byte [fs_ready], 1
    jne .unavailable
    call fs_read_directory
    jc .error
    mov dword [security_file_count], 0
    xor ebx, ebx
.entry:
    cmp ebx, 16
    jae .clean
    mov eax, ebx
    shl eax, 5
    lea edi, [fs_directory_buffer + eax]
    cmp byte [edi], 0
    je .next
    inc dword [security_file_count]
    mov eax, [edi + 12]
    cmp eax, 43
    ja .warning
    mov eax, [edi + 16]
    cmp eax, 2
    jb .warning
    cmp eax, 18
    jae .warning
.next:
    inc ebx
    jmp .entry
.clean:
    mov dword [terminal_result], terminal_security_clean
    jmp terminal_advance_command
.warning:
    mov dword [terminal_result], terminal_security_warning
    jmp terminal_advance_command
.disabled:
    mov dword [terminal_result], terminal_security_disabled
    jmp terminal_advance_command
.unavailable:
.error:
    mov dword [terminal_result], terminal_security_error
    jmp terminal_advance_command

terminal_backspace:
    cmp byte [terminal_length], 0
    je event_loop
    dec byte [terminal_length]
    movzx ebx, byte [terminal_length]
    mov byte [terminal_input + ebx], 0
    call redraw_active
    jmp event_loop

terminal_submit:
    mov dword [command_cursor], terminal_input
    mov dword [next_command_cursor], 0
    mov dword [terminal_result], terminal_blank
    jmp terminal_next_command

terminal_next_command:
    mov esi, [command_cursor]
    test esi, esi
    jz terminal_reset_input

    mov edi, esi
.find_separator:
    mov al, [edi]
    test al, al
    jz .last_command
    cmp al, ';'
    je .separator_found
    inc edi
    jmp .find_separator

.separator_found:
    lea eax, [edi + 1]
    mov [next_command_cursor], eax
    mov byte [edi], 0
    jmp .trim_command

.last_command:
    mov dword [next_command_cursor], 0

.trim_command:
    mov esi, [command_cursor]
.skip_spaces:
    cmp byte [esi], ' '
    jne .dispatch
    inc esi
    jmp .skip_spaces

.dispatch:
    cmp byte [esi], 0
    je terminal_advance_command

    mov edi, terminal_help_command
    call equals
    test eax, eax
    jz terminal_show_help

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_info_command
    call equals
    test eax, eax
    jz terminal_show_info

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_version_command
    call equals
    test eax, eax
    jz terminal_show_version

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_clear_command
    call equals
    test eax, eax
    jz terminal_clear_output

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_desktop_command
    call equals
    test eax, eax
    jz close_window

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_reboot_command
    call equals
    test eax, eax
    jz reboot

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_logout_command
    call equals
    test eax, eax
    jz terminal_logout

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_user_command
    call equals
    test eax, eax
    jz terminal_show_user

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_services_command
    call equals
    test eax, eax
    jz terminal_show_services

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_service_network_start_command
    call equals
    test eax, eax
    jz terminal_start_network

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_service_network_stop_command
    call equals
    test eax, eax
    jz terminal_stop_network

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_service_scan_start_command
    call equals
    test eax, eax
    jz terminal_start_security_scan

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_service_scan_stop_command
    call equals
    test eax, eax
    jz terminal_stop_security_scan

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_service_filesystem_stop_command
    call equals
    test eax, eax
    jz terminal_required_service

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_service_auth_stop_command
    call equals
    test eax, eax
    jz terminal_required_service

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_security_command
    call equals
    test eax, eax
    jz terminal_security_scan

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_scan_command
    call equals
    test eax, eax
    jz terminal_security_scan

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_net_command
    call equals
    test eax, eax
    jz terminal_show_network

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_ls_command
    call equals
    test eax, eax
    jz terminal_list_files

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_files_command
    call equals
    test eax, eax
    jz show_files_window

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_cat_prefix
    call starts_with
    test eax, eax
    jz fs_cat_file

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_write_prefix
    call starts_with
    test eax, eax
    jz fs_write_file

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_delete_prefix
    call starts_with
    test eax, eax
    jz fs_delete_file

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_echo_prefix
    call starts_with
    test eax, eax
    jz terminal_echo

    mov esi, [command_cursor]
    call skip_spaces
    mov edi, terminal_calc_prefix
    call starts_with
    test eax, eax
    jz terminal_calculate

    mov dword [terminal_result], terminal_unknown
    jmp terminal_advance_command

terminal_show_help:
    mov dword [terminal_result], terminal_help_text
    jmp terminal_advance_command

terminal_show_info:
    mov dword [terminal_result], terminal_info_text
    jmp terminal_advance_command

terminal_show_version:
    mov dword [terminal_result], terminal_version_text
    jmp terminal_advance_command

terminal_show_user:
    mov dword [terminal_result], auth_username
    jmp terminal_advance_command

terminal_logout:
    mov byte [user_logged_in], 0
    mov byte [auth_state], 4
    mov byte [terminal_open], 0
    mov byte [terminal_length], 0
    mov byte [terminal_input], 0
    mov byte [active_window], 6
    mov dword [auth_message], auth_login_prompt
    call redraw_active
    jmp event_loop

terminal_show_network:
    mov eax, [network_status]
    mov [terminal_result], eax
    jmp terminal_advance_command

terminal_show_services:
    cmp byte [network_service_enabled], 1
    jne .network_off
    cmp byte [security_scan_service_enabled], 1
    jne .scan_off
    mov dword [terminal_result], services_all_on
    jmp terminal_advance_command
.scan_off:
    mov dword [terminal_result], services_network_on
    jmp terminal_advance_command
.network_off:
    cmp byte [security_scan_service_enabled], 1
    jne .all_optional_off
    mov dword [terminal_result], services_scan_on
    jmp terminal_advance_command
.all_optional_off:
    mov dword [terminal_result], services_optional_off
    jmp terminal_advance_command

terminal_start_network:
    cmp byte [network_service_enabled], 1
    je .already_running
    mov byte [network_service_enabled], 1
    call scan_network_adapter
    mov dword [terminal_result], service_network_enabled
    jmp terminal_advance_command
.already_running:
    mov dword [terminal_result], service_already_running
    jmp terminal_advance_command

terminal_stop_network:
    cmp byte [network_service_enabled], 0
    je .already_stopped
    call e1000_stop
    mov byte [network_service_enabled], 0
    mov byte [nic_ready], 0
    mov byte [network_link_up], 0
    mov byte [dhcp_state], 0
    mov byte [dhcp_started], 0
    mov dword [network_status], network_service_stopped
    mov dword [terminal_result], service_network_stopped
    jmp terminal_advance_command
.already_stopped:
    mov dword [terminal_result], service_already_stopped
    jmp terminal_advance_command

terminal_start_security_scan:
    cmp byte [security_scan_service_enabled], 1
    je .already_running
    mov byte [security_scan_service_enabled], 1
    mov dword [terminal_result], service_scan_enabled
    jmp terminal_advance_command
.already_running:
    mov dword [terminal_result], service_already_running
    jmp terminal_advance_command

terminal_stop_security_scan:
    cmp byte [security_scan_service_enabled], 0
    je .already_stopped
    mov byte [security_scan_service_enabled], 0
    mov dword [terminal_result], service_scan_stopped
    jmp terminal_advance_command
.already_stopped:
    mov dword [terminal_result], service_already_stopped
    jmp terminal_advance_command

terminal_required_service:
    mov dword [terminal_result], service_required
    jmp terminal_advance_command

fs_read_directory:
    cmp byte [fs_ready], 1
    jne .unavailable
    mov eax, 1
    mov edi, fs_directory_buffer
    call ata_read_sector
    ret
.unavailable:
    stc
    ret

fs_parse_name:
    mov byte [fs_parse_ok], 0
    mov edi, fs_filename
    xor eax, eax
    mov ecx, 12
    rep stosb
    xor ebx, ebx
.copy:
    mov al, [esi]
    test al, al
    jz .name_done
    cmp al, ' '
    je .name_done
    cmp ebx, 8
    jae .invalid
    mov [fs_filename + ebx], al
    inc ebx
    inc esi
    jmp .copy
.name_done:
    test ebx, ebx
    jz .invalid
.skip_spaces:
    cmp byte [esi], ' '
    jne .done
    inc esi
    jmp .skip_spaces
.done:
    mov [fs_argument_cursor], esi
    mov byte [fs_parse_ok], 1
    ret
.invalid:
    ret

fs_find_entry:
    mov dword [fs_found_index], -1
    call fs_read_directory
    jc .error
    xor ebx, ebx
.search:
    cmp ebx, 16
    jae .not_found
    mov eax, ebx
    shl eax, 5
    lea edi, [fs_directory_buffer + eax]
    cmp byte [edi], 0
    je .next
    mov esi, fs_filename
    mov ecx, 12
    repe cmpsb
    je .found
.next:
    inc ebx
    jmp .search
.found:
    mov [fs_found_index], ebx
.not_found:
    clc
    ret
.error:
    stc
    ret

fs_list_files:
    mov dword [fs_list_result], terminal_disk_unavailable
    call fs_read_directory
    jc .done
    mov edi, fs_list_buffer
    xor eax, eax
    mov ecx, 44
    rep stosb
    xor ebx, ebx
    mov dword [fs_list_length], 0
.entry:
    cmp ebx, 16
    jae .finished
    mov eax, ebx
    shl eax, 5
    lea esi, [fs_directory_buffer + eax]
    cmp byte [esi], 0
    je .next_entry
    cmp dword [fs_list_length], 0
    je .copy_name
    cmp dword [fs_list_length], 42
    jae .finished
    mov edi, fs_list_buffer
    add edi, [fs_list_length]
    mov byte [edi], ' '
    inc dword [fs_list_length]
.copy_name:
    mov edi, fs_list_buffer
    add edi, [fs_list_length]
.copy_character:
    mov al, [esi]
    test al, al
    jz .name_done
    cmp dword [fs_list_length], 43
    jae .finished
    mov [edi], al
    inc edi
    inc esi
    inc dword [fs_list_length]
    jmp .copy_character
.name_done:
    mov dword [fs_list_result], fs_list_buffer
.next_entry:
    inc ebx
    jmp .entry
.finished:
    cmp dword [fs_list_length], 0
    jne .done
    mov dword [fs_list_result], terminal_no_files
.done:
    ret

fs_write_file:
    cmp byte [fs_ready], 1
    jne .unavailable
    call fs_parse_name
    cmp byte [fs_parse_ok], 1
    jne .usage
    mov esi, [fs_argument_cursor]
    mov edi, fs_text_buffer
    xor eax, eax
    mov ecx, 44
    rep stosb
    mov esi, [fs_argument_cursor]
    xor ebx, ebx
.copy_text:
    mov al, [esi]
    test al, al
    jz .text_done
    cmp ebx, 43
    jae .text_done
    mov [fs_text_buffer + ebx], al
    inc ebx
    inc esi
    jmp .copy_text
.text_done:
    mov [fs_text_length], bl
    call fs_find_entry
    jc .io_error
    cmp dword [fs_found_index], -1
    jne .entry_ready
    xor ebx, ebx
.find_free:
    cmp ebx, 16
    jae .full
    mov eax, ebx
    shl eax, 5
    cmp byte [fs_directory_buffer + eax], 0
    je .free_found
    inc ebx
    jmp .find_free
.free_found:
    mov [fs_found_index], ebx
.entry_ready:
    mov edi, fs_sector_buffer
    xor eax, eax
    mov ecx, 512
    rep stosb
    mov esi, fs_text_buffer
    movzx ecx, byte [fs_text_length]
    mov edi, fs_sector_buffer
    rep movsb
    mov eax, [fs_found_index]
    add eax, 2
    mov esi, fs_sector_buffer
    call ata_write_sector
    jc .io_error

    mov eax, [fs_found_index]
    shl eax, 5
    lea edi, [fs_directory_buffer + eax]
    push edi
    xor eax, eax
    mov ecx, 32
    rep stosb
    pop edi
    mov esi, fs_filename
    mov ecx, 12
    rep movsb
    movzx eax, byte [fs_text_length]
    mov [edi], eax
    mov eax, [fs_found_index]
    add eax, 2
    mov [edi + 4], eax
    mov eax, 1
    mov esi, fs_directory_buffer
    call ata_write_sector
    jc .io_error
    mov dword [terminal_result], terminal_file_saved
    jmp terminal_advance_command
.unavailable:
    mov dword [terminal_result], terminal_disk_unavailable
    jmp terminal_advance_command
.usage:
    mov dword [terminal_result], terminal_write_usage
    jmp terminal_advance_command
.full:
    mov dword [terminal_result], terminal_disk_full
    jmp terminal_advance_command
.io_error:
    mov dword [terminal_result], terminal_disk_error
    jmp terminal_advance_command

fs_cat_file:
    cmp byte [fs_ready], 1
    jne .unavailable
    call fs_parse_name
    cmp byte [fs_parse_ok], 1
    jne .usage
    call fs_find_entry
    jc .io_error
    cmp dword [fs_found_index], -1
    je .not_found
    mov eax, [fs_found_index]
    shl eax, 5
    mov ecx, [fs_directory_buffer + eax + 12]
    mov eax, [fs_directory_buffer + eax + 16]
    mov [fs_text_length], cl
    mov edi, fs_sector_buffer
    call ata_read_sector
    jc .io_error
    mov edi, fs_content_buffer
    xor eax, eax
    mov ecx, 44
    rep stosb
    movzx ecx, byte [fs_text_length]
    cmp ecx, 43
    jbe .copy
    mov ecx, 43
.copy:
    mov esi, fs_sector_buffer
    mov edi, fs_content_buffer
    rep movsb
    mov dword [terminal_result], fs_content_buffer
    jmp terminal_advance_command
.unavailable:
    mov dword [terminal_result], terminal_disk_unavailable
    jmp terminal_advance_command
.usage:
    mov dword [terminal_result], terminal_cat_usage
    jmp terminal_advance_command
.not_found:
    mov dword [terminal_result], terminal_file_missing
    jmp terminal_advance_command
.io_error:
    mov dword [terminal_result], terminal_disk_error
    jmp terminal_advance_command

fs_delete_file:
    cmp byte [fs_ready], 1
    jne .unavailable
    call fs_parse_name
    cmp byte [fs_parse_ok], 1
    jne .usage
    call fs_find_entry
    jc .io_error
    cmp dword [fs_found_index], -1
    je .not_found
    mov eax, [fs_found_index]
    shl eax, 5
    mov byte [fs_directory_buffer + eax], 0
    mov dword [fs_directory_buffer + eax + 12], 0
    mov dword [fs_directory_buffer + eax + 16], 0
    mov eax, 1
    mov esi, fs_directory_buffer
    call ata_write_sector
    jc .io_error
    mov dword [terminal_result], terminal_file_deleted
    jmp terminal_advance_command
.unavailable:
    mov dword [terminal_result], terminal_disk_unavailable
    jmp terminal_advance_command
.usage:
    mov dword [terminal_result], terminal_delete_usage
    jmp terminal_advance_command
.not_found:
    mov dword [terminal_result], terminal_file_missing
    jmp terminal_advance_command
.io_error:
    mov dword [terminal_result], terminal_disk_error
    jmp terminal_advance_command

terminal_list_files:
    call fs_list_files
    mov eax, [fs_list_result]
    mov [terminal_result], eax
    jmp terminal_advance_command

terminal_echo:
    cmp byte [esi], 0
    je .empty
    lea esi, [esi + 5]
    mov edi, terminal_echo_buffer
.copy:
    mov al, [esi]
    mov [edi], al
    test al, al
    jz .done
    inc esi
    inc edi
    jmp .copy
.done:
    mov dword [terminal_result], terminal_echo_buffer
    jmp terminal_advance_command
.empty:
    mov dword [terminal_result], terminal_echo_usage
    jmp terminal_advance_command

terminal_calculate:
    call calculate_expression
    jmp terminal_advance_command

terminal_clear_output:
    mov dword [terminal_result], terminal_blank
    jmp terminal_advance_command

terminal_advance_command:
    mov eax, [next_command_cursor]
    mov [command_cursor], eax
    jmp terminal_next_command

skip_spaces:
    cmp byte [esi], ' '
    jne .done
    inc esi
    jmp skip_spaces
.done:
    ret

calculate_expression:
    call skip_spaces
    call parse_decimal
    jc .invalid
    mov [calc_left], eax

    call skip_spaces
    mov al, [esi]
    cmp al, '+'
    je .operator_valid
    cmp al, '-'
    jne .invalid
.operator_valid:
    mov [calc_operator], al
    inc esi

    call parse_decimal
    jc .invalid
    mov [calc_right], eax
    call skip_spaces
    cmp byte [esi], 0
    jne .invalid

    mov eax, [calc_left]
    cmp byte [calc_operator], '+'
    jne .subtract
    add eax, [calc_right]
    jo .invalid
    jmp .format
.subtract:
    sub eax, [calc_right]
    jo .invalid
.format:
    call format_calculation_result
    ret
.invalid:
    mov dword [terminal_result], terminal_calc_usage
    ret

parse_decimal:
    xor eax, eax
    xor ecx, ecx
.digit:
    mov bl, [esi]
    cmp bl, '0'
    jb .done
    cmp bl, '9'
    ja .done
    sub bl, '0'
    movzx ebx, bl
    push ebx
    mov ebx, 10
    mul ebx
    pop ebx
    test edx, edx
    jnz .invalid
    add eax, ebx
    jc .invalid
    cmp eax, 0x7FFFFFFF
    ja .invalid
    inc esi
    inc ecx
    jmp .digit
.done:
    test ecx, ecx
    jz .invalid
    clc
    ret
.invalid:
    stc
    ret

format_calculation_result:
    mov edi, calc_result_buffer + 11
    mov byte [edi], 0
    dec edi
    test eax, eax
    jns .digits
    neg eax
    mov byte [calc_negative], 1
    jmp .convert
.digits:
    mov byte [calc_negative], 0
.convert:
    mov ebx, 10
.digit:
    xor edx, edx
    div ebx
    add dl, '0'
    mov [edi], dl
    dec edi
    test eax, eax
    jnz .digit
    cmp byte [calc_negative], 0
    je .finish
    mov byte [edi], '-'
    dec edi
.finish:
    inc edi
    mov [terminal_result], edi
    ret

reboot:
    cli
    mov al, 0xFE
    out 0x64, al
.halt:
    hlt
    jmp .halt

terminal_reset_input:
    mov byte [terminal_length], 0
    mov byte [terminal_input], 0
    call redraw_active
    jmp event_loop

set_palette:
    mov dx, 0x3C8
    mov al, 32
    out dx, al
    mov dx, 0x3C9
    mov esi, palette_data
    mov ecx, 168
.write:
    lodsb
    out dx, al
    loop .write
    ret

draw_desktop:
    call draw_wallpaper

    mov dword [rect_x], 0
    mov dword [rect_y], 0
    mov dword [rect_w], 320
    mov dword [rect_h], 22
    mov byte [glass_color], 68
    call draw_glass
    RECT 0, 0, 320, 1, 80
    RECT 10, 18, 300, 1, 79
    TEXT 12, 8, 80, desktop_title
    TEXT 272, 8, 80, desktop_version

    RECT 22, 35, 276, 137, 32
    RECT 24, 32, 272, 140, 41
    mov dword [rect_x], 25
    mov dword [rect_y], 33
    mov dword [rect_w], 270
    mov dword [rect_h], 137
    mov byte [glass_color], 67
    call draw_glass

    mov dword [rect_x], 27
    mov dword [rect_y], 35
    mov dword [rect_w], 266
    mov dword [rect_h], 22
    mov byte [glass_color], 75
    call draw_glass
    RECT 27, 35, 266, 1, 81
    RECT 33, 40, 2, 12, 80
    RECT 38, 40, 2, 12, 80
    RECT 35, 44, 3, 2, 80
    TEXT 48, 43, 80, window_title
    TEXT 238, 43, 80, desktop_ready_label
    RECT 27, 57, 266, 1, 71

    mov dword [rect_x], 32
    mov dword [rect_y], 62
    mov dword [rect_w], 82
    mov dword [rect_h], 101
    mov byte [glass_color], 65
    call draw_glass

    mov dword [rect_x], 118
    mov dword [rect_y], 62
    mov dword [rect_w], 171
    mov dword [rect_h], 101
    mov byte [glass_color], 69
    call draw_glass
    RECT 36, 64, 74, 27, 68
    RECT 36, 64, 74, 1, 80
    RECT 40, 70, 12, 12, 42
    TEXT 44, 73, 80, menu_terminal_icon
    TEXT 58, 75, 80, menu_terminal
    RECT 36, 95, 74, 27, 68
    RECT 36, 95, 74, 1, 80
    RECT 40, 101, 12, 12, 45
    TEXT 44, 104, 80, menu_files_icon
    TEXT 58, 106, 80, menu_files
    RECT 36, 126, 74, 27, 68
    RECT 36, 126, 74, 1, 80
    RECT 40, 132, 12, 12, 43
    TEXT 44, 135, 80, menu_info_icon
    TEXT 58, 137, 80, menu_info
    TEXT 126, 70, 80, welcome_label
    RECT 126, 79, 151, 1, 80
    TEXT 126, 86, 80, system_label
    TEXT 126, 99, 80, terminal_shortcut_label
    TEXT 126, 110, 80, files_shortcut_label
    TEXT 126, 121, 80, network_label
    mov dword [text_x], 126
    mov dword [text_y], 132
    mov byte [text_color], 80
    mov esi, [network_status]
    call draw_text
    TEXT 126, 148, 80, disk_status_label

    mov dword [rect_x], 0
    mov dword [rect_y], 180
    mov dword [rect_w], 320
    mov dword [rect_h], 20
    mov byte [glass_color], 69
    call draw_glass
    RECT 0, 180, 320, 1, 81
    RECT 0, 182, 320, 1, 78
    RECT 8, 183, 17, 15, 32
    RECT 10, 184, 13, 12, 39
    RECT 12, 185, 9, 10, 40
    RECT 14, 187, 5, 6, 43
    TEXT 30, 188, 79, start_label
    RECT 77, 185, 1, 11, 40
    TEXT 86, 188, 80, desktop_hint

    RECT 283, 185, 1, 12, 40
    RECT 286, 185, 1, 12, 40
    TEXT 291, 188, 80, clock_label
    ret

draw_start_menu:
    RECT 5, 75, 136, 104, 32
    RECT 7, 72, 132, 106, 41
    RECT 8, 73, 130, 104, 40
    mov dword [rect_x], 9
    mov dword [rect_y], 74
    mov dword [rect_w], 128
    mov dword [rect_h], 20
    mov byte [glass_color], 74
    call draw_glass
    RECT 9, 74, 128, 1, 81
    TEXT 19, 81, 80, menu_title
    RECT 13, 98, 120, 18, 79
    RECT 14, 99, 118, 16, 68
    RECT 17, 102, 12, 11, 42
    TEXT 35, 105, 80, menu_terminal
    RECT 13, 118, 120, 18, 79
    RECT 14, 119, 118, 16, 68
    RECT 17, 122, 12, 11, 45
    TEXT 35, 125, 80, menu_files
    RECT 13, 138, 120, 18, 79
    RECT 14, 139, 118, 16, 68
    RECT 17, 142, 12, 11, 43
    TEXT 35, 145, 80, menu_info
    RECT 13, 158, 120, 18, 79
    RECT 14, 159, 118, 16, 68
    RECT 17, 162, 12, 11, 47
    TEXT 35, 165, 80, menu_help
    ret

draw_wallpaper:
    pushad
    xor ebp, ebp
.row:
    cmp ebp, 180
    jae .done
    mov eax, ebp
    imul eax, 31
    mov ebx, 180
    xor edx, edx
    div ebx
    add eax, 32
    mov [gradient_color], al
    mov edi, VIDEO_MEMORY
    mov eax, ebp
    imul eax, SCREEN_WIDTH
    add edi, eax
    mov ecx, SCREEN_WIDTH
    mov al, byte [gradient_color]
    rep stosb
    inc ebp
    jmp .row
.done:
    call draw_aero_waves
    popad
    ret

draw_aero_waves:
    pushad
    xor ebx, ebx
.column:
    cmp ebx, 320
    jae .done
    mov eax, ebx
    sub eax, 160
    jns .distance_ready
    neg eax
.distance_ready:

    xor edx, edx
    mov ecx, 5
    div ecx
    mov ecx, 140
    sub ecx, eax
    mov [pixel_y], ecx
    mov [pixel_x], ebx
    mov byte [text_color], 62
    call draw_pixel
    inc dword [pixel_y]
    mov byte [text_color], 79
    call draw_pixel

    mov eax, ebx
    sub eax, 160
    jns .distance_second
    neg eax
.distance_second:
    mov ecx, 7
    xor edx, edx
    div ecx
    mov ecx, 163
    sub ecx, eax
    mov [pixel_y], ecx
    mov [pixel_x], ebx
    mov byte [text_color], 57
    call draw_pixel
    inc ebx
    jmp .column
.done:
    popad
    ret

draw_glass:
    pushad
    mov al, [glass_color]
    mov [rect_color], al
    call draw_rect
    xor ebp, ebp
.row:
    cmp ebp, [rect_h]
    jae .done
    xor ebx, ebx
.column:
    cmp ebx, [rect_w]
    jae .next_row
    test ebx, 7
    jnz .skip_pixel
    test ebp, 7
    jnz .skip_pixel
    mov eax, [rect_y]
    add eax, ebp
    shr eax, 4
    add al, [glass_color]
    mov [glass_pixel_color], al
    mov eax, [rect_y]
    add eax, ebp
    imul eax, SCREEN_WIDTH
    add eax, [rect_x]
    add eax, ebx
    mov edi, VIDEO_MEMORY
    add edi, eax
    mov al, [glass_pixel_color]
    mov [edi], al
.skip_pixel:
    inc ebx
    jmp .column
.next_row:
    inc ebp
    jmp .row
.done:
    popad
    ret

draw_help_window:
    call draw_dialog_frame
    TEXT 83, 67, 80, help_title
    TEXT 72, 91, 80, help_line_one
    TEXT 72, 103, 80, help_line_two
    TEXT 72, 121, 79, close_hint
    ret

draw_auth_window:
    call draw_wallpaper
    mov dword [rect_x], 0
    mov dword [rect_y], 0
    mov dword [rect_w], 320
    mov dword [rect_h], 22
    mov byte [glass_color], 68
    call draw_glass
    TEXT 12, 8, 80, desktop_title
    RECT 43, 42, 234, 117, 32
    RECT 46, 39, 228, 120, 41
    mov dword [rect_x], 48
    mov dword [rect_y], 41
    mov dword [rect_w], 224
    mov dword [rect_h], 116
    mov byte [glass_color], 69
    call draw_glass
    mov dword [rect_x], 48
    mov dword [rect_y], 41
    mov dword [rect_w], 224
    mov dword [rect_h], 20
    mov byte [glass_color], 75
    call draw_glass
    RECT 48, 41, 224, 1, 81
    TEXT 98, 48, 80, auth_title
    mov dword [text_x], 70
    mov dword [text_y], 74
    mov byte [text_color], 80
    mov esi, [auth_message]
    call draw_text
    cmp byte [auth_state], 1
    jne .show_username
    mov dword [text_x], 72
    mov dword [text_y], 91
    mov byte [text_color], 80
    mov esi, terminal_input
    call draw_text
    jmp .input
.show_username:
    mov dword [text_x], 72
    mov dword [text_y], 91
    mov byte [text_color], 80
    mov esi, auth_username
    call draw_text
.input:
    RECT 68, 105, 184, 20, 15
    RECT 70, 107, 180, 16, 14
    mov dword [text_x], 76
    mov dword [text_y], 112
    mov byte [text_color], 80
    cmp byte [auth_state], 1
    je .draw_plain_input
    mov edi, auth_masked_buffer
    xor ecx, ecx
.mask:
    cmp cl, [terminal_length]
    jae .mask_done
    mov byte [edi], 'X'
    inc edi
    inc cl
    jmp .mask
.mask_done:
    mov byte [edi], 0
    mov esi, auth_masked_buffer
    call draw_text
    jmp .hint
.draw_plain_input:
    mov esi, terminal_input
    call draw_text
.hint:
    TEXT 88, 137, 79, auth_enter_hint
    ret

draw_info_window:
    call draw_dialog_frame
    TEXT 83, 67, 80, info_title
    TEXT 72, 91, 80, info_line_one
    mov dword [text_x], 72
    mov dword [text_y], 103
    mov byte [text_color], 80
    mov esi, [network_status]
    call draw_text
    TEXT 72, 115, 80, network_protocols_pending
    TEXT 72, 139, 79, close_hint
    ret

draw_files_window:
    call draw_dialog_frame
    TEXT 83, 67, 80, files_title
    mov dword [text_x], 72
    mov dword [text_y], 91
    mov byte [text_color], 80
    mov esi, [fs_list_result]
    call draw_text
    TEXT 72, 115, 80, files_hint
    TEXT 72, 139, 79, close_hint
    ret

draw_terminal:
    call draw_dialog_frame
    TEXT 83, 67, 80, terminal_title
    RECT 56, 76, 208, 59, 15
    RECT 58, 78, 204, 55, 14
    mov dword [text_x], 62
    mov dword [text_y], 86
    mov byte [text_color], 80
    mov esi, [terminal_result]
    call draw_text
    TEXT 62, 112, 79, terminal_prompt
    TEXT 86, 112, 80, terminal_input
    TEXT 72, 139, 79, terminal_hint
    ret

draw_dialog_frame:
    RECT 47, 53, 226, 91, 32
    RECT 49, 51, 222, 95, 41
    RECT 50, 52, 220, 93, 40
    RECT 51, 53, 218, 20, 36
    RECT 51, 53, 218, 2, 42
    RECT 52, 56, 216, 15, 37
    RECT 52, 75, 216, 66, 34
    RECT 56, 78, 208, 1, 40
    RECT 56, 137, 208, 1, 40
    RECT 257, 55, 11, 12, 86
    RECT 258, 56, 9, 10, 87
    RECT 260, 58, 2, 2, 80
    RECT 264, 58, 2, 2, 80
    RECT 262, 60, 2, 2, 80
    RECT 260, 64, 2, 2, 80
    RECT 264, 64, 2, 2, 80
    ret

draw_rect:
    pushad
    mov eax, [rect_y]
    imul eax, SCREEN_WIDTH
    add eax, [rect_x]
    mov edi, VIDEO_MEMORY
    add edi, eax
    mov ebp, [rect_h]
.row:
    mov ecx, [rect_w]
    mov al, [rect_color]
    rep stosb
    add edi, SCREEN_WIDTH
    sub edi, [rect_w]
    dec ebp
    jnz .row
    popad
    ret

draw_pixel:
    pushad
    mov eax, [pixel_y]
    imul eax, SCREEN_WIDTH
    add eax, [pixel_x]
    mov edi, VIDEO_MEMORY
    add edi, eax
    mov al, [text_color]
    mov [edi], al
    popad
    ret

draw_text:
    pushad
    mov dword [char_index], 0
.next_character:
    lodsb
    test al, al
    jz .done
    mov [char_code], al
    cmp al, ' '
    jne .find_start
    inc dword [char_index]
    jmp .next_character
.find_start:
    xor ecx, ecx
.find_glyph:
    mov al, [glyph_chars + ecx]
    test al, al
    jz .missing_glyph
    cmp al, [char_code]
    je .glyph_found
    inc ecx
    jmp .find_glyph
.glyph_found:
    imul eax, ecx, 5
    add eax, glyph_data
    mov [glyph_pointer], eax
    mov dword [glyph_row], 0
.row:
    mov eax, [glyph_pointer]
    mov ebx, [glyph_row]
    mov dl, [eax + ebx]
    mov dword [glyph_column], 0
.column:
    mov ecx, [glyph_column]
    cmp ecx, 3
    jae .next_row
    mov al, dl
    mov cl, 2
    sub cl, byte [glyph_column]
    shr al, cl
    test al, 1
    jz .skip_pixel
    mov eax, [char_index]
    shl eax, 2
    add eax, [text_x]
    add eax, [glyph_column]
    mov [pixel_x], eax
    mov eax, [text_y]
    add eax, [glyph_row]
    mov [pixel_y], eax
    call draw_pixel
.skip_pixel:
    inc dword [glyph_column]
    jmp .column
.next_row:
    inc dword [glyph_row]
    cmp dword [glyph_row], 5
    jb .row
    inc dword [char_index]
    jmp .next_character
.missing_glyph:
    inc dword [char_index]
    jmp .next_character
.done:
    popad
    ret

palette_data:
    db 0, 4, 20,   0, 5, 23,   0, 7, 26,   0, 8, 29
    db 0, 10, 32,  0, 11, 35,  0, 13, 38,  0, 14, 41
    db 0, 16, 44,  0, 17, 47,  0, 19, 50,  0, 20, 53
    db 0, 22, 56,  0, 24, 58,  0, 27, 60,  0, 30, 62
    db 0, 33, 63,  0, 36, 63,  1, 39, 63,  2, 42, 63
    db 4, 45, 63,  7, 48, 63,  10, 51, 63, 14, 54, 63
    db 18, 56, 63, 23, 58, 63, 29, 60, 63, 36, 61, 63
    db 43, 62, 63, 50, 63, 63, 57, 63, 63, 63, 63, 63
    db 8, 24, 40,  10, 29, 45,  13, 34, 50, 17, 39, 54
    db 22, 44, 58, 28, 49, 61, 34, 53, 63, 40, 57, 63
    db 46, 60, 63, 51, 62, 63, 56, 63, 63, 60, 63, 63
    db 63, 63, 63, 52, 59, 63, 42, 53, 60, 32, 46, 57
    db 63, 63, 63, 58, 62, 63, 63, 16, 20, 48, 8, 12

desktop_title db 'OWNOS DESKTOP', 0
window_title db 'OWNOS', 0
welcome_label db 'WELCOME TO OWNOS', 0
system_label db 'SYSTEM READY', 0
start_label db 'START', 0
clock_label db 'READY', 0
desktop_version db 'VERSION 02', 0
desktop_ready_label db 'READY', 0
terminal_shortcut_label db 'PRESS T TERMINAL', 0
files_shortcut_label db 'PRESS F FILES', 0
network_label db 'NETWORK STATUS', 0
disk_status_label db 'PERSISTENT DISK READY', 0
desktop_hint db 'T TERMINAL  F FILES', 0
menu_title db 'OWNOS START', 0
menu_terminal db 'TERMINAL', 0
menu_files db 'FILES', 0
menu_info db 'SYSTEM INFO', 0
menu_help db 'HELP', 0
menu_terminal_icon db 'T', 0
menu_files_icon db 'F', 0
menu_info_icon db 'S', 0
help_title db 'OWNOS KEYBOARD HELP', 0
help_line_one db 'F OPENS THE FILE BROWSER', 0
help_line_two db '1 SYSTEM INFO F1 HELP', 0
info_title db 'SYSTEM INFORMATION', 0
info_line_one db 'OWNOS 32 BIT KERNEL IS RUNNING', 0
network_found db 'QEMU E1000 NETWORK CARD FOUND', 0
network_missing db 'E1000 NETWORK CARD NOT FOUND', 0
network_driver_ready db 'E1000 DRIVER READY LINK UP', 0
network_link_down db 'E1000 DRIVER READY LINK DOWN', 0
network_init_failed db 'E1000 DRIVER INIT FAILED', 0
network_service_stopped db 'NETWORK SERVICE STOPPED', 0
network_wifi_mmio_ready db '8265 MMIO READY NO FW', 0
network_wifi_bar_unsupported db '8265 BAR UNSUPPORTED', 0
network_protocols_pending db 'NO BROWSER YET: DNS TCP HTTP', 0
network_dhcp_wait_offer db 'DHCP DISCOVER SENT - WAITING', 0
network_dhcp_wait_ack db 'DHCP REQUEST SENT - WAITING', 0
network_dhcp_bound db 'DHCP ADDRESS OBTAINED', 0
network_dhcp_failed db 'DHCP CONFIGURATION FAILED', 0
terminal_title db 'OWNOS TERMINAL', 0
terminal_prompt db 'OWNOS>', 0
terminal_hint db 'ESC CLOSES TERMINAL', 0
terminal_ready db 'TYPE HELP FOR COMMANDS', 0
terminal_help_text db 'HELP SERVICES SERVICE SECURITY SCAN LS CAT', 0
terminal_info_text db 'OWNOS 32 BIT GRAPHICS KERNEL', 0
terminal_version_text db 'OWNOS KERNEL VERSION ZERO TWO', 0
terminal_unknown db 'UNKNOWN COMMAND - TYPE HELP', 0
terminal_echo_usage db 'USAGE: ECHO THEN YOUR TEXT', 0
terminal_echo_buffer times 44 db 0
terminal_calc_usage db 'USE CALC 12+3 OR CALC 12-3', 0
terminal_blank db ' ', 0
terminal_help_command db 'HELP', 0
terminal_info_command db 'INFO', 0
terminal_version_command db 'VER', 0
terminal_clear_command db 'CLEAR', 0
terminal_desktop_command db 'DESKTOP', 0
terminal_reboot_command db 'REBOOT', 0
terminal_echo_command db 'ECHO', 0
terminal_echo_prefix db 'ECHO ', 0
terminal_calc_prefix db 'CALC ', 0
terminal_net_command db 'NET', 0
terminal_services_command db 'SERVICES', 0
terminal_service_network_start_command db 'SERVICE NETWORK START', 0
terminal_service_network_stop_command db 'SERVICE NETWORK STOP', 0
terminal_service_scan_start_command db 'SERVICE SCAN START', 0
terminal_service_scan_stop_command db 'SERVICE SCAN STOP', 0
terminal_service_filesystem_stop_command db 'SERVICE FILESYSTEM STOP', 0
terminal_service_auth_stop_command db 'SERVICE AUTHENTICATION STOP', 0
terminal_ls_command db 'LS', 0
terminal_files_command db 'FILES', 0
terminal_cat_prefix db 'CAT ', 0
terminal_write_prefix db 'WRITE ', 0
terminal_delete_prefix db 'DEL ', 0
terminal_no_files db 'NO FILES', 0
terminal_disk_unavailable db 'DISK NOT READY', 0
terminal_disk_error db 'DISK ERROR', 0
terminal_disk_full db 'DISK FULL', 0
terminal_file_saved db 'FILE SAVED', 0
terminal_file_deleted db 'FILE DELETED', 0
terminal_file_missing db 'FILE NOT FOUND', 0
terminal_write_usage db 'WRITE NAME TEXT', 0
terminal_cat_usage db 'CAT NAME', 0
terminal_delete_usage db 'DEL NAME', 0
terminal_user_command db 'USER', 0
terminal_logout_command db 'LOGOUT', 0
terminal_security_command db 'SECURITY', 0
terminal_scan_command db 'SCAN', 0
terminal_security_clean db 'METADATA CHECK OK ONLY', 0
terminal_security_warning db 'CHECK FILE METADATA', 0
terminal_security_error db 'DISK SCAN UNAVAILABLE', 0
terminal_security_disabled db 'SECURITY SCAN DISABLED', 0
terminal_security_note db 'METADATA CHECK ONLY', 0
services_all_on db 'FS ON AUTH ON NET ON SCAN ON', 0
services_network_on db 'FS ON AUTH ON NET ON SCAN OFF', 0
services_scan_on db 'FS ON AUTH ON NET OFF SCAN ON', 0
services_optional_off db 'FS ON AUTH ON NET OFF SCAN OFF', 0
service_network_enabled db 'NETWORK ON; CHECK NET', 0
service_network_stopped db 'NETWORK SERVICE STOPPED', 0
service_scan_enabled db 'SCAN SERVICE ON', 0
service_scan_stopped db 'SCAN SERVICE OFF', 0
service_already_running db 'SERVICE ALREADY ON', 0
service_already_stopped db 'SERVICE ALREADY OFF', 0
service_required db 'FILESYSTEM AND AUTH REQUIRED', 0
auth_title db 'OWNOS ACCOUNT SIGN IN', 0
auth_user_prompt db 'CREATE USER NAME MAX 8', 0
auth_new_password_prompt db 'CREATE PASSWORD MIN 6', 0
auth_confirm_prompt db 'CONFIRM PASSWORD', 0
auth_login_prompt db 'ENTER PASSWORD', 0
auth_crypto_error db 'PASSWORD CHECK NOT AVAILABLE', 0
auth_username_error db 'USER NAME TOO LONG', 0
auth_password_error db 'PASSWORD NEEDS 6 CHARS', 0
auth_mismatch_error db 'PASSWORDS DO NOT MATCH', 0
auth_login_error db 'INVALID PASSWORD', 0
auth_storage_error db 'CANNOT SAVE ACCOUNT', 0
auth_empty_error db 'INPUT REQUIRED', 0
auth_enter_hint db 'ENTER TO CONTINUE', 0
auth_welcome db 'WELCOME TO OWNOS', 0
files_title db 'FILE BROWSER', 0
files_hint db 'USE TERMINAL LS CAT WRITE DEL', 0
close_hint db 'PRESS ESC TO RETURN', 0

glyph_chars db 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-', 0
glyph_data:
    db 2, 5, 7, 5, 5
    db 6, 5, 6, 5, 6
    db 3, 4, 4, 4, 3
    db 6, 5, 5, 5, 6
    db 7, 4, 6, 4, 7
    db 7, 4, 6, 4, 4
    db 3, 4, 5, 5, 3
    db 5, 5, 7, 5, 5
    db 7, 2, 2, 2, 7
    db 1, 1, 1, 5, 2
    db 5, 5, 6, 5, 5
    db 4, 4, 4, 4, 7
    db 5, 7, 7, 5, 5
    db 5, 7, 7, 7, 5
    db 2, 5, 5, 5, 2
    db 6, 5, 6, 4, 4
    db 2, 5, 5, 3, 1
    db 6, 5, 6, 5, 5
    db 3, 4, 2, 1, 6
    db 7, 2, 2, 2, 2
    db 5, 5, 5, 5, 7
    db 5, 5, 5, 5, 2
    db 5, 5, 7, 7, 5
    db 5, 5, 2, 5, 5
    db 5, 5, 2, 2, 2
    db 7, 1, 2, 4, 7
    db 7, 5, 5, 5, 7
    db 2, 6, 2, 2, 7
    db 7, 1, 7, 4, 7
    db 7, 1, 7, 1, 7
    db 5, 5, 7, 1, 1
    db 7, 4, 7, 1, 7
    db 3, 4, 7, 5, 7
    db 7, 1, 2, 2, 2
    db 7, 5, 7, 5, 7
    db 7, 5, 7, 1, 6
    db 0, 2, 7, 2, 0
    db 0, 0, 7, 0, 0

rect_x dd 0
rect_y dd 0
rect_w dd 0
rect_h dd 0
rect_color db 0
glass_color db 0
glass_pixel_color db 0
gradient_color db 0
text_x dd 0
text_y dd 0
text_color db 0
pixel_x dd 0
pixel_y dd 0
char_index dd 0
char_code db 0
glyph_pointer dd 0
glyph_row dd 0
glyph_column dd 0
terminal_open db 0
active_window db 0
terminal_length db 0
terminal_input times 44 db 0
terminal_result dd terminal_ready
user_logged_in db 0
auth_state db 0
auth_password_length db 0
auth_operation_error db 0
auth_username times 16 db 0
auth_password times 44 db 0
auth_salt times 16 db 0
auth_saved_hash times 32 db 0
auth_masked_buffer times 44 db 0
auth_message dd auth_user_prompt
align 16
auth_sector times 512 db 0
sha_test_input db 'abc'
sha_test_digest db 0xBA, 0x78, 0x16, 0xBF, 0x8F, 0x01, 0xCF, 0xEA
    db 0x41, 0x41, 0x40, 0xDE, 0x5D, 0xAE, 0x22, 0x23
    db 0xB0, 0x03, 0x61, 0xA3, 0x96, 0x17, 0x7A, 0x9C
    db 0xB4, 0x10, 0xFF, 0x61, 0xF2, 0x00, 0x15, 0xAD
sha_ready db 0
sha_input times 64 db 0
sha_input_length dd 0
sha_padded times 128 db 0
sha_digest times 32 db 0
sha_state times 32 db 0
sha_schedule times 256 db 0
sha_constants:
    dd 0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5
    dd 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5
    dd 0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3
    dd 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174
    dd 0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC
    dd 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA
    dd 0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7
    dd 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967
    dd 0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13
    dd 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85
    dd 0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3
    dd 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070
    dd 0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5
    dd 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3
    dd 0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208
    dd 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2
sha_rounds dd 0
sha_block_count dd 0
sha_length_offset dd 0
sha_block_offset dd 0
sha_round_index dd 0
sha_temp0 dd 0
sha_a dd 0
sha_b dd 0
sha_c dd 0
sha_d dd 0
sha_e dd 0
sha_f dd 0
sha_g dd 0
sha_h dd 0
sha_t1 dd 0
sha_t2 dd 0
security_file_count dd 0
ata_lba dd 0
ata_buffer dd 0
ata_result db 0
fs_ready db 0
fs_parse_ok db 0
fs_text_length db 0
fs_found_index dd -1
fs_list_result dd terminal_disk_unavailable
fs_list_length dd 0
fs_argument_cursor dd 0
fs_filename times 12 db 0
fs_list_buffer times 44 db 0
fs_text_buffer times 44 db 0
fs_content_buffer times 44 db 0
align 16
fs_directory_buffer times 512 db 0
align 16
fs_sector_buffer times 512 db 0
network_status dd network_missing
network_pci_device dd 0
nic_mmio dd 0
wifi_mmio_base dd 0
nic_ready db 0
network_service_enabled db 1
security_scan_service_enabled db 1
network_adapter_kind db 0
network_link_up db 0
dhcp_state db 0
dhcp_started db 0
dhcp_message_type db 0
dhcp_server_seen db 0
dhcp_options_left dd 0
dhcp_send_result dd 0
dhcp_offered_ip dd 0
dhcp_server_ip dd 0
nic_mac times 6 db 0
rx_head db 0
tx_head dd 0
tx_current dd 0
tx_length dd 0
tx_buffer_pointer dd 0
network_rx_packets dd 0
command_cursor dd 0
next_command_cursor dd 0
calc_left dd 0
calc_right dd 0
calc_operator db 0
calc_negative db 0
calc_result_buffer times 12 db 0
mouse_packet times 3 db 0
mouse_packet_index db 0
mouse_x dd 160
mouse_y dd 100
cursor_mask db 0
cursor_visible db 0
cursor_save_index dd 0
mouse_background times 80 db 0

align 16
rx_ring times 8 * 16 db 0
align 16
tx_ring times 8 * 16 db 0
align 16
rx_buffers times 8 * 2048 db 0
align 16
tx_buffers times 8 * 2048 db 0
align 16
dhcp_packet times 304 db 0

mouse_outline:
    db 0x80, 0xC0, 0xE0, 0xF0, 0xF8, 0xFC, 0xFE, 0xF0, 0xD8, 0x0C
mouse_inner:
    db 0x00, 0x40, 0x60, 0x70, 0x78, 0x7C, 0x78, 0x50

keymap:
    db 0, 0, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '+', 0, 0
    db 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '[', ']', 0, 0, 'A', 'S'
    db 'D', 'F', 'G', 'H', 'J', 'K', 'L', ';', 0, 0, 0, 0, 'Z', 'X', 'C', 'V'
    db 'B', 'N', 'M', ',', '.', '/', 0, 0, 0, ' '
    times 70 db 0

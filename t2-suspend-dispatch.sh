#!/usr/bin/env bash
set -eo pipefail

SUSPEND_UNIT_NAME="t2-suspend.service"
GUARD_UNIT_NAME="t2-wakeup-guard.service"
SUSPEND_UNIT_PATH="/etc/systemd/system/${SUSPEND_UNIT_NAME}"
GUARD_UNIT_PATH="/etc/systemd/system/${GUARD_UNIT_NAME}"

KARGS=("mem_sleep_default=deep" "pcie_ports=native" "pcie_aspm=off")

OS_ID=""
OS_LIKE=""
CURRENT_CMDLINE=""
MODEL_IDENTIFIER=""
LSPCI_OUTPUT=""
HAS_KARG_MEM_SLEEP_DEEP=0
HAS_KARG_PCIE_PORTS_NATIVE=0
HAS_KARG_PCIE_ASPM_OFF=0
HAS_DGPU=0
HAS_APPLE_GMUX_FORCE_IGD=0
HAS_TOUCHBAR=0
HAS_TINY_DFR=0
HAS_BCM4377=0
HAS_BRCM_WIFI_UNLOAD=1
KBD_BACKLIGHT_PATH=""
KBD_BACKLIGHT_KIND=""
ENABLE_AUDIO_WORKAROUND=0

log()  { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Execute with sudo"
}

confirm_with_user() {
    echo
    echo "This script will modify kernel parameters and install two systemd units:"
    echo "1: t2-suspend.service"
    echo "2: t2-wakeup-guard.service"
    echo "Make a backup of your kernel command line before proceeding!"
    echo 
    read -p "Continue with installation? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Installation cancelled."
        exit 0
    fi
}

disable_all_s3_wakeup() {
    while read -r dev sstate status _; do
        [ "$dev" = "Device" ] && continue
        [ "$sstate" != "S3" ] && continue
        if [ "$status" = "*enabled" ]; then
            printf '%s\n' "$dev" > /proc/acpi/wakeup
        fi
    done < /proc/acpi/wakeup
}

cleanup_prior_systemd_fixes() {
    log "Cleaning up prior systemd fixes if present"
    systemctl disable suspend-fix-t2.service 2>/dev/null || true
    systemctl disable suspend-wifi-unload.service 2>/dev/null || true
    systemctl disable resume-wifi-reload.service 2>/dev/null || true
    systemctl disable fix-kbd-backlight.service 2>/dev/null || true

    rm -f /etc/systemd/system/suspend-wifi-unload.service
    rm -f /etc/systemd/system/resume-wifi-reload.service
    rm -f /etc/systemd/system/fix-kbd-backlight.service
    rm -f /etc/systemd/system/suspend-fix-t2.service
    rm -f /usr/lib/systemd/system-sleep/t2-resync
    rm -f /usr/lib/systemd/system-sleep/90-t2-hibernate-test-brcmfmac.sh
}

choose_audio_workaround() {
    echo
    echo "Optional audio workaround:"
    echo "This stops parts of the PipeWire/PulseAudio user session before apple-bce is removed."
    echo "It may prevent resume panics on some systems, but it can also cause audio or"
    echo "session reconnect issues after resume on others."
    echo
    read -p "Enable optional audio workaround? (y/n) " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        ENABLE_AUDIO_WORKAROUND=1
    else
        ENABLE_AUDIO_WORKAROUND=0
    fi
}
load_os_release() {
    [[ -r /etc/os-release ]] || die "/etc/os-release is missing"
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
}

read_first_line() {
    local file="$1"
    [[ -r "$file" ]] || return 1
    IFS= read -r REPLY < "$file" || true
    printf '%s\n' "$REPLY"
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

bool_label() {
    [[ "$1" -eq 1 ]] && printf 'yes' || printf 'no'
}

module_loaded() {
    local module="$1"
    grep -Eq "^${module//-/_} " /proc/modules
}

cmdline_has_arg() {
    local arg="$1"
    [[ " ${CURRENT_CMDLINE} " == *" ${arg} "* ]]
}

detect_current_cmdline() {
    CURRENT_CMDLINE="$(read_first_line /proc/cmdline)"
}

detect_cmdline_flags() {
    HAS_KARG_MEM_SLEEP_DEEP=0
    HAS_KARG_PCIE_PORTS_NATIVE=0
    HAS_KARG_PCIE_ASPM_OFF=0

    if cmdline_has_arg "mem_sleep_default=deep"; then
        HAS_KARG_MEM_SLEEP_DEEP=1
    fi

    if cmdline_has_arg "pcie_ports=native"; then
        HAS_KARG_PCIE_PORTS_NATIVE=1
    fi

    if cmdline_has_arg "pcie_aspm=off"; then
        HAS_KARG_PCIE_ASPM_OFF=1
    fi
}

detect_model_identifier() {
    MODEL_IDENTIFIER="$(read_first_line /sys/class/dmi/id/product_name)"
    [[ -n "$MODEL_IDENTIFIER" ]] || die "Model identifier not detected. Unable to continue without /sys/class/dmi/id/product_name."
}

detect_pci_inventory() {
    log "Detecting PCI inventory via lspci"
    have_cmd lspci || die "lspci is required but missing"
    LSPCI_OUTPUT="$(lspci -nn)" || die "lspci failed"
}

detect_dgpu() {
    HAS_DGPU=0
    if printf '%s\n' "$LSPCI_OUTPUT" | grep -Eq '\[1002:'; then
        HAS_DGPU=1
    fi
}

detect_igd_mode() {
    local force_igd_value

    HAS_APPLE_GMUX_FORCE_IGD=0

    if [[ $HAS_DGPU -ne 1 ]]; then
        return
    fi

    if [[ -r /sys/module/apple_gmux/parameters/force_igd ]]; then
        force_igd_value="$(read_first_line /sys/module/apple_gmux/parameters/force_igd)"
        case "$force_igd_value" in
            Y|y|1)
                HAS_APPLE_GMUX_FORCE_IGD=1
                ;;
        esac
    fi
}

detect_touchbar() {
    HAS_TOUCHBAR=0

    if module_loaded hid_appletb_kbd; then
        HAS_TOUCHBAR=1
    fi
}

detect_tiny_dfr() {
    HAS_TINY_DFR=0

    if systemctl cat tiny-dfr.service >/dev/null 2>&1; then
        HAS_TINY_DFR=1
        return
    fi

    if pgrep -x tiny-dfr >/dev/null 2>&1; then
        HAS_TINY_DFR=1
    fi
}

detect_broadcom_variant() {
    HAS_BCM4377=0

    if module_loaded hci_bcm4377; then
        HAS_BCM4377=1
    elif printf '%s\n' "$LSPCI_OUTPUT" | grep -Eiq 'Broadcom.*(BCM4377|BRCM4377)'; then
        HAS_BCM4377=1
    fi
}

detect_brcm_wifi_policy() {
    HAS_BRCM_WIFI_UNLOAD="$HAS_BCM4377"

    case "$MODEL_IDENTIFIER" in
        # Keep model-based overrides here for future exceptions.
        *)
            ;;
    esac
}

detect_keyboard_backlight() {
    KBD_BACKLIGHT_PATH=""
    KBD_BACKLIGHT_KIND=""

    if [[ -e /sys/class/leds/:white:kbd_backlight/brightness ]]; then
        KBD_BACKLIGHT_PATH="/sys/class/leds/:white:kbd_backlight/brightness"
        KBD_BACKLIGHT_KIND="Magic Keyboard"
        return
    fi

    if [[ -e /sys/class/leds/apple::kbd_backlight/brightness ]]; then
        KBD_BACKLIGHT_PATH="/sys/class/leds/apple::kbd_backlight/brightness"
        KBD_BACKLIGHT_KIND="Butterfly Keyboard"
        return
    fi

    case "$MODEL_IDENTIFIER" in
        iMac*)
            KBD_BACKLIGHT_KIND="none"
            return
            ;;
        MacBook*)
            die "Keyboard backlight path not detected. Ensure the keyboard backlight is active so it can be identified."
            ;;
        *)
            die "Unsupported Apple T2 model without keyboard backlight path: ${MODEL_IDENTIFIER}"
            ;;
    esac
}

log_detection_summary() {
    log "Detected model: ${MODEL_IDENTIFIER}"
    log "Detected cmdline: ${CURRENT_CMDLINE}"
    log "Kernel arg mem_sleep_default=deep present: $(bool_label "$HAS_KARG_MEM_SLEEP_DEEP")"
    log "Kernel arg pcie_ports=native present: $(bool_label "$HAS_KARG_PCIE_PORTS_NATIVE")"
    log "Kernel arg pcie_aspm=off present: $(bool_label "$HAS_KARG_PCIE_ASPM_OFF")"
    log "Detected dGPU: $(bool_label "$HAS_DGPU")"
    log "Detected apple-gmux force_igd: $(bool_label "$HAS_APPLE_GMUX_FORCE_IGD")"
    log "Detected Touch Bar: $(bool_label "$HAS_TOUCHBAR")"
    log "Detected tiny-dfr service: $(bool_label "$HAS_TINY_DFR")"
    log "Detected BCM4377 path: $(bool_label "$HAS_BCM4377")"
    log "Allow Broadcom Wi-Fi unload sequence: $(bool_label "$HAS_BRCM_WIFI_UNLOAD")"
    log "Detected keyboard type: ${KBD_BACKLIGHT_KIND}"
    log "Optional audio workaround enabled: $(bool_label "$ENABLE_AUDIO_WORKAROUND")"
}

detect_hardware() {
    detect_current_cmdline
    detect_cmdline_flags
    detect_model_identifier
    detect_pci_inventory
    detect_dgpu
    detect_igd_mode
    detect_touchbar
    detect_tiny_dfr
    detect_broadcom_variant
    detect_brcm_wifi_policy
    detect_keyboard_backlight
}

append_args_once_to_string() {
    local current="$1"
    shift
    local out=" $current "
    local arg
    for arg in "$@"; do
        if [[ "$out" != *" $arg "* ]]; then
            out+="$arg "
        fi
    done
    out="${out# }"
    out="${out% }"
    printf '%s\n' "$out"
}

feature_is_enabled() {
    local feature="$1"

    case "$feature" in
        always)
            return 0
            ;;
        kbd_magic)
            [[ "$KBD_BACKLIGHT_KIND" == "Magic Keyboard" ]]
            ;;
        kbd_butterfly)
            [[ "$KBD_BACKLIGHT_KIND" == "Butterfly Keyboard" ]]
            ;;
        bcm_wifi)
            [[ $HAS_BRCM_WIFI_UNLOAD -eq 1 ]]
            ;;
        bcm4377)
            [[ $HAS_BCM4377 -eq 1 ]]
            ;;
        touchbar)
            [[ $HAS_TOUCHBAR -eq 1 ]]
            ;;
        tiny_dfr)
            [[ $HAS_TINY_DFR -eq 1 ]]
            ;;
        audio_user_session)
            [[ $ENABLE_AUDIO_WORKAROUND -eq 1 ]]
            ;;
        gmux_igd)
            [[ $HAS_APPLE_GMUX_FORCE_IGD -eq 1 ]]
            ;;
        touchbar_or_tiny_dfr)
            [[ $HAS_TOUCHBAR -eq 1 || $HAS_TINY_DFR -eq 1 ]]
            ;;
        bcm4377_or_tiny_dfr)
            [[ $HAS_BCM4377 -eq 1 || $HAS_TINY_DFR -eq 1 ]]
            ;;
        *)
            die "Unknown suspend unit feature block: ${feature}"
            ;;
    esac
}

write_suspend_unit() {
    local current_feature="always"
    local line

    log "Writing ${SUSPEND_UNIT_PATH}"
    : > "${SUSPEND_UNIT_PATH}"

    while IFS= read -r line; do
        case "$line" in
            '# @feature '*)
                current_feature="${line#\# @feature }"
                continue
                ;;
            '# @endfeature')
                current_feature="always"
                continue
                ;;
        esac

        if [[ -z "$line" ]]; then
            printf '\n' >> "${SUSPEND_UNIT_PATH}"
            continue
        fi

        if feature_is_enabled "$current_feature"; then
            printf '%s\n' "$line" >> "${SUSPEND_UNIT_PATH}"
        else
            printf '# %s\n' "$line" >> "${SUSPEND_UNIT_PATH}"
        fi
    done <<'EOF'
[Unit]
Description=Unload and Reload Modules for Suspend and Resume
Before=sleep.target
StopWhenUnneeded=yes

[Service]
User=root
Type=oneshot
RemainAfterExit=yes

# @feature audio_user_session
ExecStart=-/usr/bin/bash -lc 'uid=$(loginctl list-sessions --no-legend 2>/dev/null | awk "{print \$2}" | head -n1); [ -n "$uid" ] || exit 0; [ -S "/run/user/$uid/bus" ] || exit 0; username=$(id -nu "$uid" 2>/dev/null) || exit 0; XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" runuser -u "$username" -- systemctl --user stop pipewire.socket pipewire-pulse.socket pipewire.service pipewire-pulse.service wireplumber.service 2>/dev/null || true'
# @endfeature
# @feature gmux_igd
ExecStart=-/usr/bin/rmmod -f apple_gmux
ExecStart=-/usr/bin/sh -c 'echo 1 > /sys/bus/pci/devices/0000:01:00.0/remove'
# @endfeature
# @feature kbd_butterfly
ExecStart=-/usr/bin/sh -c "/usr/bin/echo 0 | /usr/bin/tee /sys/class/leds/apple::kbd_backlight/brightness"
# @endfeature
# @feature kbd_magic
ExecStart=-/bin/bash -c "/bin/echo 0 | tee /sys/class/leds/:white:kbd_backlight/brightness"
# @endfeature
# @feature bcm4377
ExecStart=-/usr/bin/rmmod hci_bcm4377
# @endfeature
# @feature bcm_wifi
ExecStart=-/usr/bin/rmmod brcmfmac_wcc
ExecStart=-/usr/bin/rmmod brcmfmac
ExecStart=-/usr/bin/rmmod brcmutil
# @endfeature
# @feature tiny_dfr
ExecStart=-/usr/bin/systemctl stop tiny-dfr.service
ExecStart=-/usr/bin/pkill -9 tiny-dfr
# @endfeature
# @feature touchbar
ExecStart=-/usr/bin/rmmod appletbdrm
ExecStart=-/usr/bin/rmmod hid_appletb_kbd
ExecStart=-/usr/bin/rmmod hid_appletb_bl
# @endfeature
ExecStart=-/usr/bin/rmmod -f apple-bce

ExecStop=/usr/bin/modprobe apple-bce
# @feature gmux_igd
ExecStop=/usr/bin/sleep 4
ExecStop=-/usr/bin/sh -c 'echo 1 > /sys/bus/pci/rescan'
ExecStop=-/usr/bin/modprobe apple_gmux
# @endfeature
# @feature bcm_wifi
ExecStop=-/usr/bin/modprobe brcmutil
ExecStop=-/usr/bin/modprobe brcmfmac
ExecStop=-/usr/bin/modprobe brcmfmac_wcc
# @endfeature
# @feature bcm4377
ExecStop=-/usr/bin/modprobe hci_bcm4377
# @endfeature
# @feature touchbar
ExecStop=-/usr/bin/modprobe hid_appletb_bl
ExecStop=-/usr/bin/modprobe hid_appletb_kbd
ExecStop=-/usr/bin/modprobe appletbdrm
# @endfeature
# @feature bcm4377_or_tiny_dfr
ExecStop=/usr/bin/sleep 2
# @endfeature
# @feature tiny_dfr
ExecStopPost=-/usr/bin/systemctl reset-failed tiny-dfr.service
ExecStopPost=-/usr/bin/systemctl restart tiny-dfr.service
# @endfeature
# @feature kbd_butterfly
ExecStopPost=-/usr/bin/sh -c "/usr/bin/echo 255 | /usr/bin/tee /sys/class/leds/apple::kbd_backlight/brightness"
# @endfeature
# @feature kbd_magic
ExecStopPost=-/bin/bash -c "/bin/echo 255 | tee /sys/class/leds/:white:kbd_backlight/brightness"
# @endfeature
# @feature audio_user_session
ExecStopPost=-/usr/bin/bash -lc 'uid=$(loginctl list-sessions --no-legend 2>/dev/null | awk "{print \$2}" | head -n1); [ -n "$uid" ] || exit 0; [ -S "/run/user/$uid/bus" ] || exit 0; username=$(id -nu "$uid" 2>/dev/null) || exit 0; XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" runuser -u "$username" -- systemctl --user start pipewire.socket pipewire-pulse.socket wireplumber.service 2>/dev/null || true'
# @endfeature
# @feature touchbar
ExecStopPost=-/usr/bin/systemctl restart upower
# @endfeature

[Install]
WantedBy=sleep.target
EOF
}

write_guard_unit() {
    log "Writing ${GUARD_UNIT_PATH}"
    cat > "${GUARD_UNIT_PATH}" <<'EOF'
[Unit]
Description=Disable problematic ACPI wake sources

[Service]
Type=oneshot
ExecStart=-/usr/bin/bash -lc 'grep -q "^ARPT[[:space:]].*\\*enabled" /proc/acpi/wakeup && echo ARPT > /proc/acpi/wakeup || true'
ExecStart=-/usr/bin/bash -lc 'grep -q "^RP01[[:space:]].*\\*enabled" /proc/acpi/wakeup && echo RP01 > /proc/acpi/wakeup || true'
ExecStart=-/usr/bin/bash -lc 'grep -q "^TRP0[[:space:]].*\\*enabled" /proc/acpi/wakeup && echo TRP0 > /proc/acpi/wakeup || true'
ExecStart=-/usr/bin/bash -lc 'grep -q "^TRP1[[:space:]].*\\*enabled" /proc/acpi/wakeup && echo TRP1 > /proc/acpi/wakeup || true'

[Install]
WantedBy=multi-user.target
WantedBy=sleep.target
EOF
}

enable_units() {
    log "Reload systemd and activate"
    systemctl daemon-reload
    systemctl enable "${SUSPEND_UNIT_NAME}"
    systemctl enable "${GUARD_UNIT_NAME}"
}

set_kargs_fedora() {
    have_cmd grubby || die "Found Fedora/RHEL, but grubby is missing"
    log "Set Kernel-Args with grubby"
    grubby --update-kernel=ALL --args="${KARGS[*]}"
}

update_grub_var_file() {
    local file="$1"
    local var="$2"

    if ! grep -qE "^${var}=" "$file"; then
        printf '%s="%s"\n' "$var" "${KARGS[*]}" >> "$file"
        return
    fi

    local old_value new_value escaped
    old_value="$(sed -n "s/^${var}=\"\(.*\)\"/\1/p" "$file" | head -n1)"
    new_value="$(append_args_once_to_string "$old_value" "${KARGS[@]}")"
    escaped="$(printf '%s' "$new_value" | sed 's/[\/&]/\\&/g')"
    sed -i "s/^${var}=\".*\"$/${var}=\"${escaped}\"/" "$file"
}

set_kargs_grub_classic() {
    local grub_file="/etc/default/grub"
    [[ -f "$grub_file" ]] || die "${grub_file} missing"

    log "Set kernel-Args in ${grub_file}"
    update_grub_var_file "$grub_file" "GRUB_CMDLINE_LINUX"

    local cfg

    for cfg in \
        /boot/grub2/grub.cfg \
        /boot/grub/grub.cfg \
        /boot/efi/EFI/*/grub.cfg
    do
        [[ -f "$cfg" ]] && break
    done

    [[ -f "$cfg" ]] || die "GRUB config not found"

    if have_cmd update-grub; then
        log "Executing update-grub"
        update-grub
    elif have_cmd grub2-mkconfig; then
        log "Executing grub2-mkconfig"
        grub2-mkconfig -o "$cfg"
    elif have_cmd grub-mkconfig; then
        log "Executing grub-mkconfig"
        grub-mkconfig -o "$cfg"
    else
        die "No GRUB config generator found"
    fi
}

patch_systemd_boot_entry_file() {
    local file="$1"

    if grep -q '^options ' "$file"; then
        local current new escaped
        current="$(sed -n 's/^options[[:space:]]\+//p' "$file" | head -n1)"
        new="$(append_args_once_to_string "$current" "${KARGS[@]}")"
        escaped="$(printf '%s' "$new" | sed 's/[\/&]/\\&/g')"
        sed -i "s/^options[[:space:]].*$/options ${escaped}/" "$file"
    else
        printf '\noptions %s\n' "${KARGS[*]}" >> "$file"
    fi
}

set_kargs_systemd_boot() {
    local touched=0

    if [[ -f /etc/kernel/cmdline ]]; then
        log "Setting kernel-args in /etc/kernel/cmdline"
        local current new
        current="$(cat /etc/kernel/cmdline)"
        new="$(append_args_once_to_string "$current" "${KARGS[@]}")"
        printf '%s\n' "$new" > /etc/kernel/cmdline
        touched=1
    fi

    local entry
    for entry in /boot/loader/entries/*.conf /efi/loader/entries/*.conf /boot/efi/loader/entries/*.conf; do
        [[ -e "$entry" ]] || continue
        log "Patching systemd-boot-entry ${entry}"
        patch_systemd_boot_entry_file "$entry"
        touched=1
    done

    [[ $touched -eq 1 ]] || die "No systemd-boot cmdline-target found"
}

dispatch_kargs() {
    case "${OS_ID}" in
        fedora|rhel|centos|rocky|almalinux)
            set_kargs_fedora
            ;;
        ubuntu|debian|linuxmint|pop|neon|elementary)
            set_kargs_grub_classic
            ;;
        arch|endeavouros|manjaro)
            if [[ -d /boot/loader/entries || -d /efi/loader/entries || -f /etc/kernel/cmdline ]]; then
                set_kargs_systemd_boot
            elif [[ -f /etc/default/grub ]]; then
                set_kargs_grub_classic
            else
                die "Arch-family recognized, but neither systemd-boot nor GRUB-config were found"
            fi
            ;;
        *)
            if [[ "$OS_LIKE" == *fedora* ]] && have_cmd grubby; then
                set_kargs_fedora
            elif [[ -d /boot/loader/entries || -d /efi/loader/entries || -f /etc/kernel/cmdline ]]; then
                set_kargs_systemd_boot
            elif [[ -f /etc/default/grub ]]; then
                set_kargs_grub_classic
            else
                die "Unknown distro/bootloader-combination"
            fi
            ;;
    esac
}

main() {
    require_root
    log "Loading distro information"
    load_os_release
    log "Detecting hardware"
    detect_hardware
    log_detection_summary
    choose_audio_workaround
    log "Optional audio workaround enabled: $(bool_label "$ENABLE_AUDIO_WORKAROUND")"
    confirm_with_user
    cleanup_prior_systemd_fixes
    log "Disabling all enabled S3 wake sources"
    disable_all_s3_wakeup
    write_suspend_unit
    write_guard_unit
    enable_units
    dispatch_kargs

    log "Done."
    log "Suspend-unit: ${SUSPEND_UNIT_NAME}"
    log "Wakeup-guard-unit: ${GUARD_UNIT_NAME}"
    log "Kernel-args ensured: ${KARGS[*]}"
    log "Reboot neccessary!"
}

main "$@"

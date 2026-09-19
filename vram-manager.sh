#!/usr/bin/env bash
# Linux VRAM Manager
# Installs/configures DMEM VRAM management, selects a desktop-specific
# foreground integration when available, applies a persistent app.slice
# VRAM headroom limit, verifies it, and removes the custom setup.

set -u

VERSION=1.1.1
SERVICE=/etc/systemd/system/dmemcg-appslice-limit.service
HELPER=/usr/local/sbin/set-dmem-appslice-limit
CONFIG=/etc/default/dmemcg-appslice-limit
STATE=/var/lib/linux-vram-manager/installed-packages
UID_NOW=$(id -u)
REBOOT_NEEDED=0

say() { printf '\n%s\n' "$*"; }
ok() { printf '  [OK] %s\n' "$*"; }
warn() { printf '  [!] %s\n' "$*"; }
err() { printf '  [ERROR] %s\n' "$*" >&2; }
pause_menu() { printf '\nPress Enter to continue... '; read -r _ || true; }

is_bazzite() { grep -Eqi '^ID=bazzite$' /etc/os-release 2>/dev/null; }
is_nobara() { grep -Eqi '^ID=nobara$' /etc/os-release 2>/dev/null; }
is_fedora() { grep -Eqi '^ID=fedora$' /etc/os-release 2>/dev/null; }
is_arch() { grep -Eqi '^ID=(arch|cachyos|endeavouros|garuda|manjaro|arcolinux)$' /etc/os-release 2>/dev/null; }
is_systemd() { command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; }

desktop_name() {
    local d
    d="${XDG_CURRENT_DESKTOP:-} ${XDG_SESSION_DESKTOP:-} ${DESKTOP_SESSION:-}"
    d=$(printf '%s\n' "$d" | tr '[:upper:]' '[:lower:]')
    case "$d" in
        *kde*|*plasma*) echo 'KDE Plasma' ;;
        *gnome*) echo 'GNOME' ;;
        *hyprland*) echo 'Hyprland' ;;
        *niri*) echo 'Niri' ;;
        *sway*) echo 'Sway' ;;
        *labwc*|*openbox*) echo 'Labwc/Openbox' ;;
        *wayfire*) echo 'Wayfire' ;;
        *cosmic*) echo 'COSMIC' ;;
        *xfce*) echo 'Xfce' ;;
        *cinnamon*) echo 'Cinnamon' ;;
        *mate*) echo 'MATE' ;;
        *lxqt*) echo 'LXQt' ;;
        *lxde*) echo 'LXDE' ;;
        *budgie*) echo 'Budgie' ;;
        *deepin*) echo 'Deepin' ;;
        *enlightenment*) echo 'Enlightenment' ;;
        *i3*) echo 'i3' ;;
        *dwm*) echo 'dwm' ;;
        *bspwm*) echo 'bspwm' ;;
        *awesome*) echo 'awesome' ;;
        *icewm*) echo 'IceWM' ;;
        *fluxbox*) echo 'Fluxbox' ;;
        *umbriel*) echo 'Umbriel' ;;
        *) echo 'Unknown / custom' ;;
    esac
}

app_path() {
    local rel
    is_systemd || return 1
    rel=$(systemctl show "user@${UID_NOW}.service" -p ControlGroup --value 2>/dev/null) || return 1
    [ -n "$rel" ] || return 1
    printf '/sys/fs/cgroup%s/app.slice\n' "$rel"
}

dmem_ready() {
    [ -r /sys/fs/cgroup/dmem.capacity ] || return 1
    awk '$1 ~ /\/(vram|vram[0-9]+|vidmem|vidmem[0-9]+)$/ {ok=1} END{exit(ok?0:1)}' /sys/fs/cgroup/dmem.capacity
}

package_installed() {
    if command -v pacman >/dev/null 2>&1; then
        pacman -Qq 2>/dev/null | grep -Fxq -- "$1"
    elif command -v rpm >/dev/null 2>&1; then
        rpm -q "$1" >/dev/null 2>&1
    else
        return 1
    fi
}

record_package() {
    local manager="$1" pkg="$2"
    sudo mkdir -p "$(dirname "$STATE")"
    if ! sudo grep -Fqx "$manager|$pkg" "$STATE" 2>/dev/null; then
        printf '%s|%s\n' "$manager" "$pkg" | sudo tee -a "$STATE" >/dev/null
    fi
}

install_pacman_pkg() {
    local pkg="$1"
    package_installed "$pkg" && return 0
    if sudo pacman -S --needed "$pkg" || { command -v yay >/dev/null 2>&1 && yay -S --needed "$pkg"; } || { command -v paru >/dev/null 2>&1 && paru -S --needed "$pkg"; }; then
        if package_installed "$pkg"; then
            record_package pacman "$pkg"
            return 0
        fi
    fi
    return 1
}

install_aur_pkg() {
    local pkg="$1"
    package_installed "$pkg" && return 0
    if command -v yay >/dev/null 2>&1; then
        yay -S --needed "$pkg" || return 1
    elif command -v paru >/dev/null 2>&1; then
        paru -S --needed "$pkg" || return 1
    else
        return 1
    fi
    package_installed "$pkg" && record_package pacman "$pkg"
}

install_dnf_pkg() {
    local pkg="$1"
    package_installed "$pkg" && return 0
    sudo dnf install -y "$pkg" || return 1
    package_installed "$pkg" && record_package rpm "$pkg"
}

ensure_terra() {
    if command -v dnf >/dev/null 2>&1 && dnf repolist 2>/dev/null | grep -Eq '^terra([[:space:]]|$)'; then
        return 0
    fi
    printf 'The required VRAM package is provided through Terra on Fedora. Add Terra now? [y/N]: '
    read -r answer || answer=''
    [[ "$answer" =~ ^[Yy]$ ]] || return 1
    sudo dnf install --nogpgcheck --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' terra-release || return 1
    return 0
}

print_desktop_support() {
    local d
    d=$(desktop_name)
    say 'Desktop integration'
    case "$d" in
        'KDE Plasma')
            printf '  Detected: %s\n' "$d"
            if package_installed plasma-foreground-booster; then
                printf '  Foreground booster: plasma-foreground-booster (provides plasma-foreground-booster-dmemcg)\n'
            elif package_installed plasma-foreground-booster-dmemcg; then
                printf '  Foreground booster: plasma-foreground-booster-dmemcg (AUR/Fedora package name)\n'
            else
                printf '  Foreground booster: not installed\n'
            fi
            ;;
        GNOME)
            printf '  Detected: GNOME\n'
            printf '  Preferred integration: gnome-vram-booster (Arch/AUR) or uresourced-dmemcg (Fedora/Bazzite)\n'
            printf '  Fallback: Gamescope + dmemcg-booster\n'
            ;;
        Hyprland)
            printf '  Detected: Hyprland\n'
            printf '  Foreground booster: hyprland-focused-booster (AUR)\n'
            printf '  Fallback: Gamescope + dmemcg-booster\n'
            ;;
        Niri)
            printf '  Detected: Niri\n'
            printf '  Foreground booster: niri-focused-booster (distro package or AUR)\n'
            printf '  Fallback: Gamescope + dmemcg-booster\n'
            ;;
        *)
            printf '  Detected: %s\n' "$d"
            printf '  Foreground integration: no verified desktop-specific booster detected\n'
            printf '  Generic path: Gamescope + dmemcg-booster (games must be launched through Gamescope)\n'
            ;;
    esac
}

package_status() {
    say 'VRAM-management packages'
    if command -v pacman >/dev/null 2>&1; then
        local p found=0
        for p in dmemcg-booster plasma-foreground-booster plasma-foreground-booster-dmemcg gnome-vram-booster hyprland-focused-booster niri-focused-booster kcgroups; do
            if package_installed "$p"; then
                printf '  [installed] %s %s\n' "$p" "$(pacman -Q "$p" | awk '{print $2}')"
                found=1
            fi
        done
        ((found)) || echo '  No matching packages found.'
    elif command -v rpm >/dev/null 2>&1; then
        local p found=0
        for p in dmemcg-booster plasma-foreground-booster-dmemcg uresourced-dmemcg; do
            if rpm -q "$p" >/dev/null 2>&1; then
                printf '  [installed] %s\n' "$p"
                found=1
            fi
        done
        ((found)) || echo '  No matching packages found.'
    else
        echo '  Unsupported package manager.'
    fi
}

services_status() {
    say 'VRAM services'
    if is_systemd; then
        printf '  dmem system: '
        systemctl is-active dmemcg-booster-system.service 2>/dev/null || echo 'not active'
        printf '  dmem user:   '
        systemctl --user is-active dmemcg-booster-user.service 2>/dev/null || echo 'not active'
        for s in plasma-foreground-booster.service gnome-vram-booster.service hyprland-focused-booster.service niri-focused-booster.service uresourced.service; do
            if systemctl --user cat "$s" >/dev/null 2>&1 || systemctl cat "$s" >/dev/null 2>&1; then
                printf '  %s: ' "$s"
                systemctl --user is-active "$s" 2>/dev/null || systemctl is-active "$s" 2>/dev/null || echo 'not active'
            fi
        done
    else
        warn 'systemd is not active; this release requires systemd for the persistent app.slice ceiling.'
    fi
}

ensure_base_dmem() {
    sudo -v || return 1
    if is_bazzite; then
        ok 'Bazzite already provides the base DMEM stack.'
    elif command -v pacman >/dev/null 2>&1; then
        if ! install_pacman_pkg dmemcg-booster; then
            err 'Could not install dmemcg-booster.'
            return 1
        fi
    elif command -v dnf >/dev/null 2>&1; then
        if ! package_installed dmemcg-booster; then
            if ! install_dnf_pkg dmemcg-booster; then
                ensure_terra || return 1
                install_dnf_pkg dmemcg-booster || return 1
            fi
        fi
    else
        err 'Unsupported package manager. This release supports pacman and dnf-based systems.'
        return 1
    fi

    sudo systemctl unmask dmemcg-booster-system.service 2>/dev/null || true
    sudo systemctl daemon-reload
    if ! sudo systemctl enable --now dmemcg-booster-system.service; then
        warn 'dmemcg-booster system service could not be started.'
    fi
    systemctl --user unmask dmemcg-booster-user.service 2>/dev/null || true
    systemctl --user daemon-reload
    if ! systemctl --user enable --now dmemcg-booster-user.service; then
        warn 'dmemcg-booster user service could not be started.'
    fi
}

install_gamescope_fallback() {
    local installed=0
    printf '  No verified desktop-specific booster is available; Gamescope is the generic fallback.\n'
    printf '  Install Gamescope now? [Y/n]: '
    read -r answer || answer=''
    answer="${answer:-Y}"
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        if is_bazzite; then
            package_installed gamescope && installed=1
        elif command -v pacman >/dev/null 2>&1; then
            install_pacman_pkg gamescope && installed=1 || true
        elif command -v dnf >/dev/null 2>&1; then
            install_dnf_pkg gamescope && installed=1 || true
        fi
    fi
    if ((installed)); then
        ok 'Gamescope is installed. Games must be launched through Gamescope to use this fallback integration.'
    else
        warn 'Gamescope was not installed. dmemcg-booster remains available; games need another foreground integration or Gamescope.'
    fi
}

install_desktop_integration() {
    local d answer installed=0 terra_ok=0
    d=$(desktop_name)
    say "Desktop integration: $d"

    case "$d" in
        'KDE Plasma')
            if is_bazzite; then
                package_installed plasma-foreground-booster-dmemcg && installed=1
            elif command -v pacman >/dev/null 2>&1; then
                if package_installed plasma-foreground-booster || package_installed plasma-foreground-booster-dmemcg; then
                    installed=1
                elif install_pacman_pkg plasma-foreground-booster || install_aur_pkg plasma-foreground-booster-dmemcg; then
                    installed=1
                fi
            elif command -v dnf >/dev/null 2>&1; then
                if ! package_installed plasma-foreground-booster-dmemcg; then
                    ensure_terra && terra_ok=1
                    ((terra_ok)) && install_dnf_pkg plasma-foreground-booster-dmemcg && installed=1
                else
                    installed=1
                fi
            fi
            if ((installed)) && is_systemd; then
                systemctl --user enable --now plasma-foreground-booster.service 2>/dev/null || true
            fi
            ((installed)) || warn 'KDE foreground booster is unavailable; Gamescope can be used instead.'
            ;;
        GNOME)
            if is_bazzite; then
                if package_installed uresourced-dmemcg; then
                    installed=1
                fi
            elif command -v pacman >/dev/null 2>&1; then
                local gnome_major driver_amdgpu
                gnome_major=$(gnome-shell --version 2>/dev/null | sed -n 's/.* //p' | cut -d. -f1)
                driver_amdgpu=0
                if command -v lspci >/dev/null 2>&1 && lspci -nnk 2>/dev/null | grep -qi 'Kernel driver in use: amdgpu'; then
                    driver_amdgpu=1
                fi
                if [ -n "$gnome_major" ] && [ "$gnome_major" -ge 45 ] 2>/dev/null && [ "$gnome_major" -le 50 ] 2>/dev/null && ((driver_amdgpu)); then
                    install_aur_pkg gnome-vram-booster && installed=1
                else
                    warn 'gnome-vram-booster targets GNOME 45-50 on AMD/amdgpu; using the generic Gamescope path instead.'
                fi
            elif command -v dnf >/dev/null 2>&1; then
                if ! package_installed uresourced-dmemcg; then
                    ensure_terra && terra_ok=1
                    ((terra_ok)) && install_dnf_pkg uresourced-dmemcg && installed=1
                else
                    installed=1
                fi
            fi
            if ((installed)) && command -v gnome-vram-boosterctl >/dev/null 2>&1; then
                warn 'Enable the GNOME VRAM Booster extension after installation; the upstream project requires a GNOME Shell extension.'
                REBOOT_NEEDED=1
            fi
            ((installed)) || install_gamescope_fallback
            ;;
        Hyprland)
            if command -v pacman >/dev/null 2>&1 && install_pacman_pkg hyprland-focused-booster; then
                installed=1
                if is_systemd; then
                    systemctl --user enable --now hyprland-focused-booster.service 2>/dev/null || true
                fi
                if ! command -v runapp >/dev/null 2>&1 && ! command -v uwsm >/dev/null 2>&1; then
                    warn 'hyprland-focused-booster expects applications to be launched as systemd units (for example through runapp or a similar tool).'
                fi
            fi
            ((installed)) || install_gamescope_fallback
            ;;
        Niri)
            if command -v pacman >/dev/null 2>&1 && install_pacman_pkg niri-focused-booster; then
                installed=1
                local niri_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/niri/config.kdl"
                if grep -Fq 'spawn-at-startup "niri-focused-booster"' "$niri_cfg" 2>/dev/null; then
                    ok 'niri-focused-booster is already configured to start with Niri.'
                else
                    printf 'Add niri-focused-booster to your Niri config automatically? [Y/n]: '
                    read -r answer || answer=''
                    answer="${answer:-Y}"
                    if [[ "$answer" =~ ^[Yy]$ ]]; then
                        mkdir -p "$(dirname "$niri_cfg")"
                        [ -f "$niri_cfg" ] && cp -a "$niri_cfg" "$niri_cfg.bak.$(date +%Y%m%d%H%M%S)"
                        printf '\n// Added by Linux VRAM Manager\nspawn-at-startup "niri-focused-booster"\n' >> "$niri_cfg"
                        REBOOT_NEEDED=1
                        ok 'Niri config updated; restart Niri (or reboot) to start the booster.'
                    else
                        warn 'Package installed, but Niri will not start it until the spawn-at-startup entry is added.'
                    fi
                fi
            fi
            ((installed)) || install_gamescope_fallback
            ;;
        *)
            install_gamescope_fallback
            ;;
    esac
}

prepare_kernel() {
    if dmem_ready; then
        ok 'DMEM/VRAM kernel support is already active.'
        return 0
    fi

    say 'Kernel / DMEM support'

    if is_bazzite || is_nobara; then
        warn 'This distro normally provides the required kernel integration.'
        warn 'DMEM is not currently exposing a VRAM region; update/reboot the distro before continuing.'
        REBOOT_NEEDED=1
        return 0
    fi

    if is_arch && (command -v yay >/dev/null 2>&1 || command -v paru >/dev/null 2>&1); then
        warn 'DMEM is not active in the current kernel.'
        warn 'Use a kernel with DMEM support (Linux 7.3+ or an appropriate distro kernel).' 
        printf 'Install linux-dmemcg automatically? [y/N]: '
        read -r answer || answer=''
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            if command -v yay >/dev/null 2>&1; then
                yay -S --needed linux-dmemcg || return 1
            else
                paru -S --needed linux-dmemcg || return 1
            fi
            REBOOT_NEEDED=1
            ok 'linux-dmemcg installed. Reboot into that kernel, then run Verify/Apply.'
        fi
        return 0
    fi

    if is_fedora || is_nobara; then
        warn 'DMEM is not active in the current Fedora-family kernel.'
        printf 'Update the Fedora kernel now? [y/N]: '
        read -r answer || answer=''
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            sudo dnf upgrade -y kernel kernel-core kernel-modules || return 1
            REBOOT_NEEDED=1
            ok 'Fedora-family kernel packages updated. Reboot, then run Verify/Apply.'
        fi
        return 0
    fi

    warn 'No automatic kernel preparation is available for this distro.'
    warn 'The system needs a kernel/driver combination that exposes GPU memory through Linux DMEM.'
    return 0
}

install_vram() {
    say 'Install / enable VRAM management'
    ensure_base_dmem || return 1
    install_desktop_integration
    prepare_kernel || return 1
    print_desktop_support
    services_status
    package_status
    if ((REBOOT_NEEDED)); then
        printf '\nA restart/reboot is needed to complete the selected changes. Reboot now? [y/N]: '
        read -r answer || answer=''
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            sudo systemctl reboot
        fi
        REBOOT_NEEDED=0
    fi
}

write_helper() {
    sudo tee "$HELPER" >/dev/null <<'SCRIPT'
#!/bin/sh
set -eu
CONFIG=/etc/default/dmemcg-appslice-limit
ROOT=/sys/fs/cgroup
USER_ID="$1"
[ -r "$CONFIG" ] && . "$CONFIG"
RESERVE_MIB="${RESERVE_MIB:-50}"
case "$RESERVE_MIB" in ''|*[!0-9]*) exit 1;; esac
CGREL=$(systemctl show "user@${USER_ID}.service" -p ControlGroup --value 2>/dev/null)
[ -n "$CGREL" ] || exit 1
APP="$ROOT$CGREL/app.slice"
for i in $(seq 1 300); do
    [ -r "$APP/dmem.max" ] && [ -r "$APP/dmem.current" ] && [ -r "$ROOT/dmem.capacity" ] && break
    sleep 1
done
[ -r "$APP/dmem.max" ] && [ -r "$APP/dmem.current" ] && [ -r "$ROOT/dmem.capacity" ] || exit 1
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
FOUND=0
while read -r DEVICE CAPACITY; do
    case "$DEVICE" in
        */vram|*/vram[0-9]*|*/vidmem|*/vidmem[0-9]*) ;;
        *) continue ;;
    esac
    FOUND=1
    TARGET=$((CAPACITY - RESERVE_MIB * 1024 * 1024))
    [ "$TARGET" -gt 0 ] || exit 1
    CURRENT=$(awk -v d="$DEVICE" '$1 == d {print $2; exit}' "$APP/dmem.current")
    if [ -n "$CURRENT" ] && [ "$CURRENT" -gt "$TARGET" ]; then
        echo "ERROR: current VRAM usage exceeds requested limit for $DEVICE" >&2
        exit 1
    fi
    printf '%s %s\n' "$DEVICE" "$TARGET" >> "$TMP"
done < "$ROOT/dmem.capacity"
[ "$FOUND" -eq 1 ] || exit 1
cat "$TMP" > "$APP/dmem.max"
echo "VRAM safety margin: ${RESERVE_MIB} MiB"
exit 0
SCRIPT
    sudo chmod 755 "$HELPER"
}

write_service() {
    local uid="$1"
    sudo tee "$SERVICE" >/dev/null <<EOF2
[Unit]
Description=Apply app.slice VRAM safety limit
After=user@${uid}.service
Requires=user@${uid}.service

[Service]
Type=oneshot
ExecStart=${HELPER} ${uid}
RemainAfterExit=yes
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF2
}

apply_limit() {
    local reserve input answer
    reserve=50
    [ -r "$CONFIG" ] && . "$CONFIG" 2>/dev/null || true
    reserve="${RESERVE_MIB:-50}"
    printf 'VRAM headroom in MiB [%s]: ' "$reserve"
    read -r input || return 1
    [ -n "$input" ] && reserve="$input"
    [[ "$reserve" =~ ^[0-9]+$ ]] || { err 'Enter a whole number of MiB.'; return 1; }
    (( reserve > 0 )) || { err 'Headroom must be greater than zero.'; return 1; }
    if ! dmem_ready; then
        err 'DMEM/VRAM support is not active. Run Install/Enable and reboot if it installed a new kernel.'
        return 1
    fi
    sudo tee "$CONFIG" >/dev/null <<EOF2
RESERVE_MIB=$reserve
EOF2
    write_helper
    write_service "$UID_NOW"
    sudo systemctl daemon-reload
    sudo systemctl enable dmemcg-appslice-limit.service
    if ! sudo systemctl restart dmemcg-appslice-limit.service; then
        err 'The VRAM ceiling service failed to start.'
        return 1
    fi
    if ! systemctl is-active --quiet dmemcg-appslice-limit.service; then
        err 'The VRAM ceiling was not applied successfully.'
        systemctl status dmemcg-appslice-limit.service --no-pager -l || true
        return 1
    fi
    systemctl status dmemcg-appslice-limit.service --no-pager -l
    printf '\nThe VRAM ceiling is active now; a reboot is not required. Reboot anyway to verify persistence? [y/N]: '
    read -r answer || answer=''
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        sudo systemctl reboot
    fi
}

verify() {
    local app
    say 'Verification'
    printf '  Systemd: '
    is_systemd && echo 'active' || echo 'not active'
    printf '  Desktop: %s\n' "$(desktop_name)"
    printf '  DMEM: '
    dmem_ready && echo 'ready' || echo 'not ready'
    app="$(app_path 2>/dev/null || true)"
    if [ -r "$app/dmem.max" ]; then
        echo
        echo '  dmem.capacity:'
        cat /sys/fs/cgroup/dmem.capacity
        echo
        echo '  app.slice/dmem.max:'
        cat "$app/dmem.max"
        echo
        echo '  app.slice/dmem.current:'
        cat "$app/dmem.current"
    else
        warn 'app.slice/dmem.max is unavailable.'
    fi
    echo
    systemctl show dmemcg-appslice-limit.service -p ActiveState -p SubState -p ExecMainStatus -p Result 2>/dev/null || true
    echo
    journalctl -b -u dmemcg-appslice-limit.service -n 12 --no-pager 2>/dev/null || true
}

remove_custom() {
    local app tmp
    say 'Remove custom VRAM ceiling'
    app="$(app_path 2>/dev/null || true)"
    if [ -w "$app/dmem.max" ] && [ -r /sys/fs/cgroup/dmem.capacity ]; then
        tmp="$(mktemp)"
        while read -r DEVICE _; do
            case "$DEVICE" in
                */vram|*/vram[0-9]*|*/vidmem|*/vidmem[0-9]*) printf '%s max\n' "$DEVICE" >> "$tmp";;
            esac
        done < /sys/fs/cgroup/dmem.capacity
        cat "$tmp" > "$app/dmem.max" 2>/dev/null || true
        rm -f "$tmp"
    fi
    sudo systemctl disable --now dmemcg-appslice-limit.service 2>/dev/null || true
    sudo rm -f "$SERVICE" "$HELPER" "$CONFIG"
    sudo systemctl daemon-reload
    ok 'Custom ceiling removed and app.slice restored to max.'
}

remove_packages() {
    local rc=0
    say 'Remove installed VRAM-management packages'
    if is_bazzite; then
        warn 'Bazzite manages these components as part of the image; they are not removed by this tool.'
        return
    fi

    if command -v pacman >/dev/null 2>&1; then
        local pkgs=() p manager pkg
        local candidates=(dmemcg-booster plasma-foreground-booster plasma-foreground-booster-dmemcg kcgroups gnome-vram-booster hyprland-focused-booster niri-focused-booster)
        for p in "${candidates[@]}"; do
            package_installed "$p" && pkgs+=("$p")
        done
        if [ -r "$STATE" ]; then
            while IFS='|' read -r manager pkg; do
                [ "$manager" = pacman ] || continue
                [ -n "$pkg" ] || continue
                case "$pkg" in
                    dmemcg-booster|plasma-foreground-booster|plasma-foreground-booster-dmemcg|kcgroups|gnome-vram-booster|hyprland-focused-booster|niri-focused-booster)
                        package_installed "$pkg" || continue
                        case " ${pkgs[*]} " in *" $pkg "*) ;; *) pkgs+=("$pkg");; esac
                        ;;
                esac
            done < "$STATE"
        fi
        if ((${#pkgs[@]})); then
            printf '  Will remove: %s\n' "${pkgs[*]}"
            sudo pacman -Rns "${pkgs[@]}" || rc=$?
        else
            warn 'No supported VRAM-management packages are installed.'
        fi
    elif command -v dnf >/dev/null 2>&1; then
        local pkgs=() p manager pkg
        local candidates=(dmemcg-booster plasma-foreground-booster-dmemcg uresourced-dmemcg)
        for p in "${candidates[@]}"; do
            package_installed "$p" && pkgs+=("$p")
        done
        if [ -r "$STATE" ]; then
            while IFS='|' read -r manager pkg; do
                [ "$manager" = rpm ] || continue
                [ -n "$pkg" ] || continue
                case "$pkg" in
                    dmemcg-booster|plasma-foreground-booster-dmemcg|uresourced-dmemcg)
                        package_installed "$pkg" || continue
                        case " ${pkgs[*]} " in *" $pkg "*) ;; *) pkgs+=("$pkg");; esac
                        ;;
                esac
            done < "$STATE"
        fi
        if ((${#pkgs[@]})); then
            printf '  Will remove: %s\n' "${pkgs[*]}"
            sudo dnf remove -y "${pkgs[@]}" || rc=$?
        else
            warn 'No supported VRAM-management packages are installed.'
        fi
    else
        warn 'Unsupported package manager.'
        return 1
    fi

    if ((rc == 0)); then
        sudo rm -f "$STATE"
    else
        warn 'Package removal did not complete; the package-installation record was kept.'
    fi
    return "$rc"
}

remove_everything() {
    remove_custom
    printf '\nAlso remove the VRAM-management packages? [y/N]: '
    read -r answer || answer=''
    [[ "$answer" =~ ^[Yy]$ ]] && remove_packages
}

status_all() {
    . /etc/os-release 2>/dev/null || true
    say 'System'
    printf '  OS: %s\n' "${PRETTY_NAME:-unknown}"
    printf '  Kernel: %s\n' "$(uname -r)"
    printf '  UID: %s\n' "$UID_NOW"
    printf '  Desktop: %s\n' "$(desktop_name)"
    if dmem_ready; then ok 'DMEM/VRAM is ready.'; else warn 'DMEM/VRAM is not ready.'; fi
    print_desktop_support
    package_status
    services_status
    if [ -r "$CONFIG" ]; then
        printf '  Configured headroom: '
        sed -n 's/^RESERVE_MIB=//p' "$CONFIG"
    fi
}

while true; do
    clear 2>/dev/null || true
    echo '==============================================='
    printf '          Linux VRAM Management Tool v%s\n' "$VERSION"
    echo '==============================================='
    echo
    echo '  1) Install / enable VRAM management'
    echo '  2) Apply / change VRAM ceiling'
    echo '  3) Verify current / post-reboot state'
    echo '  4) Remove custom VRAM ceiling'
    echo '  5) Remove everything'
    echo '  6) System / package status'
    echo '  7) Exit'
    echo
    printf 'Choose [1-7]: '
    read -r choice || exit 0
    case "$choice" in
        1) install_vram; pause_menu;;
        2) apply_limit; pause_menu;;
        3) verify; pause_menu;;
        4) remove_custom; pause_menu;;
        5) remove_everything; pause_menu;;
        6) status_all; pause_menu;;
        7) exit 0;;
        *) echo 'Invalid choice.'; sleep 1;;
    esac
done

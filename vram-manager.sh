#!/usr/bin/env bash
# Linux VRAM Management Tool
# Installs the DMEM stack when available, applies a persistent dmem.max
# headroom limit, verifies it, and removes the custom setup when requested.

set -u

SERVICE_TEMPLATE=/etc/systemd/system/dmemcg-appslice-limit@.service
HELPER=/usr/local/sbin/set-dmem-appslice-limit
CONFIG=/etc/default/dmemcg-appslice-limit
UID_NOW=$(id -u)

say() { printf '\n%s\n' "$*"; }
ok() { printf '  [OK] %s\n' "$*"; }
warn() { printf '  [!] %s\n' "$*"; }
err() { printf '  [ERROR] %s\n' "$*" >&2; }
pause_menu() { printf '\nPress Enter to continue... '; read -r _ || true; }

is_bazzite() {
    grep -qi '^ID=bazzite$' /etc/os-release 2>/dev/null || grep -qi '^VARIANT=.*Bazzite' /etc/os-release 2>/dev/null
}

is_kde() {
    local d="${XDG_CURRENT_DESKTOP:-} ${XDG_SESSION_DESKTOP:-}"
    printf '%s\n' "$d" | grep -Eiq 'KDE|Plasma'
}

app_path() {
    local rel
    rel=$(systemctl show "user@${UID_NOW}.service" -p ControlGroup --value 2>/dev/null) || return 1
    [ -n "$rel" ] || return 1
    printf '/sys/fs/cgroup%s/app.slice\n' "$rel"
}

package_status() {
    say "VRAM management packages"
    if command -v pacman >/dev/null 2>&1; then
        local p
        for p in dmemcg-booster plasma-foreground-booster kcgroups; do
            if pacman -Q "$p" >/dev/null 2>&1; then
                printf '  [installed] %s %s\n' "$p" "$(pacman -Q "$p" | awk '{print $2}')"
            else
                printf '  [missing]   %s\n' "$p"
            fi
        done
    elif command -v rpm >/dev/null 2>&1; then
        local p found=0
        for p in dmemcg-booster plasma-foreground-booster-dmemcg kcgroups-dmemcg; do
            if rpm -q "$p" >/dev/null 2>&1; then
                printf '  [installed] %s\n' "$p"
                found=1
            fi
        done
        ((found)) || echo '  No matching VRAM packages found.'
    else
        echo '  Unsupported package manager.'
    fi
}

services_status() {
    say "DMEM services"
    if systemctl cat dmemcg-booster-system.service >/dev/null 2>&1; then
        systemctl is-active dmemcg-booster-system.service 2>/dev/null || true
        systemctl is-enabled dmemcg-booster-system.service 2>/dev/null || true
    else
        echo '  dmemcg-booster-system.service: not installed'
    fi
    if systemctl --user cat dmemcg-booster-user.service >/dev/null 2>&1; then
        printf '  user service: '
        systemctl --user is-active dmemcg-booster-user.service 2>/dev/null || true
    else
        echo '  dmemcg-booster-user.service: not installed'
    fi
}

install_vram() {
    say "Install / enable VRAM management"

    if is_bazzite; then
        ok 'Bazzite includes dmemcg-booster and the appropriate desktop integration in its image.'
        services_status
        return
    fi

    if command -v pacman >/dev/null 2>&1; then
        if sudo pacman -S --needed dmemcg-booster plasma-foreground-booster; then
            ok 'VRAM packages installed from pacman.'
        else
            warn 'Packages were not available from the pacman repositories.'
            if command -v yay >/dev/null 2>&1; then
                yay -S --needed dmemcg-booster plasma-foreground-booster-dmemcg || return 1
            elif command -v paru >/dev/null 2>&1; then
                paru -S --needed dmemcg-booster plasma-foreground-booster-dmemcg || return 1
            else
                err 'No AUR helper found. Install yay/paru or install the DMEM packages manually.'
                return 1
            fi
        fi
    elif command -v dnf >/dev/null 2>&1; then
        if is_kde; then
            sudo dnf install dmemcg-booster plasma-foreground-booster-dmemcg || return 1
        else
            sudo dnf install dmemcg-booster || return 1
            warn 'Non-KDE desktop detected; use the desktop/Gamescope integration appropriate to your setup.'
        fi
    else
        err 'This version supports pacman and dnf package installation.'
        return 1
    fi

    sudo systemctl unmask dmemcg-booster-system.service 2>/dev/null || true
    sudo systemctl daemon-reload
    sudo systemctl enable --now dmemcg-booster-system.service 2>/dev/null || true

    systemctl --user unmask dmemcg-booster-user.service 2>/dev/null || true
    systemctl --user daemon-reload
    systemctl --user enable --now dmemcg-booster-user.service 2>/dev/null || true

    services_status
}

write_helper() {
    sudo tee "$HELPER" >/dev/null <<'SCRIPT'
#!/bin/sh

USER_ID="$1"
ROOT=/sys/fs/cgroup
CONFIG=/etc/default/dmemcg-appslice-limit

[ -r "$CONFIG" ] || exit 1
. "$CONFIG"
RESERVE_MIB="${RESERVE_MIB:-50}"

case "$RESERVE_MIB" in
    ''|*[!0-9]*) echo "ERROR: invalid RESERVE_MIB" >&2; exit 1 ;;
esac

for i in $(seq 1 300); do
    CGREL=$(systemctl show "user@${USER_ID}.service" -p ControlGroup --value 2>/dev/null)
    [ -n "$CGREL" ] && break
    sleep 1
done

[ -n "$CGREL" ] || exit 1
APP="$ROOT$CGREL/app.slice"

# Wait for the VRAM packages to expose DMEM on app.slice.
for i in $(seq 1 300); do
    [ -r "$APP/dmem.max" ] && [ -r "$APP/dmem.current" ] && [ -r "$ROOT/dmem.capacity" ] && break
    sleep 1
done

[ -r "$APP/dmem.max" ] && [ -r "$APP/dmem.current" ] && [ -r "$ROOT/dmem.capacity" ] || exit 1

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

    printf '%s %s\n' "$DEVICE" "$TARGET" > "$APP/dmem.max" || exit 1
    echo "VRAM: $DEVICE"
    echo "Capacity: $CAPACITY bytes"
    echo "Limit: $TARGET bytes (${RESERVE_MIB} MiB headroom)"
done < "$ROOT/dmem.capacity"

[ "$FOUND" -eq 1 ] || exit 1
exit 0
SCRIPT
    sudo chmod 755 "$HELPER"
}

write_service() {
    local uid="$1"
    sudo tee "$SERVICE_TEMPLATE" >/dev/null <<EOF
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
EOF
}

apply_limit() {
    local reserve input
    reserve=50
    [ -r "$CONFIG" ] && . "$CONFIG" 2>/dev/null || true
    reserve="${RESERVE_MIB:-50}"

    printf 'VRAM headroom in MiB [%s]: ' "$reserve"
    read -r input || return 1
    [ -n "$input" ] && reserve="$input"
    [[ "$reserve" =~ ^[0-9]+$ ]] || { err 'Enter a whole number of MiB.'; return 1; }
    ((reserve > 0)) || { err 'Headroom must be greater than zero.'; return 1; }

    sudo tee "$CONFIG" >/dev/null <<EOF
RESERVE_MIB=$reserve
EOF

    write_helper
    write_service "$UID_NOW"
    sudo systemctl daemon-reload
    sudo systemctl enable "dmemcg-appslice-limit@${UID_NOW}.service"

    # The template's instance is used so the actual UID is part of the service name.
    sudo systemctl restart "dmemcg-appslice-limit@${UID_NOW}.service"
    echo
    systemctl status "dmemcg-appslice-limit@${UID_NOW}.service" --no-pager -l
}

verify() {
    local svc="dmemcg-appslice-limit@${UID_NOW}.service" app
    say "Verification"

    printf '  Persistent service: '
    systemctl is-enabled "$svc" 2>/dev/null || true
    printf '  Current state:\n'
    systemctl show "$svc" -p ActiveState -p SubState -p ExecMainStatus -p Result -p ActiveEnterTimestamp 2>/dev/null || true

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
    echo '  Current-boot service log:'
    journalctl -b -u "$svc" -n 12 --no-pager 2>/dev/null || true
}

remove_custom() {
    local app
    say 'Remove custom VRAM ceiling'

    app="$(app_path 2>/dev/null || true)"
    if [ -w "$app/dmem.max" ] && [ -r /sys/fs/cgroup/dmem.capacity ]; then
        while read -r DEVICE _; do
            case "$DEVICE" in
                */vram|*/vram[0-9]*|*/vidmem|*/vidmem[0-9]*) printf '%s max\n' "$DEVICE" > "$app/dmem.max" 2>/dev/null || true ;;
            esac
        done < /sys/fs/cgroup/dmem.capacity
    fi

    sudo systemctl disable --now "dmemcg-appslice-limit@${UID_NOW}.service" 2>/dev/null || true
    sudo systemctl disable --now dmemcg-appslice-limit.service 2>/dev/null || true
    sudo rm -f "$SERVICE_TEMPLATE" /etc/systemd/system/dmemcg-appslice-limit.service "$HELPER" "$CONFIG"
    sudo systemctl daemon-reload
    ok 'Custom ceiling and its service were removed.'
}

remove_packages() {
    say 'Remove VRAM-management packages'

    if is_bazzite; then
        warn 'Bazzite provides these packages as part of the image; this tool will not remove them.'
        return
    fi

    if command -v pacman >/dev/null 2>&1; then
        local pkgs=() p
        for p in dmemcg-booster plasma-foreground-booster kcgroups plasma-foreground-booster-dmemcg kcgroups-dmemcg; do
            pacman -Q "$p" >/dev/null 2>&1 && pkgs+=("$p")
        done
        ((${#pkgs[@]})) && sudo pacman -Rns "${pkgs[@]}" || warn 'No matching pacman packages found.'
    elif command -v dnf >/dev/null 2>&1; then
        local pkgs=() p
        for p in dmemcg-booster plasma-foreground-booster-dmemcg; do
            rpm -q "$p" >/dev/null 2>&1 && pkgs+=("$p")
        done
        ((${#pkgs[@]})) && sudo dnf remove "${pkgs[@]}" || warn 'No matching dnf packages found.'
    else
        warn 'Unsupported package manager.'
    fi
}

remove_everything() {
    remove_custom
    printf '\nAlso remove the VRAM-management packages? [y/N]: '
    read -r answer || answer=''
    [[ "$answer" =~ ^[Yy]$ ]] && remove_packages
}

status_all() {
    print_system
    package_status
    services_status
}

print_system() {
    local pretty
    . /etc/os-release 2>/dev/null || true
    pretty="${PRETTY_NAME:-unknown}"
    say 'System'
    printf '  OS: %s\n' "$pretty"
    printf '  Kernel: %s\n' "$(uname -r)"
    printf '  UID: %s\n' "$UID_NOW"
    printf '  Desktop: %s\n' "${XDG_CURRENT_DESKTOP:-unknown}"
    if [ -r /sys/fs/cgroup/dmem.capacity ]; then
        echo '  DMEM:'
        cat /sys/fs/cgroup/dmem.capacity
    else
        echo '  DMEM: unavailable'
    fi
}

while true; do
    clear 2>/dev/null || true
    echo '==============================================='
    echo '          Linux VRAM Management Tool'
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
        1) install_vram; pause_menu ;;
        2) apply_limit; pause_menu ;;
        3) verify; pause_menu ;;
        4) remove_custom; pause_menu ;;
        5) remove_everything; pause_menu ;;
        6) status_all; pause_menu ;;
        7) exit 0 ;;
        *) echo 'Invalid choice.'; sleep 1 ;;
    esac
done

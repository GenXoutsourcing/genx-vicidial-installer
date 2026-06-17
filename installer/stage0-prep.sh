#!/bin/bash
# -----------------------------------------------------------------------------
# GenX VICIdial Installer - Stage 0 OS Preparation
# Target: AlmaLinux 9 / Rocky Linux 9
# Logs to: /var/log/genx-install.log
# Reads version from: VERSION
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$REPO_ROOT/VERSION"
LOG_FILE="/var/log/genx-install.log"

INSTALLER_VERSION="unknown"
[[ -f "$VERSION_FILE" ]] && INSTALLER_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

log() {
    echo "$(date '+%F %T') [stage0 v${INSTALLER_VERSION}] $*" | tee -a "$LOG_FILE"
}

die() {
    log "ERROR: $*"
    exit 1
}

on_error() {
    local exit_code=$?
    local line_no=$1
    log "FAILED: command exited with code $exit_code at line $line_no"
    log "Review log: $LOG_FILE"
    exit "$exit_code"
}

trap 'on_error $LINENO' ERR

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run this script as root."
}

require_el9() {
    [[ -f /etc/redhat-release ]] || die "This installer requires AlmaLinux/Rocky/RHEL 9."

    if ! grep -Eq 'release 9\.' /etc/redhat-release; then
        log "Detected OS:"
        cat /etc/redhat-release | tee -a "$LOG_FILE"
        die "This installer targets EL9 only."
    fi
}

select_timezone() {
    echo
    echo "=================================================="
    echo " Select server timezone"
    echo "=================================================="
    echo "1) Eastern  - America/New_York"
    echo "2) Central  - America/Chicago"
    echo "3) Mountain - America/Denver"
    echo "4) Pacific  - America/Los_Angeles"
    echo

    read -rp "Timezone choice [1]: " TZ_CHOICE
    TZ_CHOICE="${TZ_CHOICE:-1}"

    case "$TZ_CHOICE" in
        1) GENX_TZ="America/New_York" ;;
        2) GENX_TZ="America/Chicago" ;;
        3) GENX_TZ="America/Denver" ;;
        4) GENX_TZ="America/Los_Angeles" ;;
        *)
            log "Invalid timezone choice '$TZ_CHOICE'. Using America/New_York."
            GENX_TZ="America/New_York"
            ;;
    esac

    log "Setting timezone to $GENX_TZ"
    timedatectl set-timezone "$GENX_TZ"
}

main() {
    require_root
    require_el9

    clear
    cat <<BANNER
==================================================
 GenX VICIdial Installer - Stage 0 OS Preparation
 Version: ${INSTALLER_VERSION}
 Log:     ${LOG_FILE}
==================================================
BANNER

    log "Stage 0 started"
    log "Repository root: $REPO_ROOT"
    log "Detected OS: $(cat /etc/redhat-release)"

    log "Installing English locale package"
    dnf install -y glibc-langpack-en

    log "Setting locale to en_US.UTF-8"
    localectl set-locale en_US.UTF-8
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8

    select_timezone

    log "Updating OS packages"
    dnf -y check-update || true
    dnf -y update

    log "Installing EPEL and base tools"
    dnf -y install epel-release
    dnf -y update
    dnf -y install \
        git wget curl tar unzip rsync bind-utils dnf-plugins-core \
        vim nano screen tmux lsof net-tools policycoreutils-python-utils

    log "Disabling SELinux permanently"
    if [[ -f /etc/selinux/config ]]; then
        cp -n /etc/selinux/config /etc/selinux/config.genx-original || true
        sed -i 's/^SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config
    fi
    setenforce 0 2>/dev/null || true

    log "Stage 0 complete. Reboot required before Stage 1."

    echo
    echo "After reboot:"
    echo "  cd $REPO_ROOT"
    echo "  ./installer/genx-install"
    echo

    read -rp "Reboot now? [Y/n]: " REBOOT_NOW
    REBOOT_NOW="${REBOOT_NOW:-Y}"

    if [[ "$REBOOT_NOW" =~ ^[Yy]$ ]]; then
        log "Rebooting server"
        reboot
    else
        log "User skipped reboot"
        echo "Reboot skipped. Please reboot manually before running Stage 1."
    fi
}

main "$@"

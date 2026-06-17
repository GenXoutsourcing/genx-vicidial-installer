#!/bin/bash
# -----------------------------------------------------------------------------
# GenX VICIdial Installer - Stage 0 OS Preparation
# Target: AlmaLinux 9 / Rocky Linux 9
#
# Purpose:
#   Prepare a fresh Alma/Rocky 9 server before running the main installer.
#   This stage intentionally ends with a reboot because SELinux and kernel/system
#   package changes need a clean boot before compiling DAHDI/Asterisk.
#
# What this does:
#   - Verifies root and EL9 family
#   - Installs English locale support
#   - Lets user select one of four US timezones
#   - Updates the operating system
#   - Installs base tools used by Stage 1
#   - Disables SELinux permanently
#   - Prompts for reboot
# -----------------------------------------------------------------------------

set -Eeuo pipefail

LOG_FILE="/var/log/genx-stage0-prep.log"
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'echo "ERROR: Stage 0 failed on line $LINENO. See $LOG_FILE" >&2' ERR

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo "ERROR: Run this script as root."
        exit 1
    fi
}

require_el9() {
    if [[ ! -f /etc/redhat-release ]]; then
        echo "ERROR: This installer requires AlmaLinux/Rocky/RHEL 9."
        exit 1
    fi
    if ! grep -Eq 'release 9\.' /etc/redhat-release; then
        echo "ERROR: This installer targets EL9 only. Found:"
        cat /etc/redhat-release
        exit 1
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
        *) echo "Invalid choice. Using America/New_York."; GENX_TZ="America/New_York" ;;
    esac

    timedatectl set-timezone "$GENX_TZ"
    echo "Timezone set to: $GENX_TZ"
}

main() {
    require_root
    require_el9

    echo "=================================================="
    echo " GenX VICIdial Installer - Stage 0 OS Preparation"
    echo " Log: $LOG_FILE"
    echo "=================================================="

    echo "Installing locale package..."
    dnf install -y glibc-langpack-en
    localectl set-locale en_US.UTF-8
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8

    select_timezone

    echo "Updating OS packages..."
    dnf -y check-update || true
    dnf -y update

    echo "Installing EPEL and base tools..."
    dnf -y install epel-release
    dnf -y update
    dnf -y install git wget curl tar unzip rsync bind-utils dnf-plugins-core vim nano screen tmux lsof net-tools policycoreutils-python-utils

    echo "Disabling SELinux permanently..."
    if [[ -f /etc/selinux/config ]]; then
        cp -n /etc/selinux/config /etc/selinux/config.genx-original || true
        sed -i 's/^SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config
    fi
    setenforce 0 2>/dev/null || true

    echo
    echo "Stage 0 complete. A reboot is required before Stage 1."
    echo "After reboot, run the main installer from the repository:"
    echo "  cd /usr/src/genx-vicidial-installer"
    echo "  sudo ./installer/genx-install"
    echo
    read -rp "Reboot now? [Y/n]: " REBOOT_NOW
    REBOOT_NOW="${REBOOT_NOW:-Y}"
    if [[ "$REBOOT_NOW" =~ ^[Yy]$ ]]; then
        reboot
    else
        echo "Reboot skipped. Please reboot manually before running Stage 1."
    fi
}

main "$@"

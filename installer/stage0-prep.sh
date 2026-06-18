#!/bin/bash
# -----------------------------------------------------------------------------
# GenX VICIdial Installer - Stage 0 OS Preparation
# Target: AlmaLinux 9 / Rocky Linux 9
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
    [[ -f /etc/redhat-release ]] || die "This installer requires Alma/Rocky/RHEL 9."

    if ! grep -Eq 'release 9\.' /etc/redhat-release; then
        die "This installer targets EL9 only."
    fi
}

select_timezone() {
    echo
    echo "1) Eastern  (America/New_York)"
    echo "2) Central  (America/Chicago)"
    echo "3) Mountain (America/Denver)"
    echo "4) Pacific  (America/Los_Angeles)"
    echo

    read -rp "Timezone [1]: " TZ_CHOICE
    TZ_CHOICE="${TZ_CHOICE:-1}"

    case "$TZ_CHOICE" in
        1) GENX_TZ="America/New_York" ;;
        2) GENX_TZ="America/Chicago" ;;
        3) GENX_TZ="America/Denver" ;;
        4) GENX_TZ="America/Los_Angeles" ;;
        *) GENX_TZ="America/New_York" ;;
    esac

    timedatectl set-timezone "$GENX_TZ"
    log "Timezone set to $GENX_TZ"
}

main() {

    require_root
    require_el9

    clear

    cat <<EOF
==================================================
 GenX VICIdial Installer - Stage0
 Version: ${INSTALLER_VERSION}
==================================================
EOF

    log "Stage0 started"

    #
    # Locale
    #
    dnf -y install glibc-langpack-en

    localectl set-locale LANG=en_US.UTF-8

    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8

    #
    # Timezone
    #
    select_timezone

    #
    # Full OS update
    #
    log "Updating OS"

    dnf -y update

    #
    # Base tools only
    #
    log "Installing base tools"

    dnf -y install \
        epel-release \
        git \
        wget \
        curl \
        unzip \
        tar \
        rsync \
        bind-utils \
        dnf-plugins-core \
        vim \
        nano \
        screen \
        tmux \
        lsof \
        net-tools \
        policycoreutils-python-utils

    #
    # Disable SELinux
    #
    log "Disabling SELinux"

    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config

    setenforce 0 2>/dev/null || true

    #
    # Done
    #
    log "Stage0 complete"

    echo
    echo "A reboot is required."
    echo

    read -rp "Reboot now? [Y/n]: " REBOOT_NOW
    REBOOT_NOW="${REBOOT_NOW:-Y}"

    if [[ "$REBOOT_NOW" =~ ^[Yy]$ ]]; then
        reboot
    fi
}

main "$@"

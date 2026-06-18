#!/bin/bash
# -----------------------------------------------------------------------------
# GenX VICIdial Installer - Stage 0 OS Preparation
# Target: AlmaLinux 9 / Rocky Linux 9
# Logs to: /var/log/genx-install.log
# Reads version from: VERSION
#
# Purpose:
#   Prepare a fresh EL9 server before Stage 1.
#   Stage 0 should install/validate OS repos, build tools, kernel headers,
#   PHP/Apache prerequisites, Certbot, and VICIdial runtime Perl modules.
#
# Important:
#   This script intentionally does not install/configure VICIdial itself.
#   It ends with a reboot because kernel/package/SELinux changes need a clean boot.
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$REPO_ROOT/VERSION"
LOG_FILE="/var/log/genx-install.log"
PHP_STREAM="remi-8.2"

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

enable_repositories() {
    log "Installing repository tools and EPEL"
    dnf -y install dnf-plugins-core yum-utils epel-release

    log "Enabling CRB repository"
    dnf config-manager --set-enabled crb || true

    log "Installing Remi repository for PHP 8.2"
    if [[ ! -f /etc/yum.repos.d/remi.repo ]]; then
        dnf -y install https://rpms.remirepo.net/enterprise/remi-release-9.rpm
    fi

    log "Disabling external MariaDB repo for Express v1"
    # Express v1 intentionally uses Alma/Rocky native MariaDB to avoid mysql-libs conflicts.
    rm -f /etc/yum.repos.d/MariaDB.repo

    log "Enabling PHP module stream: ${PHP_STREAM}"
    dnf -y module reset php || true
    dnf -y module enable php:${PHP_STREAM}

    log "Refreshing DNF metadata"
    dnf -y clean all || true
    dnf -y makecache
}

install_base_tools() {
    log "Installing base tools"
    dnf -y install \
        git wget curl tar unzip zip rsync bind-utils dnf-plugins-core yum-utils \
        vim nano screen tmux lsof net-tools policycoreutils-python-utils \
        htop iftop atop mytop inxi pciutils usbutils jq bc pv which file \
        mailx s-nail postfix sendmail cronie cronie-anacron logrotate
}

install_build_dependencies() {
    log "Installing Development Tools group"
    dnf -y groupinstall "Development Tools"

    log "Installing kernel/build dependencies for DAHDI/Asterisk"
    dnf -y install \
        kernel-devel-$(uname -r) kernel-headers-$(uname -r) \
        elfutils-libelf-devel openssl-devel ncurses-devel newt newt-devel slang-devel \
        libxml2-devel sqlite-devel sqlite libuuid-devel uuid-devel libedit-devel readline-devel \
        speex-devel speexdsp-devel libsrtp-devel jansson-devel gsm-devel \
        bison flex rpm-build patch make gcc gcc-c++ autoconf automake libtool pkgconfig \
        sox ImageMagick lame lame-devel
}

install_web_stack_prereqs() {
    log "Installing Apache, Certbot and PHP prerequisites"
    dnf -y install \
        httpd mod_ssl certbot python3-certbot-apache firewalld \
        php php-cli php-common php-devel php-gd php-curl php-mysqlnd php-ldap \
        php-zip php-fileinfo php-opcache php-imap php-mbstring php-odbc \
        php-pear php-xml php-xmlrpc php-fpm
}

install_mariadb_prereqs() {
    log "Installing MariaDB native prerequisites"
    dnf -y install mariadb-server mariadb mariadb-devel perl-DBD-MySQL
}

install_vicidial_perl_prereqs() {
    log "Installing VICIdial Perl runtime prerequisites from RPMs"
    dnf -y install \
        perl perl-CPAN perl-App-cpanminus perl-YAML perl-CPAN-DistnameInfo \
        perl-libwww-perl perl-LWP-Protocol-https perl-IO-Socket-SSL perl-Net-SSLeay \
        perl-DBI perl-DBD-MySQL perl-GD perl-Env perl-Term-ReadLine-Gnu \
        perl-SelfLoader perl-File-Which perl-ExtUtils-MakeMaker perl-Archive-Tar \
        perl-CGI perl-JSON perl-Time-HiRes perl-Net-Telnet perl-Net-Server perl-Switch

    log "Installing Asterisk::AGI via cpanminus"
    # EL9 repositories do not consistently provide perl-Asterisk-AGI.
    # HTTPS support is installed above so cpanm can reach CPAN cleanly.
    cpanm --notest Asterisk::AGI
}

create_runtime_directories() {
    log "Creating runtime directories expected by Asterisk/VICIdial"
    mkdir -p \
        /var/lib/asterisk/phoneprov \
        /var/lib/asterisk/sounds \
        /var/lib/asterisk/moh \
        /var/lib/asterisk/mohmp3 \
        /var/lib/asterisk/quiet-mp3 \
        /var/lib/asterisk/agi-bin \
        /var/spool/asterisk \
        /var/spool/asterisk/monitor \
        /var/spool/asterisk/monitorDONE/MP3 \
        /var/spool/asterisk/monitorDONE/ORIG \
        /var/log/asterisk \
        /var/log/astguiclient \
        /usr/src/genx-build
}

validate_prerequisites() {
    echo
    echo "=================================================="
    echo " Validating Stage 0 prerequisites"
    echo "=================================================="

    log "Validating important RPMs"
    rpm -q git screen wget curl httpd php mariadb-server kernel-devel-$(uname -r) kernel-headers-$(uname -r) perl-Net-Telnet perl-Net-Server perl-Switch perl-LWP-Protocol-https perl-IO-Socket-SSL perl-libwww-perl perl-App-cpanminus >/dev/null

    log "Validating required Perl modules"
    perl -MNet::Telnet -e 'print "Net::Telnet OK\n"' | tee -a "$LOG_FILE"
    perl -MNet::Server -e 'print "Net::Server OK\n"' | tee -a "$LOG_FILE"
    perl -MSwitch -e 'print "Switch OK\n"' | tee -a "$LOG_FILE"
    perl -MAsterisk::AGI -e 'print "Asterisk::AGI OK\n"' | tee -a "$LOG_FILE"

    log "Validating PHP stream"
    php -v | head -1 | tee -a "$LOG_FILE"

    log "Validating enabled repositories"
    dnf repolist | egrep -i 'epel|remi|crb|appstream|baseos' | tee -a "$LOG_FILE" || true

    log "Validating kernel-devel matches running kernel"
    [[ -d "/usr/src/kernels/$(uname -r)" ]] || die "Missing matching kernel-devel for running kernel $(uname -r). Reboot after update and rerun Stage 0."
}

disable_selinux() {
    log "Disabling SELinux permanently"
    if [[ -f /etc/selinux/config ]]; then
        cp -n /etc/selinux/config /etc/selinux/config.genx-original || true
        sed -i 's/^SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config
    fi
    setenforce 0 2>/dev/null || true
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
    log "Running kernel: $(uname -r)"

    log "Installing English locale package"
    dnf -y install glibc-langpack-en

    log "Setting locale to en_US.UTF-8"
    localectl set-locale en_US.UTF-8
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8

    select_timezone

    log "Updating OS packages"
    dnf -y check-update || true
    dnf -y update

    enable_repositories
    install_base_tools
    install_build_dependencies
    install_web_stack_prereqs
    install_mariadb_prereqs
    install_vicidial_perl_prereqs
    create_runtime_directories
    disable_selinux
    validate_prerequisites

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

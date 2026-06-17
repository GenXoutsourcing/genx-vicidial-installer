#!/bin/bash
# -----------------------------------------------------------------------------
# GenX VICIdial Installer - Stage 1 Express Install
# Target: AlmaLinux 9 / Rocky Linux 9
# Scope v1: Express server only
#
# Express role includes:
#   - MariaDB 10.11 database server
#   - Apache/httpd + Remi PHP 8.2
#   - Asterisk 18.21.0 from official source
#   - DAHDI 3.4.0 from official source with Alma/Rocky 9 kernel patches
#   - VICIdial SVN checkout/install
#   - ViciBox-style dynportal + VB-firewall assets from this Git repo
#   - Let's Encrypt SSL and WebRTC configuration
#   - ViciBox-style cron/rc.local behavior
#
# Troubleshooting:
#   Main log: /var/log/genx-stage1-express.log
#   Saved credentials: /root/genx-install-info.txt
#
# Important:
#   This script intentionally avoids demo.genxcontactcenter.com downloads.
#   Only public upstream repos/sources and local repo assets are used.
# -----------------------------------------------------------------------------

set -Eeuo pipefail

LOG_FILE="/var/log/genx-stage1-express.log"
INFO_FILE="/root/genx-install-info.txt"
BUILD_DIR="/usr/src/genx-build"
VICIDIAL_SVN="svn://svn.eflo.net/agc_2-X/trunk"
ASTERISK_VERSION="18.21.0"
DAHDI_VERSION="3.4.0+3.4.0"
MARIADB_VERSION="10.11"
PHP_STREAM="remi-8.2"

# Defaults; replaced by prompts.
REPO_ROOT=""
FQDN=""
ADMIN_EMAIL=""
PUBLIC_IP=""
DNS_IPS=""
MYSQL_ROOT_PASS=""
VICI_DB_PASS=""
VICI_CUSTOM_PASS=""
RANDOM_AUTH=""
SVN_REVISION=""
RECORDING_RETENTION_DAYS=""

exec > >(tee -a "$LOG_FILE") 2>&1
trap 'echo "ERROR: Express install failed on line $LINENO. See $LOG_FILE" >&2' ERR

usage() {
    echo "Usage: $0 --repo-root /path/to/genx-vicidial-installer"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root)
            REPO_ROOT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo "ERROR: Run this script as root."
        exit 1
    fi
}

require_el9() {
    if [[ ! -f /etc/redhat-release ]] || ! grep -Eq 'release 9\.' /etc/redhat-release; then
        echo "ERROR: This installer targets AlmaLinux/Rocky/RHEL 9 only."
        cat /etc/redhat-release 2>/dev/null || true
        exit 1
    fi
}

require_repo_assets() {
    if [[ -z "$REPO_ROOT" || ! -d "$REPO_ROOT" ]]; then
        echo "ERROR: --repo-root is required and must point to the Git repository."
        exit 1
    fi

    local missing=0
    for path in \
        "$REPO_ROOT/assets/mariadb" \
        "$REPO_ROOT/assets/apache" \
        "$REPO_ROOT/assets/dynportal" \
        "$REPO_ROOT/assets/firewall" \
        "$REPO_ROOT/assets/vicibox/cron"; do
        if [[ ! -d "$path" ]]; then
            echo "ERROR: Missing asset directory: $path"
            missing=1
        fi
    done

    if [[ "$missing" -eq 1 ]]; then
        echo "Repository assets are incomplete. Fix GitHub checkout before continuing."
        exit 1
    fi
}

random_password() {
    # 24 chars, shell/mysql friendly; no quotes or spaces.
    tr -dc 'A-Za-z0-9_@%+=' </dev/urandom | head -c 24
}

get_primary_private_ip() {
    hostname -I | awk '{print $1}'
}

get_public_ip() {
    curl -fsS4 https://ifconfig.me 2>/dev/null || curl -fsS4 https://api.ipify.org 2>/dev/null || true
}

prompt_server_info() {
    echo
    echo "=================================================="
    echo " Server identity and SSL information"
    echo "=================================================="
    echo "The FQDN is required and must already point to this server."
    echo "Example: dialer.example.com"
    echo

    while [[ -z "$FQDN" ]]; do
        read -rp "Enter FQDN: " FQDN
        FQDN="$(echo "$FQDN" | tr '[:upper:]' '[:lower:]' | xargs)"
    done

    while [[ -z "$ADMIN_EMAIL" ]]; do
        read -rp "Enter admin email for Let's Encrypt: " ADMIN_EMAIL
        ADMIN_EMAIL="$(echo "$ADMIN_EMAIL" | xargs)"
    done

    read -rp "Recording retention in days [65]: " RECORDING_RETENTION_DAYS
    RECORDING_RETENTION_DAYS="${RECORDING_RETENTION_DAYS:-65}"

    echo "Setting hostname to $FQDN"
    hostnamectl set-hostname "$FQDN"
}

validate_dns() {
    echo
    echo "=================================================="
    echo " DNS validation"
    echo "=================================================="

    dnf -y install bind-utils curl >/dev/null 2>&1 || true
    PUBLIC_IP="$(get_public_ip)"
    DNS_IPS="$(dig +short A "$FQDN" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"

    echo "FQDN:             $FQDN"
    echo "DNS A record(s):"
    echo "${DNS_IPS:-NONE}"
    echo "Server public IP: ${PUBLIC_IP:-UNKNOWN}"
    echo

    if [[ -z "$PUBLIC_IP" || -z "$DNS_IPS" ]]; then
        echo "ERROR: Could not determine public IP or DNS A record."
        exit 1
    fi

    if ! echo "$DNS_IPS" | grep -Fxq "$PUBLIC_IP"; then
        echo "ERROR: DNS for $FQDN does not resolve to this server's public IP."
        echo "Fix the DNS A record, wait for propagation, then rerun."
        exit 1
    fi

    echo "DNS validation passed."
}

save_install_info_header() {
    MYSQL_ROOT_PASS="$(random_password)"
    VICI_DB_PASS="$(random_password)"
    VICI_CUSTOM_PASS="$(random_password)"
    RANDOM_AUTH="$(random_password)"

    umask 077
    cat > "$INFO_FILE" <<EOF_INFO
GenX VICIdial Express Install
Generated: $(date)

FQDN=$FQDN
ADMIN_EMAIL=$ADMIN_EMAIL
PUBLIC_IP=$PUBLIC_IP
PRIVATE_IP=$(get_primary_private_ip)

MYSQL_ROOT_PASS=$MYSQL_ROOT_PASS
VICIDIAL_DB=asterisk
VICIDIAL_USER=cron
VICIDIAL_PASS=$VICI_DB_PASS
VICIDIAL_CUSTOM_USER=custom
VICIDIAL_CUSTOM_PASS=$VICI_CUSTOM_PASS
RANDOM_AUTH=$RANDOM_AUTH

Log file: $LOG_FILE
EOF_INFO
    chmod 600 "$INFO_FILE"
}

install_repos_and_base_packages() {
    echo
    echo "=================================================="
    echo " Installing repositories and base packages"
    echo "=================================================="

    dnf -y install dnf-plugins-core epel-release yum-utils
    dnf config-manager --set-enabled crb || true

    # Remi provides the requested PHP 8.2 stream on EL9.
    if [[ ! -f /etc/yum.repos.d/remi.repo ]]; then
        dnf -y install https://rpms.remirepo.net/enterprise/remi-release-9.rpm
    fi
    dnf -y module reset php
    dnf -y module enable php:${PHP_STREAM}

    # MariaDB official repo for 10.11. Fallback to distro packages happens later if needed.
    cat > /etc/yum.repos.d/MariaDB.repo <<EOF_MDB
[mariadb]
name = MariaDB
baseurl = https://rpm.mariadb.org/${MARIADB_VERSION}/rhel/9/x86_64
gpgkey = https://rpm.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck = 1
module_hotfixes = 1
EOF_MDB

    dnf -y makecache

    dnf -y groupinstall "Development Tools"
    dnf -y install \
        wget curl git subversion screen tmux nano vim unzip tar rsync patch make gcc gcc-c++ \
        perl perl-CPAN perl-YAML perl-CPAN-DistnameInfo perl-libwww-perl perl-DBI perl-DBD-MySQL \
        perl-GD perl-Env perl-Term-ReadLine-Gnu perl-SelfLoader perl-File-Which perl-ExtUtils-MakeMaker \
        ImageMagick sox sendmail lame-devel htop iftop atop mytop inxi bind-utils \
        kernel-devel-$(uname -r) kernel-headers-$(uname -r) elfutils-libelf-devel \
        newt newt-devel slang-devel ncurses-devel libxml2-devel sqlite-devel libuuid-devel \
        libedit-devel readline-devel speex-devel openssl-devel libsrtp-devel uuid-devel \
        httpd mod_ssl certbot python3-certbot-apache firewalld vsftpd ftp postfix dovecot s-nail \
        python3-pip chkconfig initscripts pv

    dnf -y install \
        php php-cli php-common php-devel php-gd php-curl php-mysqlnd php-ldap php-zip php-fileinfo \
        php-opcache php-imap php-mbstring php-odbc php-pear php-xml php-xmlrpc || true

    pip3 install --upgrade pip || true
    pip3 install mysql-connector-python || true
}

install_mariadb() {
    echo
    echo "=================================================="
    echo " Installing and configuring MariaDB ${MARIADB_VERSION}"
    echo "=================================================="

    dnf -y install MariaDB-server MariaDB-client MariaDB-devel || dnf -y install mariadb-server mariadb mariadb-devel

    systemctl enable mariadb

    cp -n /etc/my.cnf /etc/my.cnf.genx-original 2>/dev/null || true
    if ! grep -q '^!includedir /etc/my.cnf.d' /etc/my.cnf 2>/dev/null; then
        echo '!includedir /etc/my.cnf.d' >> /etc/my.cnf
    fi

    mkdir -p /etc/my.cnf.d
    # Install ViciBox-style split MariaDB configs from Git assets.
    # User decision: keep Alma default data path /var/lib/mysql, not /srv/mysql/data.
    for f in cache-buffers.cnf general.cnf innodb.cnf replication.cnf; do
        if [[ -f "$REPO_ROOT/assets/mariadb/$f" ]]; then
            cp -f "$REPO_ROOT/assets/mariadb/$f" "/etc/my.cnf.d/genx-$f"
            sed -i 's|/srv/mysql/data|/var/lib/mysql|g' "/etc/my.cnf.d/genx-$f"
        fi
    done

    mkdir -p /var/log/mysqld
    touch /var/log/mysqld/slow-queries.log /var/log/mysqld/mysqld.log
    chown -R mysql:mysql /var/log/mysqld || true

    systemctl restart mariadb

    # Secure root for a new install and create /root/.my.cnf for non-interactive admin commands.
    mysql -uroot <<SQL_ROOT || true
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL_ROOT

    cat > /root/.my.cnf <<EOF_MYCNF
[client]
user=root
password=${MYSQL_ROOT_PASS}
EOF_MYCNF
    chmod 600 /root/.my.cnf

    systemctl restart mariadb
}

install_php_httpd() {
    echo
    echo "=================================================="
    echo " Configuring Apache/httpd and PHP 8.2"
    echo "=================================================="

    cat > /etc/php.d/99-vicidial.ini <<'EOF_PHP'
; VICIdial settings installed by GenX installer
error_reporting = E_ALL & ~E_NOTICE
memory_limit = 448M
short_open_tag = On
max_execution_time = 3330
max_input_time = 3360
post_max_size = 448M
upload_max_filesize = 442M
default_socket_timeout = 3360
date.timezone = America/New_York
max_input_vars = 50000
EOF_PHP

    # General recording alias for local playback.
    if ! grep -q '# BEGIN VICIDIAL RECORDINGS ALIAS' /etc/httpd/conf/httpd.conf; then
        cat >> /etc/httpd/conf/httpd.conf <<'EOF_HTTPD'

# BEGIN VICIDIAL RECORDINGS ALIAS
CustomLog /dev/null common
Alias /RECORDINGS/MP3 "/var/spool/asterisk/monitorDONE/MP3/"
<Directory "/var/spool/asterisk/monitorDONE/MP3/">
    Options Indexes MultiViews
    AllowOverride None
    Require all granted
</Directory>
Timeout 600
# END VICIDIAL RECORDINGS ALIAS
EOF_HTTPD
    fi

    # Copy Apache assets if available; sed converts openSUSE apache paths to EL httpd paths.
    if [[ -d "$REPO_ROOT/assets/apache" ]]; then
        for f in "$REPO_ROOT"/assets/apache/*.conf; do
            [[ -f "$f" ]] || continue
            base="$(basename "$f")"
            cp -f "$f" "/etc/httpd/conf.d/genx-$base"
            sed -i 's|/srv/www/vhosts|/var/www/vhosts|g; s|/etc/apache2|/etc/httpd|g; s|apache2|httpd|g' "/etc/httpd/conf.d/genx-$base"
            sed -i "s|DOMAINNAME|$FQDN|g" "/etc/httpd/conf.d/genx-$base"
        done
    fi

    cat > /var/www/html/index.html <<'EOF_INDEX'
<META HTTP-EQUIV=REFRESH CONTENT="1; URL=/vicidial/welcome.php">
Please Hold while I redirect you!
EOF_INDEX

    systemctl enable httpd
    systemctl restart httpd
}

install_lame_jansson_srtp() {
    echo
    echo "=================================================="
    echo " Installing audio/build libraries"
    echo "=================================================="

    mkdir -p "$BUILD_DIR"

    cd "$BUILD_DIR"
    if [[ ! -d lame-3.99.5 ]]; then
        wget -N http://downloads.sourceforge.net/project/lame/lame/3.99/lame-3.99.5.tar.gz
        tar -zxf lame-3.99.5.tar.gz
    fi
    cd lame-3.99.5
    ./configure
    make -j"$(nproc)"
    make install

    cd "$BUILD_DIR"
    if [[ ! -d jansson-2.13 ]]; then
        wget -N https://digip.org/jansson/releases/jansson-2.13.tar.gz
        tar xzf jansson-2.13.tar.gz
    fi
    cd jansson-2.13
    ./configure
    make clean
    make -j"$(nproc)"
    make install
    ldconfig

    cd "$BUILD_DIR"
    if [[ ! -d libsrtp-2.1.0 ]]; then
        wget -N https://github.com/cisco/libsrtp/archive/v2.1.0.tar.gz -O libsrtp-2.1.0.tar.gz
        tar xzf libsrtp-2.1.0.tar.gz
    fi
    cd libsrtp-2.1.0
    ./configure --prefix=/usr --enable-openssl
    make shared_library -j"$(nproc)"
    make install
    ldconfig
}

install_dahdi() {
    echo
    echo "=================================================="
    echo " Installing DAHDI ${DAHDI_VERSION}"
    echo "=================================================="

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    wget -N "https://downloads.asterisk.org/pub/telephony/dahdi-linux-complete/dahdi-linux-complete-${DAHDI_VERSION}.tar.gz"
    rm -rf "dahdi-linux-complete-${DAHDI_VERSION}"
    tar xzf "dahdi-linux-complete-${DAHDI_VERSION}.tar.gz"
    cd "dahdi-linux-complete-${DAHDI_VERSION}"

    # Alma/Rocky 9.5+/9.6+ kernel compatibility patches.
    # These replace the old demo-server dahdi-9.5-fix.zip dependency.
    grep -rl 'DEFINE_SEMAPHORE(' linux/ | xargs -r sed -i 's/DEFINE_SEMAPHORE(\([a-zA-Z0-9_]\+\))/DEFINE_SEMAPHORE(\1, 1)/g'
    grep -rl 'from_timer' linux/drivers/dahdi | xargs -r sed -i 's/from_timer(\([^,]*\), \([^,]*\), \([^)]*\))/timer_container_of(\1, \2, \3)/g'

    sed -i 's|static int astribank_uevent(struct device \*dev, struct kobj_uevent_env \*kenv)|static int astribank_uevent(const struct device *dev, struct kobj_uevent_env *kenv)|' linux/drivers/dahdi/xpp/xbus-sysfs.c || true
    sed -i 's|static int span_uevent(struct device \*dev, struct kobj_uevent_env \*kenv)|static int span_uevent(const struct device *dev, struct kobj_uevent_env *kenv)|' linux/drivers/dahdi/dahdi-sysfs.c || true
    sed -i 's|static int device_uevent(struct device \*dev, struct kobj_uevent_env \*kenv)|static int device_uevent(const struct device *dev, struct kobj_uevent_env *kenv)|' linux/drivers/dahdi/dahdi-sysfs.c || true
    grep -rl "static int .*_match(struct device \*dev, struct device_driver \*driver)" linux/drivers/dahdi | xargs -r sed -i 's|\(static int [a-zA-Z0-9_]*_match(struct device \*dev, \)struct device_driver \*driver)|\1const struct device_driver *driver)|g'
    sed -i 's/class_create(THIS_MODULE, "dahdi")/class_create("dahdi")/' linux/drivers/dahdi/dahdi-sysfs-chan.c || true

    make clean
    make all -j"$(nproc)"
    make install
    make install-config
    ldconfig

    if [[ -d tools ]]; then
        cd tools
        make clean
        make -j"$(nproc)"
        make install
        make install-config
        ldconfig
    fi

    mkdir -p /etc/dahdi
    touch /etc/dahdi/assigned-spans.conf
    [[ -f /etc/dahdi/system.conf.sample ]] && cp -f /etc/dahdi/system.conf.sample /etc/dahdi/system.conf

    modprobe dahdi || true
    modprobe dahdi_dummy || true
    /usr/sbin/dahdi_cfg -vvvvvvvvvvvvv || true

    systemctl enable dahdi || true
    systemctl restart dahdi || service dahdi start || true
}

install_asterisk() {
    echo
    echo "=================================================="
    echo " Installing Asterisk ${ASTERISK_VERSION} from official source"
    echo "=================================================="

    mkdir -p "$BUILD_DIR/asterisk"
    cd "$BUILD_DIR/asterisk"

    wget -N https://downloads.asterisk.org/pub/telephony/libpri/libpri-1.6.1.tar.gz
    rm -rf libpri-1.6.1
    tar xzf libpri-1.6.1.tar.gz
    cd libpri-1.6.1
    make clean || true
    make -j"$(nproc)"
    make install

    cd "$BUILD_DIR/asterisk"
    wget -N "https://downloads.asterisk.org/pub/telephony/asterisk/old-releases/asterisk-${ASTERISK_VERSION}.tar.gz" || \
        wget -N "https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTERISK_VERSION}.tar.gz"
    rm -rf "asterisk-${ASTERISK_VERSION}"
    tar xzf "asterisk-${ASTERISK_VERSION}.tar.gz"
    cd "asterisk-${ASTERISK_VERSION}"

    ./configure --libdir=/usr/lib64 --with-gsm=internal --enable-opus --enable-srtp --with-ssl --enable-asteriskssl --with-pjproject-bundled --with-jansson-bundled
    make menuselect/menuselect menuselect-tree menuselect.makeopts
    menuselect/menuselect --enable app_meetme menuselect.makeopts || true
    menuselect/menuselect --enable res_http_websocket menuselect.makeopts || true
    menuselect/menuselect --enable res_srtp menuselect.makeopts || true
    make samples
    sed -i 's|noload = chan_sip.so|;noload = chan_sip.so|g' /etc/asterisk/modules.conf || true
    make -j"$(( $(nproc) + $(nproc) / 2 ))" all
    make install
    ldconfig

    # VICIdial starts Asterisk through its own boot scripts. Do not enable stock service.
    chkconfig asterisk off 2>/dev/null || true
}

install_vicidial_source_and_db() {
    echo
    echo "=================================================="
    echo " Installing VICIdial source and database"
    echo "=================================================="

    mkdir -p /usr/src/astguiclient
    cd /usr/src/astguiclient
    if [[ -d trunk/.svn ]]; then
        svn update trunk
    else
        rm -rf trunk
        svn checkout "$VICIDIAL_SVN" trunk
    fi

    cd /usr/src/astguiclient/trunk
    SVN_REVISION="$(svn info 2>/dev/null | awk '/^Revision:/ {print $2}')"
    echo "VICIdial SVN revision: ${SVN_REVISION:-unknown}"
    echo "SVN_REVISION=${SVN_REVISION:-unknown}" >> "$INFO_FILE"

    mysql <<SQL_VICI
CREATE DATABASE IF NOT EXISTS asterisk DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci;
CREATE USER IF NOT EXISTS 'cron'@'localhost' IDENTIFIED BY '${VICI_DB_PASS}';
CREATE USER IF NOT EXISTS 'cron'@'%' IDENTIFIED BY '${VICI_DB_PASS}';
GRANT SELECT,CREATE,ALTER,INSERT,UPDATE,DELETE,LOCK TABLES ON asterisk.* TO 'cron'@'localhost';
GRANT SELECT,CREATE,ALTER,INSERT,UPDATE,DELETE,LOCK TABLES ON asterisk.* TO 'cron'@'%';
GRANT RELOAD ON *.* TO 'cron'@'localhost';
GRANT RELOAD ON *.* TO 'cron'@'%';
CREATE USER IF NOT EXISTS 'custom'@'localhost' IDENTIFIED BY '${VICI_CUSTOM_PASS}';
CREATE USER IF NOT EXISTS 'custom'@'%' IDENTIFIED BY '${VICI_CUSTOM_PASS}';
GRANT SELECT,CREATE,ALTER,INSERT,UPDATE,DELETE,LOCK TABLES ON asterisk.* TO 'custom'@'localhost';
GRANT SELECT,CREATE,ALTER,INSERT,UPDATE,DELETE,LOCK TABLES ON asterisk.* TO 'custom'@'%';
GRANT RELOAD ON *.* TO 'custom'@'localhost';
GRANT RELOAD ON *.* TO 'custom'@'%';
FLUSH PRIVILEGES;
SET GLOBAL connect_timeout=60;
SQL_VICI

    mysql asterisk < /usr/src/astguiclient/trunk/extras/MySQL_AST_CREATE_tables.sql
    mysql asterisk < /usr/src/astguiclient/trunk/extras/first_server_install.sql

    local ip_address
    ip_address="$(get_primary_private_ip)"

    cat > /etc/astguiclient.conf <<EOF_ASTGUI
# astguiclient.conf - generated by GenX VICIdial installer
PATHhome => /usr/share/astguiclient
PATHlogs => /var/log/astguiclient
PATHagi => /var/lib/asterisk/agi-bin
PATHweb => /var/www/html
PATHsounds => /var/lib/asterisk/sounds
PATHmonitor => /var/spool/asterisk/monitor
PATHDONEmonitor => /var/spool/asterisk/monitorDONE
VARserver_ip => ${ip_address}
VARDB_server => localhost
VARDB_database => asterisk
VARDB_user => cron
VARDB_pass => ${VICI_DB_PASS}
VARDB_custom_user => custom
VARDB_custom_pass => ${VICI_CUSTOM_PASS}
VARDB_port => 3306
VARactive_keepalives => 123456789ECS
VARasterisk_version => 18.X
VARFTP_host => ${ip_address}
VARFTP_user => cronarchive
VARFTP_pass => ${VICI_DB_PASS}
VARFTP_port => 21
VARFTP_dir => RECORDINGS
VARHTTP_path => https://${FQDN}
VARREPORT_host => ${ip_address}
VARREPORT_user => cronarchive
VARREPORT_pass => ${VICI_DB_PASS}
VARREPORT_port => 21
VARREPORT_dir => REPORTS
VARfastagi_log_min_servers => 3
VARfastagi_log_max_servers => 16
VARfastagi_log_min_spare_servers => 2
VARfastagi_log_max_spare_servers => 8
VARfastagi_log_max_requests => 1000
VARfastagi_log_checkfordead => 30
VARfastagi_log_checkforwait => 60
ExpectedDBSchema => 1720
EOF_ASTGUI

    perl install.pl --web=/var/www/html --asterisk_version=18 --copy_sample_conf_files --no-prompt --server_ip="$ip_address" \
        --DB_database=asterisk --DB_user=cron --DB_pass="$VICI_DB_PASS" \
        --DB_custom_user=custom --DB_custom_pass="$VICI_CUSTOM_PASS" --DB_port=3306

    perl install.pl --no-prompt || true

    # Secure Asterisk Manager to localhost.
    sed -i 's/0.0.0.0/127.0.0.1/g' /etc/asterisk/manager.conf || true

    # Create ViciBox-compatible provisioning table for future cluster roles.
    mysql asterisk <<SQL_VBOX
CREATE TABLE IF NOT EXISTS vicibox (
  server_id tinyint(3) unsigned NOT NULL AUTO_INCREMENT,
  server varchar(32) NOT NULL,
  server_ip varchar(32) NOT NULL,
  server_type enum('Database','Web','Telephony','Archive') NOT NULL DEFAULT 'Telephony',
  field1 varchar(64) DEFAULT NULL,
  field2 varchar(64) DEFAULT NULL,
  field3 varchar(64) DEFAULT NULL,
  field4 varchar(64) DEFAULT NULL,
  field5 varchar(64) DEFAULT NULL,
  field6 varchar(64) DEFAULT NULL,
  field7 varchar(64) DEFAULT NULL,
  field8 varchar(64) DEFAULT NULL,
  field9 varchar(64) DEFAULT NULL,
  PRIMARY KEY (server_id)
) ENGINE=MyISAM DEFAULT CHARSET=latin1;
DELETE FROM vicibox WHERE server='${FQDN}' OR server_ip='${ip_address}';
INSERT INTO vicibox (server, server_ip, server_type, field1, field2, field3, field4, field5, field6, field7, field8, field9)
VALUES ('${FQDN}', '${ip_address}', 'Database', '1', 'asterisk', '${SVN_REVISION:-unknown}', 'cron', '${VICI_DB_PASS}', 'custom', '${VICI_CUSTOM_PASS}', 'repl', 'AUTO_GENERATE_LATER');
INSERT INTO vicibox (server, server_ip, server_type, field1, field2)
VALUES ('${FQDN}', '${ip_address}', 'Web', '${PUBLIC_IP}', '${RANDOM_AUTH}');
INSERT INTO vicibox (server, server_ip, server_type, field1)
VALUES ('${FQDN}', '${ip_address}', 'Telephony', '${PUBLIC_IP}');
UPDATE servers SET server_description='Server ${FQDN}', asterisk_version='${ASTERISK_VERSION}', conf_secret='${RANDOM_AUTH}', vicidial_balance_active='Y', auto_restart_asterisk='Y', recording_web_link='ALT_IP', alt_server_ip='${FQDN}', conf_engine='CONFBRIDGE' WHERE server_ip='${ip_address}';
UPDATE system_settings SET active_voicemail_server='${ip_address}', webphone_url='https://phone.viciphone.com/viciphone.php', sounds_web_server='https://${FQDN}';
SQL_VBOX
}

install_confbridge_records() {
    echo
    echo "=================================================="
    echo " Installing ConfBridge records"
    echo "=================================================="

    local ip_address
    ip_address="$(get_primary_private_ip)"

    mysql asterisk -e "DELETE FROM vicidial_confbridges WHERE conf_exten BETWEEN 9600000 AND 9600299;"
    for i in $(seq 0 299); do
        local ext=$((9600000 + i))
        mysql asterisk -e "INSERT INTO vicidial_confbridges VALUES (${ext},'${ip_address}','','0',NULL);" || true
    done

    if [[ -f "$REPO_ROOT/templates/confbridge-vicidial.conf" ]]; then
        cp -f "$REPO_ROOT/templates/confbridge-vicidial.conf" /etc/asterisk/confbridge-vicidial.conf
        grep -q '^#include confbridge-vicidial.conf' /etc/asterisk/confbridge.conf || echo '#include confbridge-vicidial.conf' >> /etc/asterisk/confbridge.conf
    fi
}

install_cron_and_boot() {
    echo
    echo "=================================================="
    echo " Installing cron and boot startup"
    echo "=================================================="

    local cron_file="/root/crontab-file"
    local cron_assets="$REPO_ROOT/assets/vicibox/cron"

    if [[ -f "$cron_assets/allcron" && -f "$cron_assets/dbcron" && -f "$cron_assets/dialcron" ]]; then
        cat "$cron_assets/allcron" "$cron_assets/dbcron" "$cron_assets/dialcron" > "$cron_file"
    else
        cat > "$cron_file" <<EOF_CRON
### keepalive script for astguiclient processes
* * * * * /usr/share/astguiclient/ADMIN_keepalive_ALL.pl --cu3way
### database optimization and backups
0 2 * * * /usr/share/astguiclient/ADMIN_backup.pl
3 1 * * * /usr/share/astguiclient/AST_DB_optimize.pl
### audio processing
0,3,6,9,12,15,18,21,24,27,30,33,36,39,42,45,48,51,54,57 * * * * /usr/share/astguiclient/AST_CRON_audio_1_move_mix.pl --MIX
1,4,7,10,13,16,19,22,25,28,31,34,37,40,43,46,49,52,55,58 * * * * /usr/share/astguiclient/AST_CRON_audio_2_compress.pl --MP3 --HTTPS
EOF_CRON
    fi

    cat >> "$cron_file" <<EOF_GENX

### GenX retention cleanup
15 2 * * * /usr/bin/find /var/spool/asterisk/monitorDONE/MP3 -type f -mtime +${RECORDING_RETENTION_DAYS} -delete
20 2 * * * /usr/bin/find /var/spool/asterisk/monitorDONE/ORIG -type f -mtime +1 -delete
25 2 * * * /usr/bin/find /var/lib/mysql -maxdepth 1 -name '*.sql.gz' -mtime +7 -delete

### Dynportal / VB Firewall
@reboot /usr/bin/VB-firewall --whitelist=ViciWhite --dynamic --quiet
* * * * * /usr/bin/VB-firewall --whitelist=ViciWhite --dynamic --quiet
* * * * * sleep 10; /usr/bin/VB-firewall --white --dynamic --quiet
* * * * * sleep 20; /usr/bin/VB-firewall --white --dynamic --quiet
* * * * * sleep 30; /usr/bin/VB-firewall --white --dynamic --quiet
* * * * * sleep 40; /usr/bin/VB-firewall --white --dynamic --quiet
* * * * * sleep 50; /usr/bin/VB-firewall --white --dynamic --quiet
EOF_GENX

    crontab "$cron_file"

    cat > /etc/rc.d/rc.local <<'EOF_RC'
#!/bin/bash
/usr/share/astguiclient/ip_relay/relay_control start 2>/dev/null 1>&2 || true
/usr/bin/setterm -blank 2>/dev/null || true
/usr/bin/setterm -powersave off 2>/dev/null || true
/usr/bin/setterm -powerdown 2>/dev/null || true
systemctl start mariadb.service || true
systemctl start httpd.service || true
/usr/share/astguiclient/ADMIN_restart_roll_logs.pl || true
/usr/share/astguiclient/AST_reset_mysql_vars.pl || true
modprobe dahdi || true
modprobe dahdi_dummy || true
/usr/sbin/dahdi_cfg -vvvvvvvvvvvvv || true
sleep 20
/usr/share/astguiclient/start_asterisk_boot.pl || true
exit 0
EOF_RC
    chmod +x /etc/rc.d/rc.local

    cat > /etc/systemd/system/rc-local.service <<'EOF_SERVICE'
[Unit]
Description=/etc/rc.local Compatibility
ConditionPathExists=/etc/rc.d/rc.local

[Service]
Type=oneshot
ExecStart=/etc/rc.d/rc.local
TimeoutSec=0
StandardInput=tty
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE

    systemctl daemon-reload
    systemctl enable rc-local.service
}

install_dynportal_firewall() {
    echo
    echo "=================================================="
    echo " Installing dynportal and VB-firewall"
    echo "=================================================="

    mkdir -p /var/www/vhosts/dynportal
    cp -a "$REPO_ROOT/assets/dynportal/." /var/www/vhosts/dynportal/
    chown -R apache:apache /var/www/vhosts/dynportal
    find /var/www/vhosts/dynportal -type d -exec chmod 755 {} \;
    find /var/www/vhosts/dynportal -type f -exec chmod 644 {} \;

    if [[ -f /var/www/vhosts/dynportal/inc/defaults.inc.php ]]; then
        sed -i "s|DOMAINNAME|$FQDN|g" /var/www/vhosts/dynportal/inc/defaults.inc.php || true
    fi

    mkdir -p /usr/share/vicibox-firewall
    cp -a "$REPO_ROOT/assets/firewall/." /usr/share/vicibox-firewall/

    # Install firewall helper command. Support either VB-firewall.pl or VB-firewall asset names.
    if [[ -f /usr/share/vicibox-firewall/VB-firewall.pl ]]; then
        install -m 755 /usr/share/vicibox-firewall/VB-firewall.pl /usr/bin/VB-firewall
    elif [[ -f /usr/share/vicibox-firewall/VB-firewall ]]; then
        install -m 755 /usr/share/vicibox-firewall/VB-firewall /usr/bin/VB-firewall
    fi

    [[ -f /usr/share/vicibox-firewall/ipset-geoblock ]] && install -m 755 /usr/share/vicibox-firewall/ipset-geoblock /usr/bin/ipset-geoblock || true
    [[ -f /usr/share/vicibox-firewall/vicibox-geoblock.conf ]] && cp -f /usr/share/vicibox-firewall/vicibox-geoblock.conf /etc/vicibox-geoblock.conf || true

    systemctl enable firewalld
    systemctl start firewalld

    firewall-cmd --permanent --add-service=http || true
    firewall-cmd --permanent --add-service=https || true
    firewall-cmd --permanent --add-port=446/tcp || true
    firewall-cmd --permanent --add-port=5060/udp || true
    firewall-cmd --permanent --add-port=5061/tcp || true
    firewall-cmd --permanent --add-port=8088/tcp || true
    firewall-cmd --permanent --add-port=8089/tcp || true
    firewall-cmd --permanent --add-port=10000-20000/udp || true
    firewall-cmd --reload || true
}

configure_ssl_webrtc() {
    echo
    echo "=================================================="
    echo " Configuring Let's Encrypt SSL and WebRTC"
    echo "=================================================="

    systemctl restart httpd

    certbot --apache -d "$FQDN" -m "$ADMIN_EMAIL" --agree-tos --non-interactive --redirect
    systemctl enable certbot-renew.timer || true
    systemctl start certbot-renew.timer || true

    cat > /etc/asterisk/http.conf <<EOF_AHTTP
[general]
enabled=yes
bindaddr=0.0.0.0
bindport=8088
tlsenable=yes
tlsbindaddr=0.0.0.0:8089
tlscertfile=/etc/letsencrypt/live/${FQDN}/fullchain.pem
tlsprivatekey=/etc/letsencrypt/live/${FQDN}/privkey.pem
EOF_AHTTP

    # Template used for WebRTC phones. Includes context=default fix.
    mysql asterisk <<SQL_WEBRTC
UPDATE servers SET web_socket_url='wss://${FQDN}:8089/ws';
UPDATE system_settings SET webphone_url='https://phone.viciphone.com/viciphone.php';
INSERT INTO vicidial_conf_templates (template_id, template_name, template_contents, user_group)
VALUES ('SIP_generic', 'SIP_generic WebRTC', 'type=friend\nhost=dynamic\ncontext=default\ntrustrpid=yes\nsendrpid=no\nqualify=yes\nqualifyfreq=600\ntransport=ws,wss,udp\nencryption=yes\navpf=yes\nicesupport=yes\nrtcp_mux=yes\ndirectmedia=no\ndisallow=all\nallow=ulaw,opus,vp8,h264\nnat=yes\ndtlsenable=yes\ndtlsverify=no\ndtlscertfile=/etc/letsencrypt/live/${FQDN}/cert.pem\ndtlsprivatekey=/etc/letsencrypt/live/${FQDN}/privkey.pem\ndtlssetup=actpass', '---ALL---')
ON DUPLICATE KEY UPDATE template_contents=VALUES(template_contents);
ALTER TABLE phones MODIFY COLUMN is_webphone ENUM('Y','N','Y_API_LAUNCH') DEFAULT 'Y';
UPDATE phones SET template_id='SIP_generic';
SQL_WEBRTC

    # Add confcron AMI user if missing.
    if ! grep -q '^\[confcron\]' /etc/asterisk/manager.conf; then
        cat >> /etc/asterisk/manager.conf <<'EOF_CONFCron'

[confcron]
secret = 1234
read = command,reporting
write = command,reporting
eventfilter=Event: Meetme
eventfilter=Event: Confbridge
EOF_CONFCron
    fi

    rasterisk -x reload || true
}

install_sounds_and_codecs() {
    echo
    echo "=================================================="
    echo " Installing Asterisk sounds and optional codec"
    echo "=================================================="

    mkdir -p /var/lib/asterisk/sounds /var/lib/asterisk/mohmp3 /var/lib/asterisk/quiet-mp3
    cd "$BUILD_DIR"
    for f in \
        asterisk-core-sounds-en-ulaw-current.tar.gz \
        asterisk-core-sounds-en-wav-current.tar.gz \
        asterisk-core-sounds-en-gsm-current.tar.gz \
        asterisk-extra-sounds-en-ulaw-current.tar.gz \
        asterisk-extra-sounds-en-wav-current.tar.gz \
        asterisk-extra-sounds-en-gsm-current.tar.gz \
        asterisk-moh-opsound-gsm-current.tar.gz \
        asterisk-moh-opsound-ulaw-current.tar.gz \
        asterisk-moh-opsound-wav-current.tar.gz; do
        wget -N "http://downloads.asterisk.org/pub/telephony/sounds/$f"
    done

    cd /var/lib/asterisk/sounds
    tar -zxf "$BUILD_DIR"/asterisk-core-sounds-en-gsm-current.tar.gz
    tar -zxf "$BUILD_DIR"/asterisk-core-sounds-en-ulaw-current.tar.gz
    tar -zxf "$BUILD_DIR"/asterisk-core-sounds-en-wav-current.tar.gz
    tar -zxf "$BUILD_DIR"/asterisk-extra-sounds-en-gsm-current.tar.gz
    tar -zxf "$BUILD_DIR"/asterisk-extra-sounds-en-ulaw-current.tar.gz
    tar -zxf "$BUILD_DIR"/asterisk-extra-sounds-en-wav-current.tar.gz
    rm -f CHANGES* LICENSE* CREDITS*

    cd /var/lib/asterisk/mohmp3
    tar -zxf "$BUILD_DIR"/asterisk-moh-opsound-gsm-current.tar.gz
    tar -zxf "$BUILD_DIR"/asterisk-moh-opsound-ulaw-current.tar.gz
    tar -zxf "$BUILD_DIR"/asterisk-moh-opsound-wav-current.tar.gz
    rm -f CHANGES* LICENSE* CREDITS*

    ln -sfn /var/lib/asterisk/mohmp3 /var/lib/asterisk/default

    # Optional G729 binary from public asterisk.hosting.lv, same source family as existing script.
    # If it fails, the install continues without G729.
    cd /usr/lib64/asterisk/modules || true
    if [[ -d /usr/lib64/asterisk/modules ]]; then
        wget -N http://asterisk.hosting.lv/bin/codec_g729-ast160-gcc4-glibc-x86_64-core2-sse4.so || true
        [[ -f codec_g729-ast160-gcc4-glibc-x86_64-core2-sse4.so ]] && mv -f codec_g729-ast160-gcc4-glibc-x86_64-core2-sse4.so codec_g729.so && chmod 755 codec_g729.so || true
    fi
}

fix_permissions_and_limits() {
    echo
    echo "=================================================="
    echo " Applying permissions and service limits"
    echo "=================================================="

    grep -q '^DefaultLimitNOFILE=65536' /etc/systemd/system.conf || echo 'DefaultLimitNOFILE=65536' >> /etc/systemd/system.conf
    systemctl daemon-reload

    mkdir -p /var/spool/asterisk/monitorDONE/MP3 /var/spool/asterisk/monitorDONE/ORIG
    chown -R apache:apache /var/spool/asterisk || true
    find /var/spool/asterisk -type d -exec chmod 775 {} \; || true
    find /var/spool/asterisk -type f -exec chmod 664 {} \; || true

    dnf -y remove kernel-debug* || true
}

main() {
    require_root
    require_el9
    require_repo_assets

    echo "=================================================="
    echo " GenX VICIdial Express Installer"
    echo " Log: $LOG_FILE"
    echo "=================================================="

    prompt_server_info
    validate_dns
    save_install_info_header

    install_repos_and_base_packages
    install_mariadb
    install_php_httpd
    install_lame_jansson_srtp
    install_dahdi
    install_asterisk
    install_vicidial_source_and_db
    install_confbridge_records
    install_sounds_and_codecs
    install_dynportal_firewall
    install_cron_and_boot
    configure_ssl_webrtc
    fix_permissions_and_limits

    echo
    echo "=================================================="
    echo " Express install complete"
    echo "=================================================="
    echo "Credentials saved to: $INFO_FILE"
    echo "Log saved to:         $LOG_FILE"
    echo
    read -rp "Reboot now? [Y/n]: " REBOOT_NOW
    REBOOT_NOW="${REBOOT_NOW:-Y}"
    if [[ "$REBOOT_NOW" =~ ^[Yy]$ ]]; then
        reboot
    fi
}

main "$@"

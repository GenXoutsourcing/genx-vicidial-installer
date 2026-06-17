#!/bin/bash

# Web server fix-up script
# $1 = 0 for no redirect, 1 for redirect
# $2 = 0 for no phpMyAdmin, 1 for phpMyAdmin
# $3 = database IP for phpMyAdmin, ignored if php isn't flagged

# If enabled, copy our URL redirector
if [ "$1" == "1" ]; then
    /bin/cp /usr/share/vicibox/index.html /srv/www/htdocs/index.html
fi

# Get the correct timezone string
TIMEZONERAW="$(cut -d':' -f2 <<<`timedatectl | grep 'Time zone'` | tr -d '[:space:]')"
#echo "Time Zone Raw: $TIMEZONERAW"
TIMEZONE="$(cut -d'(' -f1 <<<$TIMEZONERAW)"

# And make changes to php and /etc/sysconfig/clock
if [ -d /etc/php7 ]; then
    if [ -e /etc/php7/apache2/php.ini ]; then
        sed -i "/date.timezone = /c\date.timezone = '$TIMEZONE'" /etc/php7/apache2/php.ini
    fi
    if [ -e /etc/php7/cli/php.ini ]; then
        sed -i "/date.timezone = /c\date.timezone = '$TIMEZONE'" /etc/php7/cli/php.ini
    fi
else
    if [ -e /etc/php8/apache2/php.ini]; then
        sed -i "/date.timezone = /c\date.timezone = '$TIMEZONE'" /etc/php8/apache2/php.ini
    fi
    if [ -e /etc/php8/cli/php.ini ]; then
        sed -i "/date.timezone = /c\date.timezone = '$TIMEZONE'" /etc/php8/cli/php.ini
    fi
fi

echo "DEFAULT_TIMEZONE=\"$TIMEZONE\"" > /etc/sysconfig/clock

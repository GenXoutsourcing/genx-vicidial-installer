#!/bin/bash
echo "--- Configuring chan_sip as primary, PJSIP as secondary ---"

# Check if config files exist
for config in "/etc/asterisk/sip.conf" "/etc/asterisk/pjsip.conf"; do
    if [ ! -f "$config" ]; then
        echo "Error: $config not found"
        exit 1
    fi
done

# Configure chan_sip for port 5060
sed -i 's/^websocket_enabled[[:space:]]*=[[:space:]]*.*$/websocket_enabled=yes/' /etc/asterisk/sip.conf
sed -i 's/^bindport[[:space:]]*=[[:space:]]*5061$/bindport=5060/' /etc/asterisk/sip.conf

# Configure PJSIP for port 5061
sed -i 's/^bind[[:space:]]*=[[:space:]]*[0-9.]*:[0-9]*/bind = 0.0.0.0:5061/' /etc/asterisk/pjsip.conf

echo -e "\nConfiguration complete. Please restart Asterisk to apply changes:"
echo "   asterisk -rx 'core restart now'"
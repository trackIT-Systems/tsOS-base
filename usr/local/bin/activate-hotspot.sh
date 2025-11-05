#!/bin/bash

# Exit on error, unset variables, and pipefail
set -u -o pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Wait up to 30 seconds for wlan0 and retry hotspot activation
for i in $(seq 30); do
    if nmcli device status | grep -q "wlan0"; then
        CONNECTION=$(nmcli -t -f DEVICE,CONNECTION device status | grep "^wlan0:" | cut -d: -f2 || echo "")
        
        if [[ "$CONNECTION" == "hotspot" ]]; then
            echo "wlan0 is connected to hotspot"
            exit 0
        fi
        
        # Try to activate hotspot
        if nmcli connection up hotspot; then
            echo "Hotspot activated successfully"
            exit 0
        fi
    fi
    sleep 1
done

# Final check after timeout
CONNECTION=$(nmcli -t -f DEVICE,CONNECTION device status | grep "^wlan0:" | cut -d: -f2 || echo "")
if [[ "$CONNECTION" == "hotspot" ]]; then
    echo "wlan0 is connected to hotspot"
    exit 0
fi

echo "Failed to activate hotspot after 30 seconds"
exit 1


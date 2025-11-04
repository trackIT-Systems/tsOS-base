#!/bin/bash

# Exit on error, unset variables, and pipefail
set -eu -o pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Wait up to 30 seconds for wlan0 to become available
for i in $(seq 30); do
    if nmcli device status | grep -q "wlan0"; then
        echo "wlan0 device detected"
        break
    fi
    sleep 1
done

# Check if wlan0 is connected to hotspot
CONNECTION=$(nmcli -t -f DEVICE,CONNECTION device status | grep "^wlan0:" | cut -d: -f2)

if [[ "$CONNECTION" != "hotspot" ]]; then
    echo "wlan0 is not connected to hotspot (current: ${CONNECTION:-none}). Activating hotspot..."
    nmcli connection up hotspot
else
    echo "wlan0 is already connected to hotspot"
fi

exit 0


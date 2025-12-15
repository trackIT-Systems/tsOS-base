#!/bin/bash

set -e

# Script to check if repartition was successful and remove the boot parameter
# Checks:
# 1. Partition table is MBR (msdos)
# 2. Partition count is 4-6 (depending on device size and extended partition visibility)

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root"
    exit 1
fi

CMDLINE_FILE="/boot/firmware/cmdline.txt"

# Detect the root device from /proc/cmdline
get_root_device() {
    local root_param=$(grep -o 'root=[^ ]*' /proc/cmdline | cut -d= -f2)
    
    if [ -z "$root_param" ]; then
        echo "Could not find root device in /proc/cmdline"
        return 1
    fi
    
    # Extract base device name (e.g., /dev/mmcblk0p2 -> /dev/mmcblk0)
    # Handle both mmcblk (with 'p') and sd* (without 'p') devices
    if [[ "$root_param" =~ mmcblk[0-9]+p[0-9]+ ]]; then
        # MMC device: /dev/mmcblk0p2 -> /dev/mmcblk0
        echo "$root_param" | sed 's/p[0-9]*$//'
    else
        # SD device: /dev/sda2 -> /dev/sda
        echo "$root_param" | sed 's/[0-9]*$//'
    fi
}

# Check if partition table is MBR (msdos)
check_mbr() {
    local device="$1"
    
    if [ ! -b "$device" ]; then
        echo "Device $device does not exist"
        return 1
    fi
    
    # Use parted to check partition table type
    local pt_type=$(parted -m "$device" print 2>/dev/null | sed -n '2p' | cut -d: -f6)
    
    if [ "$pt_type" = "msdos" ]; then
        echo "Partition table is MBR (msdos)"
        return 0
    else
        echo "Partition table is not MBR (found: $pt_type)"
        return 1
    fi
}

# Count partitions on the device
count_partitions() {
    local device="$1"
    
    # Extract device name without /dev/ prefix for pattern matching
    local device_name=$(basename "$device")
    
    # Count partitions using lsblk, matching the repartition script's approach
    # Filter for partitions matching the device name pattern (e.g., mmcblk0p1, sda1)
    local count=$(lsblk -n -o kname "$device" | grep -E "^${device_name}p?[0-9]+$" | wc -l)
    echo "$count"
}

# Remove repartition parameter from cmdline.txt
remove_repartition_parameter() {
    if [ ! -f "$CMDLINE_FILE" ]; then
        echo "Cmdline file not found: $CMDLINE_FILE"
        return 1
    fi
    
    # Check if repartition parameter exists
    if ! grep -q '\brepartition\b' "$CMDLINE_FILE"; then
        echo "Repartition parameter not found in cmdline.txt"
        return 0
    fi
    
    # Remove the repartition parameter (word boundary, with trailing space if present)
    sed -i 's/\brepartition\b *//' "$CMDLINE_FILE"
    
    echo "Removed repartition parameter from $CMDLINE_FILE"
    return 0
}

# Main execution
main() {
    echo "Checking repartition completion status"
    
    # Get root device
    ROOT_DEVICE=$(get_root_device)
    if [ $? -ne 0 ] || [ -z "$ROOT_DEVICE" ]; then
        echo "Failed to detect root device"
        exit 1  # Error condition - keep service enabled for retry
    fi
    
    echo "Root device: $ROOT_DEVICE"
    
    # Check if partition table is MBR
    if ! check_mbr "$ROOT_DEVICE"; then
        echo "Repartition not complete (not MBR), keeping boot parameter"
        exit 1  # Repartition not complete - keep service enabled for next boot
    fi
    
    # Count partitions
    PART_COUNT=$(count_partitions "$ROOT_DEVICE")
    echo "Partition count: $PART_COUNT"
    
    # Verify partition count is 4-6
    # Expected: at least 4 partitions (1,2,3,5) for devices <= 16GiB
    #           at least 5 partitions (1,2,3,5,6) for devices > 16GiB
    # Extended partition (4) may not show in lsblk
    if [ "$PART_COUNT" -lt 4 ] || [ "$PART_COUNT" -gt 6 ]; then
        echo "Unexpected partition count: $PART_COUNT (expected 4-6)"
        echo "Repartition may not be complete, keeping boot parameter"
        exit 1  # Repartition not complete - keep service enabled for next boot
    fi
    
    # All checks passed, remove the boot parameter
    echo "Repartition verification successful (MBR with $PART_COUNT partitions)"
    if ! remove_repartition_parameter; then
        echo "Failed to remove repartition parameter"
        exit 1  # Error removing parameter - keep service enabled for retry
    fi
    
    echo "Repartition cleanup completed successfully"
    exit 0  # Success - service will disable itself
}

main

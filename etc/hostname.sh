#!/usr/bin/env bash

set -eu -o pipefail

echo "Running Raspberry Pi cmdline.txt configuration script..." 1>&2

# Initialize parameters
SERIAL=$(cat /proc/cpuinfo | grep Serial | cut -d ' ' -f 2 | cut -c9-16)
source /etc/os-release
if [ "$SERIAL" == "" ]; then
    HOSTNAME=$ID-$VARIANT_ID-unknown
    echo "Error reading Raspberry Pi serial number, defaulting to $HOSTNAME" 1>&2
else
    HOSTNAME=$ID-$VARIANT_ID-$SERIAL
fi

TIMEZONE=$(cat /etc/timezone)

function set_hostname() {
    echo " Setting hostname via hostnamectl: $1." 1>&2
    hostnamectl set-hostname $1

    echo " Setting hostname in /etc/hosts" 1>&2
    cat >/etc/hosts <<EOF
127.0.0.1       localhost
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters

127.0.1.1       $1
EOF

    BOOTFS_HOSTS="/boot/firmware/hosts"
    if [ -f "$BOOTFS_HOSTS" ]; then
        echo " Appending $BOOTFS_HOSTS" 1>&2
        test -f $BOOTFS_HOSTS && cat $BOOTFS_HOSTS >>/etc/hosts
    fi

    echo " Restarting avahi-daemon" 1>&2
    systemctl restart avahi-daemon.service
}

function set_hotspot_ssid() {
    local netplan_file="/etc/netplan/90-NM-c0ffee00-a000-4000-8000-000000000001.yaml"
    local nm_file="/etc/NetworkManager/system-connections/hotspot.nmconnection"
    
    if [ -f "$netplan_file" ]; then
        echo " Setting hotspot SSID via sed in netplan: $1." 1>&2
        sed -i '/access-points:/{n; s/^\([[:space:]]*\)[^:[:space:]]*\(:\)/\1'"$1"'\2/;}' "$netplan_file"
    elif [ -f "$nm_file" ]; then
        echo " Setting hotspot SSID via sed in NetworkManager: $1." 1>&2
        sed -i '/^ssid=/ s/=.*/='"$1"'/' "$nm_file"
    else
        echo "Error: Neither netplan config ($netplan_file) nor NetworkManager config ($nm_file) exists." 1>&2
        exit 1
    fi
}

function set_timezone() {
    echo " Setting timezone via timedatectl: $1." 1>&2
    timedatectl set-timezone $1

    echo " Updating tzdata /etc/timezone" 1>&2
    dpkg-reconfigure -f noninteractive tzdata
}

echo "Scanning kernel commandline for configuration parameters" 1>&2
CMDLINE=($(cat /proc/cmdline))
for arg in "${CMDLINE[@]}"; do
    case "${arg}" in
    systemd.hostname=tsos-default-name)
        echo "... ignoring '${arg}' (default)" 1>&2
        ;;
    systemd.hostname=*)
        HOSTNAME="${arg#systemd.hostname=}"
        echo "... found '${arg}'" 1>&2
        ;;
    timezone=*)
        TIMEZONE="${arg#timezone=}"
        echo "... found '${arg}'" 1>&2
        ;;
    esac
done

set_hostname $HOSTNAME
set_hotspot_ssid $HOSTNAME
set_timezone $TIMEZONE

echo "Done." 1>&2

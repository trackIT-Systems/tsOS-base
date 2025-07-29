#!/usr/bin/env bash

set -eu -o pipefail

echo "Running Raspberry Pi cmdline.txt configuration script..." 1>&2

# Initialize parameters
source /etc/os-release
ID=$(cat /proc/cpuinfo | grep Serial | cut -d ' ' -f 2 | cut -c9-16)
if [ "$ID" == "" ]; then
    HOSTNAME=$NAME-unknown
    echo "Error reading Raspberry Pi serial number, defaulting to $HOSTNAME" 1>&2
else
    HOSTNAME=$NAME-$ID
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
set_timezone $TIMEZONE

echo "Done." 1>&2

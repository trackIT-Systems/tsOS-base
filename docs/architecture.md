# Architecture

## Base System

Built on Raspberry Pi OS Lite (Debian Trixie) using [pimod](https://github.com/Nature40/pimod) to modify the base image.

## Filesystem Layout

### Partition Structure

The system uses GPT partition table (converted from MBR on first boot via initramfs hook). Partition layout:

1. **bootfs** (Partition 1)
   - Type: EFI System Partition (EF00)
   - Filesystem: VFAT
   - Mount: `/boot/firmware` (read-write)
   - Bind mount: `/media/boot` (user access)
   - Contains: Kernel, initramfs, device tree, runtime configs

2. **rootfs** (Partition 2)
   - Type: Linux filesystem (8300)
   - Filesystem: ext4
   - Mount: `/` (read-only base)
   - Size: 6 GiB (fixed)
   - Base OS filesystem, protected by overlayroot

3. **clonefs** (Partition 3)
   - Type: Linux filesystem (8300)
   - Filesystem: ext4, label `clonefs`
   - Mount: `/media/clonefs`
   - Size: 6 GiB (matches rootfs)
   - Reserved for cloning/backup operations

4. **upperfs** (Partition 4)
   - Type: Linux filesystem (8300)
   - Filesystem: ext4, label `upperfs`
   - Mount: Used by overlayroot
   - Size: Up to 16 GiB boundary
   - Stores overlay changes (persistent across reboots)

5. **datafs** (Partition 5, optional)
   - Type: Microsoft basic data (0700)
   - Filesystem: ExFAT, label `datafs`
   - Mount: `/media/datafs` → `/data` (bind mount)
   - Size: Remaining space (if device > 16 GiB)
   - User data storage, accessible from other OS

### Overlayroot Configuration

Root filesystem is read-only via `overlayroot`:

- **Base layer**: `/` (rootfs partition, read-only)
- **Upper layer**: `LABEL=upperfs` partition (persistent overlay)
- **Configuration**: `/etc/overlayroot.local.conf`
  ```
  overlayroot="device:dev=LABEL=upperfs,recurse=0"
  ```

Runtime changes are written to upperfs overlay and persist across reboots. Base rootfs remains unchanged.

### Mount Points (`/etc/fstab`)

```
proc                    /proc               proc    defaults                                0 0
LABEL=bootfs            /boot/firmware      vfat    defaults,user,umask=000,fmask=111       0 2
/dev/root               /                   ext4    defaults,noatime                        0 1
LABEL=datafs            /media/datafs       exfat   defaults,user,umask=000,fmask=111,nofail,x-systemd.device-timeout=5  0 2

# Bind mounts for user access
/boot/firmware          /media/boot         none    defaults,bind,x-mount.mkdir             0 0
/media/datafs           /data               none    defaults,bind,nofail                    0 0
```

### Repartitioning

On first boot with `repartition` kernel parameter:
- Converts MBR → GPT partition table
- Resizes rootfs to 6 GiB
- Creates clonefs, upperfs, and datafs partitions
- Formats new partitions (ext4 for clonefs/upperfs, ExFAT for datafs)
- `repartition-cleanup.service` removes boot parameter after completion

### Filesystem Characteristics

- **Root**: Read-only ext4 with overlayroot overlay (persistent)
- **Boot**: Writable VFAT (accessible from other OS)
- **Data**: Writable ExFAT (cross-platform compatibility)
- **Overlay**: ext4 (persistent runtime changes)
- **Clone**: ext4 (backup/clone target)

## Key Components

### Build-Time Packages

Core packages installed via `apt-get`:
- Python 3 + pip
- NetworkManager, iwd, wireguard-tools
- mosquitto (MQTT broker)
- chrony (replaces systemd-timesyncd)
- gpsd, gpsd-clients
- caddy (web server)
- filebrowser (web file manager)
- overlayroot, dkms, udevil

### Custom Services

Python-based services installed from git submodules:
- `tsconfig` - Configuration service (FastAPI)
- `tsconfig-ble` - Bluetooth Low Energy service
- `pymqttutil` - System statistics via MQTT
- `wittypi4` - RTC and power management (DKMS module + Python daemon)
- `pysmartsolar` - SmartSolar integration
- `vedirect_dump` - VE.Direct protocol handler
- `uhubctl` - USB hub control (compiled from source)

### Systemd Services

Key enabled services:
- `tsconfig.service`, `tsconfig-ble.service`
- `mqttutil.service`
- `wittypid.service` (power management)
- `mosquitto.service`
- `caddy.service`, `filebrowser.service`
- `devmon.service` (udevil automount)
- `gpsd.service`
- `chrony-wait.service` (time sync dependency)
- `hostname-config.service`
- `activate-hotspot.service`
- `brovi_startup.service`
- `repartition-cleanup.service`

### Hardware Support

- **WittyPi 4**: RTC module via DKMS (`rtc-pcf85063-wittypi4`), device tree overlay
- **GPIO**: I2C enabled, UART0 on GPIO header (Pi5), OTG mode (Pi4)
- **USB**: Huawei modem support via udev rules
- **GPS**: gpsd with static location fallback (`/boot/firmware/geolocation`)

## Configuration Points

Runtime configuration via `/boot/firmware/`:
- `cmdline.txt` - Kernel parameters (hostname via `systemd.hostname=`)
- `mqttutil.conf` - MQTT reporting config
- `wireguard.conf` - VPN configuration (symlinked to `/etc/wireguard/`)
- `mosquitto.d/` - Additional MQTT broker configs
- `geolocation` - Static GPS coordinates

## Network Stack

- **NetworkManager**: Primary network management (replaces systemd-networkd)
- **iwd**: WiFi backend
- **WireGuard**: VPN support
- **Samba**: File sharing enabled

## Security

- Read-only root filesystem
- SSH keys managed via `copy-authorized-keys.service`
- Default password set in `userconf.txt` (boot partition)
- NetworkManager for network security

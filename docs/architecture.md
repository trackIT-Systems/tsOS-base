# Architecture

## Base System

Built on Raspberry Pi OS Lite (Debian Trixie) using [pimod](https://github.com/Nature40/pimod) to modify the base image.

## Filesystem Layout

### Partition Structure

The system uses GPT partition table (converted from MBR on first boot via initramfs hook). Partition layout:

1. **bootfs** (Partition 1)
   - Type: EFI System Partition (EF00)
   - Filesystem: VFAT
   - Mount: `/boot/firmware` (root-owned, `0755` - readable by everyone, writable by root
     only; see [Security Design](security.md))
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
   - Type: MBR 0x07 (exFAT/NTFS; macOS only mounts exFAT with this type)
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
LABEL=bootfs            /boot/firmware      vfat    defaults,uid=0,gid=0,dmask=0022,fmask=0133  0 2
/dev/root               /                   ext4    defaults,noatime                        0 1
LABEL=datafs            /media/datafs       exfat   defaults,user,umask=000,fmask=111,nofail,x-systemd.device-timeout=5  0 2

# Bind mount for user access
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
- NetworkManager, wireguard-tools
- mosquitto (MQTT broker)
- chrony (replaces systemd-timesyncd)
- gpsd, gpsd-clients
- caddy (web server)
- FileBrowser Quantum (web file manager)
- overlayroot, udevil
- uhubctl (USB hub per-port power control)

### Custom Services

Python-based services installed from git submodules under `/usr/local/src`:
- `tsconfig` - Configuration service (FastAPI)
- `tsconfig-ble` - Bluetooth Low Energy service
- `pymqttutil` - System statistics via MQTT
- `tsschedule` - Power scheduling (WittyPi 4, Raspberry Pi 5)
- `pysmartsolar` - SmartSolar integration
- `vedirect_dump` - VE.Direct protocol handler

### Systemd Services

Key enabled services:
- `tsconfig.service`, `tsconfig-ble.service`
- `mqttutil.service`
- `tsschedule.service` (power management)
- `mosquitto.service`
- `caddy.service`, `filebrowser.service`
- `devmon.service` (udevil automount)
- `gpsd.service`
- `chrony-wait.service` (time sync dependency)
- `hostname-config.service`
- `repartition-cleanup.service`

### Hardware Support

- **WittyPi 4**: RTC driver `rtc-pcf85063-wittypi4` and `wittypi4` overlay (RTC, shutdown, SYSUP), prebuilt from the [wittypi4](https://github.com/trackIT-Systems/wittypi4) release
- **GPIO**: I2C enabled, UART0 on GPIO header (Pi5), OTG mode (Pi4)
- **LTE**: Teltonika TRM200 (MeiG SLM770A) via ModemManager plugins from the [modemmanager-meig-asr](https://github.com/trackIT-Systems/modemmanager-meig-asr) release
- **LTE**: Huawei / Brovi E3372 sticks (E3372-325, E3372h-320, E3372h-153) in modem mode via the [modemmanager-e3372](https://github.com/trackIT-Systems/modemmanager-e3372) release (usb_modeswitch configuration and patched ModemManager Huawei plugin)
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
- **wpa_supplicant**: WiFi backend
- **WireGuard**: VPN support

## Security

- Read-only root filesystem
- SSH keys managed via `copy-authorized-keys.service` (runs as `pi`; `root`'s keys are a
  separate manufacturer-controlled file, not sourced from the boot partition)
- `pi`'s default password is seeded as a `userconf` file, applied by `userconfig.service` on
  first boot (patched for an upstream shell-reset bug) - the same mechanism an operator's own
  boot-partition `userconf`/`userconf.txt` goes through
- `pi` has no general sudo (only an explicit restart allowlist); `root`'s password is a
  build-time choice (`TSOS_ROOT_PASSWORD`, unset by default → locked, same as before) - see
  [Security Design](security.md)
- NetworkManager for network security

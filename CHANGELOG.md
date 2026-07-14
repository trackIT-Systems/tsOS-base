# Changelog

All notable changes to tsOS-base are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Calendar Versioning](https://calver.org/) (`YYYY.M.PATCH`).

## [Unreleased]

## [2026.7.1] - 2026-07-14

### Added

- `vcgencmd` Python module for reading Raspberry Pi firmware metrics
- `mqttutil` reporting of `vcgencmd` values (clocks, voltages, PMIC, throttling)
- Changelog documenting project history

### Changed

- Updated `tsconfig` and `tsschedule` (mqttutil.conf support, brownout recovery,
  `huaweicheck` / `wificheck` services, Docker CI on branch pushes)
- GitHub releases populated from changelog

## [2026.6.1] - 2026-06-01

### Added

- `wificheck` service for automatic Wi-Fi reconnection
- PMIC temperature and RP1 thermal reporting in `mqttutil`

### Changed

- `tsupdate` rsync behaviour improved

## [2026.4.1] - 2026-04-14

### Added

- Default configuration provisioning from zip archives
- Automatic application of available updates (`tsupdate`)

### Changed

- Niceness values for background services
- Custom `/boot/firmware` path for `tsconfig.yml`

### Fixed

- Invalid niceness value for `tsupdate`
- Restored Mosquitto configuration symlink

## [2026.3.3] - 2026-03-27

### Added

- Wi-Fi client (station) mode with connection priority

### Changed

- GitHub Actions workflow updates

## [2026.3.2] - 2026-03-03

### Added

- ModemManager data reporting in `mqttutil`

### Fixed

- Memory leak in `mqttutil`

## [2026.3.1] - 2026-03-02

### Changed

- `mqttutil` dependency updates
- OS version reported via `os-release`
- `hostname.sh` invoked without bash wrapper

### Fixed

- Solarlife git repository reference

## [2026.2.4] - 2026-02-27

### Added

- Solarlife BLE device readout

### Changed

- Reverted to `wpa_supplicant` for Wi-Fi (stability issues with NetworkManager)

## [2026.2.3] - 2026-02-27

_No user-facing changes._

## [2026.2.2] - 2026-02-27

### Added

- Solarlife library installation
- udev rule for Victron VE.Direct devices

### Changed

- WittyPi repository URL updated
- `tsupdate` support for downloading private update files
- WittyPi 4 module reinstalled for backward `mqttutil` compatibility

## [2026.2.1] - 2026-02-26

### Added

- Solarlife module
- Default `tsos.trackit-system.de` server configuration

### Removed

- Legacy WittyPi module

### Changed

- WittyPi path corrections

## [2026.1.2] - 2026-01-28

### Added

- `rpiboot` installation

### Changed

- `tsschedule` support for Raspberry Pi Compute Module 5
- Filebrowser update

## [2026.1.1] - 2026-01-21

### Added

- `tsflash` utility
- Explicit Wi-Fi channel configuration
- `/data` as Filebrowser working directory

### Changed

- `devmon` continues mounting on `fsck` errors
- Rate limit for `chrony-wait-stop`
- Returned to NetworkManager connection files (from Netplan)
- Removed `chronyd-restricted` in favour of plain Chrony

### Fixed

- Smooth `tsupdate` handling during boot

## [2025.12.6] - 2025-12-23

### Added

- `tsupdate` daemon installation and activation

## [2025.12.5] - 2025-12-22

### Added

- `tsupdate` over-the-air update system
- Automatic `pidiff` differential update file generation in CI

## [2025.12.4] - 2025-12-22

### Changed

- Updated Raspberry Pi OS base image
- Image shrink uses SHRINK instead of ZERO
- pimod v0.9.0

## [2025.12.3] - 2025-12-18

### Changed

- `os-release` naming strategy adapted

## [2025.12.2] - 2025-12-15

### Added

- Hardware watchdog enabled from initial power-on

### Changed

- Repartition scripts use MBR partition table (Raspberry Pi 3 compatibility)
- Watchdog petting in repartition script

## [2025.12.1] - 2025-12-11

### Added

- Dual-boot updatability with overlayroot and repartitioning
- Developer documentation
- Repartition check and cleanup scripts

### Changed

- Dynamic `/data` mount on `sda`
- Root filesystem mounted via `/dev/root`
- Masked legacy firstboot services and scripts

## [2025.11.4] - 2025-11-14

### Changed

- Brovi modem power cycle on boot
- `uhubctl` update

## [2025.11.3] - 2025-11-13

### Added

- VHF Signals dashboard link

## [2025.11.2] - 2025-11-13

### Added

- `chrony-wait-stop` service for RTC time-sync target handling
- Hotspot activation retry on boot

### Fixed

- Hotspot hostname setting

## [2025.11.1] - 2025-11-04

### Changed

- Network handling refactored
- Vim set as default editor

## [2025.10.5] - 2025-10-29

### Fixed

- Wi-Fi setup broken with WPA2 on older hardware

## [2025.10.4] - 2025-10-22

### Changed

- CI builds run on arm64 runners
- Image file zeroed after build (pimod)
- Default location set to Brandenburger Tor

## [2025.10.3] - 2025-10-21

### Added

- Centralized geolocation via `/etc/geolocation`

### Changed

- `mqttutil` reports `tsconfig` version information

## [2025.10.2] - 2025-10-16

### Added

- Samba file sharing
- Persistent systemd journal
- USB OTG mode on Raspberry Pi 4
- Bluetooth enabled on Raspberry Pi 3 and 4

### Changed

- Reduced image size
- `rfkill` handling aligned with previous behaviour

### Fixed

- `tsconfig` startup and bash variable handling
- Swap and `resize2fs` methods

## [2025.10.1] - 2025-10-15

### Changed

- Upgraded base image to Debian Trixie (Raspberry Pi OS)

## [2025.8.3] - 2025-08-20

### Fixed

- USB drive mount to `/data` uses `nofail` option

## [2025.8.2] - 2025-08-19

### Added

- USB drive mount concept for `/data`

### Changed

- Increased root partition size
- Disabled automatic package updates

## [2025.8.1] - 2025-08-01

### Fixed

- WittyPi 4 bugfixes
- `tsconfig` latitude/longitude handling

## [2025.7.3] - 2025-07-31

### Fixed

- Typo in configuration

## [2025.7.2] - 2025-07-31

### Added

- Non-Huawei LTE modem support
- Hostname distribution initialization

### Changed

- Default CPU governor set to `schedutil`

### Fixed

- WittyPi reboot/shutdown firstboot bug

## [2025.7.1] - 2025-07-23

### Changed

- Filebrowser and `tsconfig` updates

## [2025.6.4] - 2025-06-26

_No user-facing changes._

## [2025.6.3] - 2025-06-24

### Changed

- Replaced sysdweb with `tsconfig` configuration manager

## [2025.6.2] - 2025-06-10

### Fixed

- Re-enabled `raspi-config` for dynamic CPU frequency scaling

## [2025.6.1] - 2025-06-06

### Added

- Firstboot `datafs` creation on initial boot
- GitUI web interface
- Git repositories included in image

### Changed

- Bind mount instead of symlink for data paths
- Updated Caddy and Filebrowser

### Fixed

- `authorized_keys` copy service timeout
- `vedirect_dump` bugfixes

## [2025.3.gh1] - 2025-03-31

### Changed

- GitHub release settings

## [2025.3.3] - 2025-03-31

### Changed

- WittyPi 4 update (ButtonEntry bugfix, system timezone support)

## [2025.3.2] - 2025-03-13

### Added

- Timezone configuration via `cmdline.txt`
- `authorized_keys` copied from boot filesystem

### Changed

- Legacy timezone configuration mechanism removed
- WittyPi power-cut delay increased
- Dotfiles hidden in Filebrowser

## [2025.3.1] - 2025-03-10

### Added

- WittyPi 4 power-cut service

### Changed

- Swap service disabled
- Removed SmartSolar power retrieval

## [2025.2.1] - 2025-02-05

### Changed

- `mqttutil` update

## [2025.1.2] - 2025-01-24

### Changed

- Repository renamed to tsOS-base

## [2025.1.1] - 2025-01-23

### Added

- Country code and NetworkManager configuration

### Changed

- GitHub Actions runners updated to modern Ubuntu

### Fixed

- Re-enabled ifupdown network configuration

## [2024.12.1] - 2024-12-19

### Added

- UART0 enabled on Raspberry Pi 5

### Changed

- Updated Raspberry Pi OS base image
- Removed pimod build dependency from image

## [2024.09.2] - 2024-09-16

### Added

- `vedirect_dump` for reliable Victron VE.Direct readouts

### Fixed

- Error handling in `vedirect_dump`

## [2024.09.1] - 2024-09-16

### Added

- VE.Direct serial readout support

## [2024.07.2] - 2024-07-26

### Changed

- WittyPi support for revision 7 hardware

## [2024.07.1] - 2024-07-08

### Added

- Git-based versioning for releases

### Changed

- Updated Raspberry Pi OS base image

## [2024.05.1] - 2024-05-08

### Changed

- Default reset method for `huaweicheck`

## [2024.04.2] - 2024-04-30

### Fixed

- Reimplemented `chrony-waitsync` (boot issues)

## [2024.04.1] - 2024-04-22

_No user-facing changes._

## [2024.03.3] - 2024-04-22

### Changed

- Protected `resolv.conf` from modification

## [2024.03.2] - 2024-03-12

### Fixed

- WittyPi schedule time-sync race condition
- WittyPi logic bugs
- `mqttutil` now depends on `network-online`

### Changed

- Removed `chrony-waitsync`

## [2024.03.1] - 2024-03-04

### Added

- WittyPi power management support
- WittyPi status querying
- Brovi modem handling refactored

## [2024.02.3] - 2024-02-20

### Changed

- `huaweicheck` uses Huawei API instead of power cycling
- `huaweicheck` timer intervals adjusted

## [2024.02.2] - 2024-02-15

### Changed

- Symlink created for backward compatibility

## [2024.02.1] - 2024-02-15

### Added

- WittyPi compatibility
- `rtl88x2bu` Wi-Fi driver and `wlan1` configuration
- Default configuration files

### Changed

- Audio disabled by default
- Updated Raspberry Pi OS and SmartSolar modules
- WittyPi module updated; Chrony support

## [2024.01.4] - 2024-01-09

### Changed

- CI builds only on tag pushes

### Fixed

- MEMS / Raspberry Pi 4 compatibility

## [2024.01.3] - 2024-01-03

### Added

- Zsh shell

### Removed

- Private SSH keys from image

## [2024.01.2] - 2024-01-02

Initial release of tsOS-base as a stripped-down Raspberry Pi OS image for
field-deployed sensor stations.

### Added

- Base Raspberry Pi OS image built with [pimod](https://github.com/Nature40/pimod)
- GitHub Actions CI for tagged releases (arm64 and armhf)
- Caddy reverse proxy and file server
- sysdweb service management web UI
- `pymqttutil` for MQTT-based system monitoring
- Radio tracking (`pyradiotracking`) with RTL-SDR support
- Huawei / Brovi LTE modem support (`huaweicheck`)
- Victron SmartSolar BLE readout (`pysmartsolar`)
- GPS clock support via `gpsd` and Chrony
- I2S microphone kernel module
- Avahi service discovery
- Hostname configuration via kernel command line
- Hardware watchdog and kernel panic reboot
- Real-time clock support
- Flash script for convenient SD card writing
- `/data` partition for persistent storage
- WireGuard VPN configuration
- uhubctl USB power management

# tsOS-base
[![Build tsOS-base Images](https://github.com/trackIT-Systems/tsOS-base/actions/workflows/build.yml/badge.svg)](https://github.com/trackIT-Systems/tsOS-base/actions/workflows/build.yml)
![GitHub Release](https://img.shields.io/github/v/release/trackIT-Systems/tsOS-base)

tsOS-base is a Raspberry Pi OS Lite (Debian Trixie) image for unattended field sensor stations. It ships two architectures: **arm64** (Raspberry Pi 3+ / Compute Module) and **armhf** (older Pi models).

The root filesystem is read-only with a persistent overlay. Partition layout, overlayroot, and first-boot repartitioning are described in [docs/architecture.md](docs/architecture.md).

## What's in the image

- **tsconfig** — web and BLE configuration
- **Caddy** reverse proxy with **Filebrowser** at `/data/`
- **Mosquitto** MQTT broker and **mqttutil** system reporting
- **pyenvsense** — SHT3x / SHT4x environmental sensors
- **Chrony** + **gpsd** time sync
- **WittyPi 4** RTC / power management via **tsschedule**
- **WireGuard**, **Samba**, LTE helpers (`huaweicheck`, Brovi)
- Victron readout (**pysmartsolar**, **vedirect_dump**)

## Download and flash

Images are published in [GitHub Releases](https://github.com/trackIT-Systems/tsOS-base/releases). Use the arm64 build for Pi 3 and newer; use armhf for older boards.

Flash with Raspberry Pi Imager or `dd`. Default hostname is `tsos-default-name` ([boot/firmware/cmdline.txt](boot/firmware/cmdline.txt)).

## First access

**SSH:** user `pi`, password `natur`. Drop a public-key file at `/boot/firmware/authorized_keys` on the card; [copy-authorized-keys.service](etc/systemd/system/copy-authorized-keys.service) installs it for `pi` and `root` on boot.

**Wi-Fi hotspot:** SSID follows the hostname (default `tsos-default-name`), PSK `BirdsAndBats`. The station is `169.254.0.1` ([hotspot.nmconnection](etc/NetworkManager/system-connections/hotspot.nmconnection)). An optional client network is defined in [station.nmconnection](etc/NetworkManager/system-connections/station.nmconnection).

**Web:** Caddy on port 80 — tsconfig at `/`, Filebrowser at `/data/` ([Caddyfile](etc/caddy/Caddyfile)). Avahi advertises HTTP as `_http._tcp`.

## Boot configuration

Runtime settings live on the VFAT boot partition (`/boot/firmware` on the Pi). Edit on the card, then reboot.

| File | Purpose |
| --- | --- |
| [`cmdline.txt`](boot/firmware/cmdline.txt) | `systemd.hostname=`, `timezone=`, first-boot `repartition` |
| `tsconfig.yml` | tsconfig service config (copied from the tsconfig submodule at build) |
| [`mqttutil.conf`](boot/firmware/mqttutil.conf) | MQTT system reporting |
| `mosquitto.d/` | Extra Mosquitto broker configs (`include_dir`) |
| [`envsense.yml`](boot/firmware/envsense.yml) | Environmental sensors (`pyenvsense`) |
| `wireguard.conf` | WireGuard interface (symlinked to `/etc/wireguard/`) |
| `authorized_keys` | SSH keys copied to `pi` and `root` |
| `geolocation` | Static GPS coordinates (symlinked to `/etc/geolocation`) |

Deeper filesystem and overlay details: [docs/architecture.md](docs/architecture.md).

## Storage

`/data` is the station data volume: ExFAT `datafs` after first-boot repartition, or a USB disk bind-mounted by `devmon`. Filebrowser roots at `/data`. Samba share `[media]` exports `/media` guest-writable.

## Updates

`tsupdate` applies OTA images using Raspberry Pi tryboot, with automatic rollback if the new image fails to boot. Operator overview: [docs/updatability.md](docs/updatability.md). Daemon details: [usr/local/src/tsupdate/README.md](usr/local/src/tsupdate/README.md).

## Hardware

- WittyPi 4 RTC and power scheduling (`tsschedule`)
- UART0 on the GPIO header (Pi 5); USB OTG (Pi 4)
- I2C bus 1 at 400 kHz; second bus via `dtparam=i2c_vc=on`
- GPS via gpsd; static fallback `/boot/firmware/geolocation`
- Huawei / Brovi LTE via NetworkManager and `huaweicheck`
- Hardware watchdog: [docs/watchdog.md](docs/watchdog.md)

## Build

Images are built with [pimod](https://github.com/Nature40/pimod) `v0.9.2` ([docker-compose.yml](docker-compose.yml)):

```sh
docker-compose run --rm pimod pimod.sh tsOS-base.Pifile
# armhf:
docker-compose run --rm pimod pimod.sh tsOS-base-armhf.Pifile
```

See [docs/build.md](docs/build.md) and [docs/structure.md](docs/structure.md).

## Further reading

- [Architecture](docs/architecture.md) — overlayroot, partitions, services
- [Build system](docs/build.md) — Pifile and CI
- [Project structure](docs/structure.md) — repository layout
- [Updatability](docs/updatability.md) — dual-boot / tryboot
- [Hardware watchdog](docs/watchdog.md)
- [Developer docs index](docs/README.md)

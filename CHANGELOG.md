# Changelog

All notable changes to tsOS-base are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Calendar Versioning](https://calver.org/) (`YYYY.M.PATCH`).

## [Unreleased]

**This release changes the root/pi privilege model - see [docs/security.md](docs/security.md).
It ships as a reflash boundary: no delta update is published into it, existing devices keep
their previous model and are not patched; every device is reinstalled from scratch.**

### Security

- Operator authentication: tsconfig (web UI, API, web shell) and `/data` over HTTP now require a login with `pi`'s password (PAM, new `etc/pam.d/tsconfig`; Caddy `forward_auth` guards Filebrowser), and the BLE gateway requires an encrypted link plus the same login. Staff can log in to tsconfig, WebDAV and BLE as `root` with root's password if the image was built with `TSOS_ROOT_PASSWORD` (checked through `su`; no extra rights; stricter throttling). Filebrowser now runs as `pi`, no longer authenticates itself (`noauth` off, proxy-header login from Caddy after tsconfig's PAM check) and serves WebDAV at `/data/dav/data/` with HTTP Basic `pi` + the `pi` password (verified by tsconfig, `/auth/check` accepts Basic only for `/data/dav/`). The hotspot password can be set from a config bundle via `hotspot.nmconnection`. Defaults are unchanged and public (`pi`/`natur`, hotspot `BirdsAndBats`) until a bundle sets real values. See [docs/security.md](docs/security.md)
- `pi` has no sudo at all (removed from `sudo` and `adm`; no sudoers drop-in). Its privileged
  actions use polkit and group membership instead: non-persistent `systemctl` verbs on a fixed
  unit allowlist (`20-tsos-systemctl.rules`; `enable`/`disable`/`mask` stay denied), reboot via
  logind (`21-tsos-reboot.rules`), full NetworkManager control for `netdev` including secrets
  (`10-tsos-netdev.rules`), the full journal via `systemd-journal`, and `pkexec` into the
  root-owned `tsconfig-privileged` wrapper (config write/delete/stat, overlay wipe, GSM field
  removal; `30-tsos-privileged.rules`). `polkitd` and `pkexec` are installed explicitly.
- The BLE gateway (`tsconfig-ble.service`) runs as its own system user `tsconfig-ble` in `shadow` instead of `pi`, for tsconfig's new BLE hash login (`{"hash": "$6$..."}` logs in as `pi` with pi's hash from the applied bundle's `userconf.txt`). `pi` stays out of `shadow`. pi's hash is now a BLE credential: treat bundles with `userconf.txt` as secrets. See docs/security.md, "BLE"
- `chrony.service` is on the polkit unit allowlist (`20-tsos-systemctl.rules`), so the restart `tsconfig` offers for it works for `pi` instead of failing
- `root` is reachable via SSH with a manufacturer key (`root/.ssh/authorized_keys`, baked in,
  independent of the boot partition). The boot partition's `authorized_keys` applies to `pi`
  only, and sshd reads it in place (`Match User pi` in `20-tsos-authorized-keys.conf`) instead of
  `copy-authorized-keys` copying it to `~/.ssh/authorized_keys2`: a key removed from the boot
  partition stops working at the next login, and `.ssh/authorized_keys2` is no longer read for
  any user. `root` gets a password only if the image is built with `TSOS_ROOT_PASSWORD` (otherwise
  `passwd -l`); it then also works for `su`, the staff login and SSH (root password SSH is
  enabled only in that case, `PermitRootLogin prohibit-password` otherwise).
- `/boot/firmware` is now root-owned (`0755`) instead of world-writable, and no longer
  bind-mounted to `/media/boot`; `/usr/local/src` is now `root:root` instead of `pi:pi`.
  `tsconfig.service` runs as `pi` and writes root-owned configuration through
  `tsconfig-privileged`, which re-validates it (WireGuard hook directives are rejected). The
  service allowlist is no longer read from the operator-writable `tsconfig.yml`.
- `pi`'s password comes from `userconf.txt` (default `natur`), applied by `userconfig.service` on every boot, so a config bundle can change it at any time (upstream disabled the unit after the first file via `cancel-rename`). `userconf-service` is replaced by a short script that applies `pi:<hash>` itself: no rename, no dialog, shell stays zsh.
- The password hashes written at build time (`pi`'s default `natur`, `root` from `TSOS_ROOT_PASSWORD`) use fixed salts (`tsOSusersalt0000`, `tsOSrootsalt0000`), so the same password gives the same hash on every build.
- Optional HTTPS: Caddy also serves the site on `:443` with certificates from its own per-device local CA (`tls internal`) for the hostname, `<hostname>.local`, `localhost` and `169.254.0.1`; clients connecting by IP get the `.local` certificate. Plain HTTP on `:80` stays and is not redirected. Logins over HTTPS get a `Secure` session cookie. See [docs/security.md](docs/security.md), "HTTPS (optional)"
- Samba is removed entirely (package, `smb.conf`, `smbd` service). It previously shared `/data` to
  any guest on the network (and, in earlier releases, all of `/media`, which included the boot
  partition and a read-only root filesystem mount). `/data` is reached over HTTP (`/data/`, login
  required) or SSH/SFTP as `pi`.
- `filebrowser` and `envsense` run with `ProtectSystem=strict` sandboxing instead of unsandboxed
  root (`envsense` as a `DynamicUser`; `filebrowser` as `pi`, see the operator authentication entry).
- `tsupdate` only accepts update sources from the `trackIT-Systems` GitHub org (enforced in
  code), and verifies cached/downloaded files against the GitHub API's asset digest instead of
  trusting the (world-writable) download cache by name.
- The web shell execs the operator's own login shell directly instead of `su`-ing to a
  separately configurable user.

- `mqttutil` is replaced by `tstelemetry` (see Changed). mqttutil evaluated the Python expressions in `/boot/firmware/mqttutil.conf` and imported the modules it listed, so whoever could write that file (on the card, through a bundle, or in tsconfig's Reporting tab) ran code as `pi`. Its successor's settings, `/etc/tsconfig/tstelemetry.yml`, hold data only and are root-owned build-time data

### Fixed

- `envsense.service` no longer restarts forever on boards without the configured onboard source (e.g. `rpi_rp1` off a Raspberry Pi 5). The default `boot/firmware/envsense.yml` configures no sensors, since `tstelemetry` already records SoC, RP1 and PMIC temperatures, and `envsensed` (pyenvsense) now exits with status 0 when no sensors are configured. Add external SHT3x / SHT4x sensors to the file to use it
- `tstelemetry` collects `thermal`, `pmic`, `throttled`, `clocks`, `voltages` and `network` again: its sandbox allows `/dev/vcio_gencmd` (vcgencmd reads the firmware there since 0.4; `/dev/vcio` is root's) and `AF_NETLINK` (to list the network interfaces)
- Failed logins (web, WebDAV, BLE) no longer log the user name unless it is `pi` or `root`, so a password typed into the user name field does not reach the journal or MQTT; the OIDC logout no longer logs the session ID
- Explicitly install `modemmanager` (no longer pulled in by default on Trixie) ([#33](https://github.com/trackIT-Systems/tsOS-base/issues/33))
- Hotspot is WPA2-only again (`proto=rsn`, was WPA/WPA2 mixed mode, flagged as insecure by macOS and refused by some Android clients). A NetworkManager dispatcher script (`90-hotspot-wpa2`) drops the `WPA-PSK-SHA256` key management NetworkManager adds without PMF, which firmware without PMF support (Raspberry Pi 3 B) cannot advertise ([#17](https://github.com/trackIT-Systems/tsOS-base/issues/17), [#19](https://github.com/trackIT-Systems/tsOS-base/issues/19))

### Changed

- Services log to the journal per the logging convention: tsconfig, tsconfig-ble, tstelemetry, smartsolard, solarlifed, envsensed, tsscheduled and tsupdated write their priority and source location to the journal (`journalctl -p warning` works; before, every line was stored as info). Units started through `/usr/bin/env` or `python3` set `SyslogIdentifier=` (they logged as `env`/`python3`). All run at WARNING by default: `-v` is dropped from `tsschedule.service` and `tsconfig-ble.service`, `LOG_LEVEL=INFO` from `tsconfig.service`, and smartsolar and solarlife ship `log_level: WARNING`
- `tsupdate` reports failures as transient (offline, timeouts, GitHub 5xx and rate limit: WARNING once), configuration (repository, access, URLs, maintenance window: ERROR) or other errors, logged once per stage until they work again; an offline station no longer logs an ERROR on every check. The `tsupdate` CLI exits 75 for transient and 78 for configuration errors
- **Breaking for consumers:** `smartsolard` and `solarlifed` publish every reading as CSV, JSON and CBOR with fixed columns (`time` with UTC offset, `synced`, `device`, then the values under their names, no display texts with units), at most one reading per device every 300 s over MQTT (`mqtt.publish_interval_s`), and write one CSV file per day, re-timing readings taken before the clock is synced. smartsolar no longer says which source a reading came from; solarlife readings are on `{host}/solarlife/{mac}/{block}/{fmt}`. Topics and columns: [pysmartsolar](https://github.com/trackIT-Systems/pysmartsolar/blob/main/docs/outputs.md), [pysolarlife](https://github.com/trackIT-Systems/pysolarlife/blob/main/docs/outputs.md)
- **Breaking for consumers:** system telemetry comes from `tstelemetry.service` (part of tsconfig) instead of `mqttutil.service`. The topics `{host}/mqttutil/<task>` are replaced by `{host}/tsconfig/<collector>/{csv,json,cbor}` plus a retained `{host}/tsconfig/state`, and the payloads changed: every format carries the same columns, `time` (with UTC offset; in CBOR a tag-0 datetime) and `synced` first; CBOR is a list in column order. Bridges must forward the new topics (e.g. `topic +/tsconfig/+/cbor out 1`). Files go to `/data/<host>/tsconfig/<collector>/<host>_<YYYY-MM-DD>_<collector>.csv`, one per day, instead of `/data/<task>.jsonl` (existing JSONL files are left alone). Every mqttutil task has a collector; `rp1` now finds its sensor by name (it read `hwmon2`, which is a different sensor on some boards), and WittyPi readings are skipped on stations without the board instead of logging a traceback every minute. Telemetry starts before the clock is synced: readings are re-timed for the files once chrony has synced. Topic and column reference and the old-to-new mapping: [docs/telemetry.md](docs/telemetry.md)
- `/boot/firmware/mqttutil.conf` is gone. Telemetry is not operator configuration any more: `/etc/tsconfig/tstelemetry.yml` (collectors on/off and intervals) is installed from tsconfig's `configs/tstelemetry.yml`, like `tsconfig.yml`. Config bundles that still contain `mqttutil.conf` are accepted; the file is skipped
- `vcgencmd` 0.5.0 reads firmware telemetry through the mailbox device `/dev/vcio_gencmd` instead of running the `vcgencmd` binary for every value; readings and API are unchanged. Config keys asked for by name are also found at their default value
- `smartsolar.yml` and `solarlife.yml` moved from the boot partition to `/etc/smartsolar/` and `/etc/solarlife/` (the daemons' new default config paths); they are root-owned build-time config, not something to edit on the SD card.
- tsconfig's own `tsconfig.yml` (services list, feature flags) is installed to `/etc/tsconfig/tsconfig.yml` instead of the boot partition: it is build-time data that nothing edits at runtime, and it is no longer changeable by mounting the SD card.
- gitui is downloaded with `curl` like every other build-time download, not `wget`, so the image carries no `wget` leftovers (`~/.wget-hsts`, `wget-log`).
- `50-vedirect.rules` also matches the FTDI FT230X (`0403:6015`) next to the FT232R, and names every such adapter `/dev/ttyUSBvd<n>` after its `ttyUSB<n>` (`smartsolard` follows the first match, `serial.port: /dev/ttyUSBvd*`), and tells **ModemManager to ignore** these adapters (`ID_MM_DEVICE_IGNORE`, `ID_MM_PORT_IGNORE`): it used to probe the port with AT commands, which are garbage on a VE.Direct line. The chip is generic (the cable it was written for shows up as manufacturer "FTDI", product "USB <-> Serial", no serial number), so the rule matches the chip, not Victron
- The VE.Direct readout no longer runs from `mqttutil` (`vedirect_dump`, once a minute, one reader at a time on the port): `smartsolard` reads the cable itself. **Breaking for consumers:** the MQTT topic `{host}/mqttutil/vedirect` and `/data/<host>/mqttutil/vedirect.jsonl` are replaced by the topics and CSV of the new service (see Added). Values are published per source with `Friendly name (unit)` keys, the field names differ from `vedirect_dump` (e.g. `Battery voltage (V)`, `PV power (W)`, `Panel voltage (V)`; yields in kWh). The cable is **on by default** in `smartsolar.yml`: without one the port is retried quietly (one log line and event), with one it is used next to Bluetooth
- The SolarLife BLE readout no longer runs from `mqttutil`: it used to scan, connect and disconnect once a minute, which mostly failed while the 2.4 GHz hotspot shared the radio. `solarlifed` keeps one connection open instead. **Breaking for consumers:** the MQTT topic `{host}/mqttutil/solarlife` and the file `/data/<host>/mqttutil/solarlife.jsonl` are replaced by the topics and CSV above (values are published per block, with keys `Friendly name (unit)` as before). The `pysolarlife` Python API (`read_device()`, `MpptClient`) is gone
- `tsconfig-ble.service` no longer `Requires=` tsconfig (`Wants=` instead): restarting tsconfig used to stop and restart the BLE gateway too, dropping every open BLE connection. It is now `Type=notify` with `WatchdogSec=60`, so systemd restarts a gateway that hangs
- Dropped armhf builds; images are arm64 only
- Source trees for application git submodules live under `/usr/local/src` instead of `/home/pi`
- Install `uhubctl` from apt instead of building the git submodule
- Raspberry Pi OS Lite base image updated to 2026-09-15 (Trixie, kernel 6.18)
- Build with pimod v0.9.3 (Docker image, GitHub Action, and pidiff)
- WittyPi RTC driver and overlay installed prebuilt from the `wittypi4` 0.2.0 release (tsschedule no longer ships the kernel driver); the overlay now also provides shutdown (GPIO4) and SYSUP (GPIO17), replacing the `gpio-shutdown` and `gpio-led` overlays. No DKMS or compiler in the image; the `wittypi4` submodule and the unused `i2cdevice` package are dropped
- Updated `tsconfig` (saving configuration no longer deploys automatically; save and deploy are separate actions)
- Replaced File Browser with FileBrowser Quantum v1.5.6-stable (same `/data/files` URLs, no-auth)
- Default `pi` password and zsh login shell are set in the image; `userconfig.service` stays enabled with a patched `userconf-service` so Trixie `userconf-pi` cannot reset the shell to bash
- ~~Passwordless `sudo` for `pi` restored (`raspi-config nonint do_sudo_pass 1`; Trixie disables it by default)~~ - reverted, see Security above
- Huawei / Brovi E3372 LTE sticks (E3372-325, E3372h-320, E3372h-153) run in modem mode instead of HiLink mode: switched by the [`modemmanager-e3372`](https://github.com/trackIT-Systems/modemmanager-e3372) 1.24.0-2 release and connected by ModemManager through the `cellular` profile (`ppp0` on the E3372-325, `wwan0` on the E3372h). The host gets the carrier IP directly instead of `192.168.8.x` behind the stick's NAT
- The `cellular` profile has IPv6 disabled (the E3372-325 ends PPP sessions that negotiate IPv6)
- NetworkManager ignores the ECM interface of the Quectel EC200A (`2c7c:6005`, new `70-quectel-ec200a-nm-unmanaged.rules`): ModemManager connects it over PPP, and DHCP on the ECM interface left a dead default route via the modem's internal router
- Avahi publishes over IPv4 only (`use-ipv6=no`) and only IPv4 addresses (`publish-aaaa-on-ipv4=no`), so an mDNS reflector echoing a stale IPv6 record no longer renames the host to `<host>-2.local` at boot

### Added

- Logging convention, [docs/logging.md](docs/logging.md): every service logs to the journal with its program name (`SYSLOG_IDENTIFIER`), a real priority and the source location in `CODE_FILE`/`CODE_LINE`/`CODE_FUNC`; the default level is WARNING, a working station logs nothing in normal operation, and a failure is logged when it starts, changes and ends, not on every retry ([#31](https://github.com/trackIT-Systems/tsOS-base/issues/31))
- `tstelemetry` publishes journal entries from `info` up as `<host>/tsconfig/journal/<unit>/<level>/{csv,json,cbor}`, limited per level (repeats merged, burst and rate per unit, hourly budget, configurable in `tstelemetry.yml`), plus counts per unit and level as the `journalstats` collector. The bridge chooses what leaves the station, e.g. `topic +/tsconfig/journal/+/err/cbor out 1` ([#31](https://github.com/trackIT-Systems/tsOS-base/issues/31))
- MQTT over WebSockets for tsconfig's live dashboard: Mosquitto has a second loopback listener (`127.0.0.1:9001`, `protocol websockets`) and Caddy serves it at `/mqtt` for logged-in users (`forward_auth` to tsconfig's `/auth/check`, as for Filebrowser). Requests whose `Origin` is not the device itself are refused with 403. The broker has no authentication of its own, so a logged-in user can read and write every topic. The login is only checked when the socket opens, so an open socket stays connected after logout. Mosquitto now declares its loopback listeners (`1883` on `127.0.0.1` and `::1`) explicitly and uses `per_listener_settings`: anonymous access is allowed on those only, and a listener added in `mosquitto.d` keeps Mosquitto's default of refusing anonymous clients. See [docs/security.md](docs/security.md), "MQTT over WebSocket"
- tsconfig's status page shows the charge controller: a Power card for `solarlifed` or `smartsolard`, whichever has readings from the last 5 minutes (`system.power_recent_s`), with a Refresh button for a live read. tsconfig forwards `status`, `cached` and `read` to the daemons' control sockets for logged-in users and refuses every other command, `write` among them. See docs/security.md
- Victron SmartSolar readout as its own service: `smartsolar.service` runs `smartsolard` (`pysmartsolar` 1.2.0), which follows one SmartSolar over the Instant Readout advertisements (works with the hotspot up) and/or the VE.Direct cable, and reports to CSV (`/data/<host>/smartsolar/<host>_<timestamp>-smartsolar.csv`) and MQTT (`{host}/smartsolar/{serial}/json` and `/cbor`, one message per source, plus retained `state` and `events` topics). Devices are named by serial number. Configured by `/boot/firmware/smartsolar.yml`; the `smartsolar` CLI talks to the daemon over `/run/smartsolar/smartsolar.sock` (values, key, settings, `write`, `.vcsf` profile `diff`/`load`/`save`, over the cable or Bluetooth). It runs as `pi` with a sandbox that leaves USB serial devices visible, starts after `tsos-bluetooth-address.service`, keeps a fetched key in `/var/lib/smartsolar`, and is on the polkit unit allowlist. The Instant Readout key has to be put into `smartsolar.yml` or fetched once with the hotspot off, because a GATT connection mostly fails while the hotspot shares the radio. See [docs/security.md](docs/security.md), "SmartSolar daemon"
- SolarLife MPPT readout as its own service: `solarlife.service` runs `solarlifed` (from the rewritten `pysolarlife`), which holds one BLE connection to the strongest SolarLife controller, polls it and reports to CSV (`/data/<host>/solarlife/<host>_<timestamp>-solarlife.csv`) and MQTT (`{host}/solarlife/{mac}/json` and `/cbor`, plus retained `state` and `events` topics). Configured by `/boot/firmware/solarlife.yml`; the `solarlife` CLI talks to the daemon over `/run/solarlife/solarlife.sock` (cached and live values, writes, reconnect, rescan). It runs as `pi` with a sandbox, starts after `tsos-bluetooth-address.service`, and is on the polkit unit allowlist. See [docs/security.md](docs/security.md), "SolarLife daemon"
- Per-install Bluetooth address (`tsos-bluetooth-address.service`, `/usr/local/sbin/tsos-bluetooth-address`): at every boot, after `bluetoothd` and before `tsconfig-ble`, the controller gets its own vendor prefix plus three random bytes that are stored in `/var/lib/bluetooth/tsos-address`, next to BlueZ's keys. After a reflash (keys gone) the device therefore shows up under a new address and phones pair afresh instead of failing on a stale bond (macOS/iOS: "Peer removed pairing information", fixed only by forgetting the device in the phone's settings). The serial in the advertisement stays the stable identity. The old bond stays on the phone as harmless clutter. The suffix belongs to the SD card and the prefix to the board; a card that is cloned after its first boot gives all clones of one board type the same address
- Teltonika TRM200 (MeiG SLM770A, RNDIS and ECM mode) LTE support: ModemManager plugins installed from the [`modemmanager-meig-asr`](https://github.com/trackIT-Systems/modemmanager-meig-asr) 1.24.0-1 release
- Avahi announces WebDAV (`_webdav._tcp` on 80, TXT `path=/data/dav/data/`, `u=pi`) and SSH/SFTP (`_ssh._tcp`, `_sftp-ssh._tcp`); `_http._tcp` gets TXT `path=/`

### Removed

- The `pymqttutil` submodule and `mqttutil.service` (replaced by `tstelemetry.service`); `python3-schedule`, `python3-pytimeparse` and `python3-dotenv` are no longer installed for it
- The `[vedirect]` task from `boot/firmware/mqttutil.conf` and the `vedirect_dump` submodule with its `vedirect_m8` / `ve_utils` / `gatt` installs (the udev rule `50-vedirect.rules` stays: it creates `/dev/ttyUSBvd0` for `smartsolard`)
- The `[solarlife]` task from `boot/firmware/mqttutil.conf` (`mqttutil` no longer uses BLE). `pysmartsolar` was not part of the mqttutil configuration and stays installed unchanged
- HiLink tooling for the Huawei / Brovi sticks: `huaweicheck` (service and timer), `brovi_switch`, `brovi_startup`, the `40-huawei.rules` udev rules, the `hua0` interface and its `huawei` NetworkManager profile, and the `huawei/*` HiLink web API readouts in `boot/firmware/mqttutil.conf` (`uhubctl` stays installed)
- Avahi no longer announces `_mqtt._tcp`: Mosquitto listens on loopback only unless a `mosquitto.d` listener is added

## [2026.9.1] - 2026-09-16

### Added

- `pyenvsense` environmental sensor daemon (`envsensed`) with default config at `/boot/firmware/envsense.yml` (SoC temperature)
- Second I2C bus enabled (`dtparam=i2c_vc=on`)

### Changed

- ARM I2C (bus 1) baud rate set to 400 kHz

### Fixed

- `hostname-config` no longer orders itself before `sockets.target`, which created a systemd cycle and skipped the unit at boot. It now runs as a `network-pre.target` service before Avahi and NetworkManager, and sets hostname/timezone via files instead of D-Bus (`hostnamectl`/`timedatectl`).

## [2026.7.2] - 2026-07-20

### Added

- Avahi daemon config restricting mDNS to `eth0` and `wlan0` (excludes macvlan and other virtual interfaces)

### Changed

- `hostname-config` runs before Avahi starts instead of restarting `avahi-daemon` after hostname changes
- Updated `tsconfig` (enforce fixed clock times for system maintenance, synchronize and verify file mtimes on updates, and improve Soundscapepipe configuration/UI for optional fields and disabled output devices)

### Fixed

- `tsupdate` preserves `cmdline.txt` modification (`mtime`) and access (`atime`) times during tryboot operations to prevent `tsconfig` from incorrectly treating it as newer than the source configuration

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

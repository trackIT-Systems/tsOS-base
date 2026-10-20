# Telemetry (`tstelemetry`)

`tstelemetry.service` publishes the device's health over MQTT and writes it to daily CSV files. It replaces `mqttutil`. Its code is the `app.telemetry` package of [tsconfig](../usr/local/src/tsconfig), but it runs as a process of its own, so telemetry continues while the web UI is down or being updated.

Each kind of data comes from one **collector**, a Python module in [app/telemetry/collectors](../usr/local/src/tsconfig/app/telemetry/collectors). The settings file, `/etc/tsconfig/tstelemetry.yml`, only switches collectors on and off and sets their intervals. It cannot run code, unlike `mqttutil.conf`, and it is not operator configuration.

## MQTT

| Topic | Payload | Retained |
| --- | --- | --- |
| `<host>/tsconfig/<collector>/csv` | one `;`-separated line, no header | no |
| `<host>/tsconfig/<collector>/json` | object, keys in column order | no |
| `<host>/tsconfig/<collector>/cbor` | array, values in column order | no |
| `<host>/tsconfig/state` | `{"state": "online"}`, or `{"state": "offline"}` (last will) | yes |

- `<host>` is the hostname.
- QoS is 0, and messages are dropped while the broker is unreachable.
- A collector that reports several things (disks, interfaces, config files) sends one message per thing, all with the same `time`.

All three formats carry the same columns in the same order:
1. `time`: when the reading was taken, with the station's UTC offset. JSON and CSV use ISO 8601 (`2026-10-19T14:00:00+02:00`). CBOR uses tag 0, the same string, which decoders return as a timezone-aware datetime.
2. `synced`: whether the clock was synced when the reading was taken. Readings with `false` have an unreliable `time` (see [Clock](#clock)).
3. The collector's columns, listed below. A value the device cannot provide is `null` (empty in CSV).

CBOR has no key names, which keeps cellular traffic small. Its field order is the column order listed here, which is also the CSV file header.

For the cellular bridge, forwarding CBOR and the state is enough:

```
topic +/tsconfig/+/cbor out 1
topic +/tsconfig/state out 1
```

### Other publishers on the station

The charge controller daemons publish in the same style: CSV, JSON and CBOR with fixed columns, `time` and `synced` first, rate-limited for cellular, daily CSV files with the same clock handling. Their topics and columns are documented in their own repositories:

- `smartsolard`: [pysmartsolar docs/outputs.md](https://github.com/trackIT-Systems/pysmartsolar/blob/main/docs/outputs.md), bridge line `topic +/smartsolar/+/cbor out 1`
- `solarlifed`: [pysolarlife docs/outputs.md](https://github.com/trackIT-Systems/pysolarlife/blob/main/docs/outputs.md), bridge lines `topic +/solarlife/+/+/cbor out 1` and `topic +/solarlife/+/cbor out 1` (state and events)

## Collectors

| Collector | Default interval | Columns after `time;synced` |
| --- | --- | --- |
| `system` | 60 s | `uptime` (s, since boot), `load_1`, `load_5`, `load_15`, `mem_total`, `mem_available`, `mem_used`, `mem_percent`, `mem_free`, `mem_active`, `mem_inactive`, `mem_buffers`, `mem_cached`, `mem_shared`, `mem_slab` (bytes, %), `cpu_freq`, `cpu_freq_min`, `cpu_freq_max` (MHz) |
| `thermal` | 60 s | `soc`, `rp1`, `pmic` (°C) |
| `disk` | 60 s | `mount`, `total`, `used`, `free` (bytes), `percent`. One message per mounted mount point (default `/`, `/data`) |
| `pmic` | 60 s | `<rail>_A` for `3V7_WL_SW`, `3V3_SYS`, `1V8_SYS`, `DDR_VDD2`, `DDR_VDDQ`, `1V1_SYS`, `0V8_SW`, `VDD_CORE`, `3V3_DAC`, `3V3_ADC`, `0V8_AON`, `HDMI`; then `<rail>_V` for the same rails; then `EXT5V_V`, `BATT_V`, `BAT_RTC_V` (Raspberry Pi 5 only) |
| `throttled` | 60 s | `under_voltage`, `freq_capped`, `throttled`, `temp_limit`, `under_voltage_occurred`, `freq_capped_occurred`, `throttling_occurred`, `temp_limit_occurred`, `raw` |
| `clocks` | 60 s | `arm`, `core`, `h264`, `hevc`, `isp`, `v3d`, `uart`, `pwm`, `emmc`, `pixel`, `vec`, `hdmi`, `dpi` (Hz) |
| `voltages` | 60 s | `core`, `sdram_c`, `sdram_i`, `sdram_p` (V) |
| `wittypi` | 60 s | `voltage_in`, `voltage_out` (V), `current_out` (A), `power_ldo`, `temperature` (°C), `firmware_revision` |
| `network` | 600 s | `interface`, `present`, `up`, `ipv4`, `ipv6` (space-separated, without link-local), `rx_bytes`, `tx_bytes`. One message per configured interface (default `wireguard`, `eth0`, `wlan0`, `wwan0`); a missing one has `present` false |
| `modem` | 3600 s | `manufacturer`, `model`, `hardware_revision`, `imei`, `signal_strength_dbm`, `signal_strength_percent`, `access_technology`, `state`, `operator_name`, `ip_addresses`, `sim_iccid`, `sim_operator`, `sim_imsi`. Nothing is sent when there is no modem |
| `configs` | 3600 s | `file`, `present`, `mtime`, `size`. One message per configuration file tsconfig knows |
| `release` | 3600 s | `name`, `variant`, `version`, `codename`, `commit` (from `/etc/os-release`), `kernel`, `tsconfig` |

At startup, a collector whose hardware or tool is missing is skipped with one log line, e.g. no WittyPi board, no `vcgencmd`, or no `mmcli`. A collector that fails while running logs a warning once, and again when the error changes. It logs once more when it works again.

## Files

`/data/<host>/tsconfig/<collector>/<host>_<YYYY-MM-DD>_<collector>.csv`:
- `;` separated
- a header row at the top
- one file per collector and local calendar day

Files are only appended to, never rotated or deleted.

## Clock

A station without RTC, or without network, can run for a long time with a wrong clock. `tstelemetry` does not wait for `time-sync.target`. Instead:

- It reads the kernel's clock state with `adjtimex`. chrony clears `STA_UNSYNC` once it has synced. Once seen synced, the clock counts as synced for the rest of the boot; a marker in `/run/tstelemetry` keeps this across restarts of the daemon.
- **Before the sync**, MQTT messages are sent live with `synced` false. Readings for the files go to a spool, `/data/<host>/tsconfig/.spool/<boot_id>.jsonl`, together with the time since boot (`CLOCK_BOOTTIME`).
- **At the sync**, every spooled reading gets the time *now − (boottime now − boottime of the reading)*. It is then appended to the file of its day, still with `synced` false, and the spool is removed.
- **A spool from an earlier boot** that never synced cannot be corrected, because its boot clock is lost. At the next start it is written to `<host>_unsynced_<boot_id>_<collector>.csv` with the times as recorded, and removed.

## Settings

`/etc/tsconfig/tstelemetry.yml` is root-owned build-time data, installed from tsconfig's [`configs/tstelemetry.yml`](../usr/local/src/tsconfig/configs/tstelemetry.yml) like `tsconfig.yml`. It is not on the boot partition, not part of config bundles, and tsconfig has no page for it. Every missing key takes the default shown in the shipped file. An invalid file is logged and ignored (defaults apply), so a broken image change does not silence a station. `tstelemetry -c <file>` reads another file, for testing.

`tstelemetry --once -v` reads every collector once and prints the JSON payloads, without publishing or writing files.

## Migrating from mqttutil

The old topics `<host>/mqttutil/<task>` are gone. Old config bundles that contain `mqttutil.conf` are still accepted; that file is skipped. Existing `/data/*.jsonl` files of mqttutil are left as they are.

| mqttutil task | New collector and columns |
| --- | --- |
| `uptime`, `load`, `memory`, `cpufreq` | `system` |
| `temperature`, `rp1`, `pmic`, `vcgencmd_temperature` | `thermal` (`soc`, `rp1`, `pmic`) |
| `diskusage/data` | `disk` (`mount` = `/data`) |
| `ifaddr/wireguard` | `network` (`interface` = `wireguard`) |
| `modem` | `modem` |
| `wittypi4` | `wittypi` |
| `tsconfig` (config files) | `configs` |
| `release` | `release` |
| `vcgencmd_pmic`, `vcgencmd_throttled`, `vcgencmd_clocks`, `vcgencmd_voltages` | `pmic`, `throttled`, `clocks`, `voltages` |

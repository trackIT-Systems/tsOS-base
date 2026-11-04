# Telemetry (`tstelemetry`)

`tstelemetry.service` publishes the device's health over MQTT and writes it to daily CSV files. It replaces `mqttutil`. Its code is the `app.telemetry` package of [tsconfig](../usr/local/src/tsconfig), but it runs as a process of its own, so telemetry continues while the web UI is down or being updated.

Each kind of data comes from one **collector**, a Python module in [app/telemetry/collectors](../usr/local/src/tsconfig/app/telemetry/collectors). The settings file, `/etc/tsconfig/tstelemetry.yml`, only switches collectors on and off and sets their intervals. It cannot run code, unlike `mqttutil.conf`, and it is not operator configuration.

## MQTT

| Topic | Payload | Retained |
| --- | --- | --- |
| `<host>/tsconfig/<collector>/csv` | one `;`-separated line, no header | no |
| `<host>/tsconfig/<collector>/json` | object, keys in column order | no |
| `<host>/tsconfig/<collector>/cbor` | array, values in column order | no |
| `<host>/tsconfig/journal/<unit>/<level>/<format>` | journal entries, see [Logging](logging.md#forwarding-over-mqtt) | no |

- `<host>` is the hostname.
- QoS is 0, and messages are dropped while the broker is unreachable. The bridge does not queue them while the uplink is down either, see [MQTT](mqtt.md#qos-decides-what-is-queued).
- Nothing is retained, and there is no online/offline topic or last will. A station or collector that stops shows as missing readings.
- A collector that reports several things (disks, interfaces, config files) sends one message per thing.

A reading is a snapshot of now and carries **no time**: it arrives within seconds, or not at all, so the receiver stamps it on arrival (InfluxDB through Telegraf does by default). The station's own clock is a reading of its own, the `timesync` collector. See [Time](time.md#station-services).

All three formats carry the collector's columns, listed below, in the same order. A value the device cannot provide is `null` (empty in CSV). CBOR has no key names, which keeps cellular traffic small. Its field order is the column order listed here, which is also the CSV file header after `time`.

For the cellular bridge, forwarding CBOR is enough:

```
topic +/tsconfig/+/cbor out 1
```

`+/tsconfig/+/cbor` includes `journalstats`, but not the journal entries, which are one level deeper. Which of them leave the station is chosen per unit and level, see [Logging](logging.md#topics).

### Other publishers on the station

The charge controller daemons publish in the same style: CSV, JSON and CBOR with fixed columns and no time, nothing retained, rate-limited for cellular, and daily CSV files only once the clock is trusted. Their topics and columns are documented in their own repositories:

- `smartsolard`: [pysmartsolar docs/outputs.md](https://github.com/trackIT-Systems/pysmartsolar/blob/main/docs/outputs.md), bridge line `topic +/smartsolar/+/cbor out 1` (readings and events)
- `solarlifed`: [pysolarlife docs/outputs.md](https://github.com/trackIT-Systems/pysolarlife/blob/main/docs/outputs.md), bridge lines `topic +/solarlife/+/+/cbor out 1` (readings) and `topic +/solarlife/events/cbor out 1` (events)

## Collectors

| Collector | Default interval | Columns |
| --- | --- | --- |
| `timesync` | 60 s | `source` (`none`, `rtc`, `ntp` or `gnss`: what chrony follows), `stratum`, `error_s` (chrony's bound on the clock's error: half the root delay plus the root dispersion), `station_time` (the station's clock, ISO 8601 with UTC offset; compared with the arrival time, it shows how far the station is off). `stratum` and `error_s` are null without a source. Skipped without `chronyc` |
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
| `journalstats` | 600 s | `unit`, `level`, `entries`, `dropped`. One message per unit and level that logged in the interval; `dropped` counts what the journal limits held back (see [Logging](logging.md#counts)). Skipped when `journal.enabled` is off |

At startup, a collector whose hardware or tool is missing is skipped with one log line, e.g. no WittyPi board, no `vcgencmd`, or no `mmcli`. A collector that fails while running logs a warning once, and again when the error changes. It logs once more when it works again.

## Files

`/data/<host>/tsconfig/<collector>/<host>_<YYYY-MM-DD>_<collector>.csv`:
- `;` separated
- a header row at the top
- `time` first (when the reading was taken, ISO 8601 with the station's UTC offset), then the collector's columns
- one file per collector and local calendar day

Files are only appended to, never rotated or deleted.

## Clock

`tstelemetry` is a station service and does not wait for `time-sync.target` ([Time](time.md)): its readings are needed to see why a station has no trusted clock. It reads the kernel's clock state with `adjtimex`. chrony clears `STA_UNSYNC` once it has a source (NTP, GNSS or the RTC checked by tsscheduled). Once seen synced, the clock counts as synced for the rest of the boot; a marker in `/run/tstelemetry` keeps this across restarts of the daemon.

- **Before that**, readings only go over MQTT. The files get nothing: there is no spool and no re-timing. Dropping rows is logged once when it starts and once when it ends.
- **From then on**, every reading also goes to its day's file.

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

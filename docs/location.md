# Location (`tslocation`)

> **Status: concept.** Not implemented yet. This page describes the planned design. Parts that still have to be verified on hardware are listed under [Open points](#open-points).

Until now, a station's location has been the fixed position in `/boot/firmware/geolocation`. `tslocation.service` adds measured positions for stations that can be moved, and tracks for stations that move (transect walks). It runs in one of three modes. It reports what it measures to the server and never changes the configured position itself.

Like `tstelemetry`, its code is a package of [tsconfig](../usr/local/src/tsconfig) (`app/location`), but it runs as a process of its own. Most of the work is done by gpsd and ModemManager. The daemon decides when the GNSS receiver runs, compares positions, and publishes the results.

## Positions

The daemon keeps three positions apart:

| Position | Meaning | Where | Written by |
| --- | --- | --- | --- |
| **reference** | Where the station is supposed to be | `/boot/firmware/geolocation` (geoclue format: lat, lon, alt, accuracy) | the server or operator only, **never by the device** |
| **measured** | The latest GNSS fix | `/run/tslocation/` | `tslocation` |
| **effective** | What other services should use | `/run/tslocation/` | `tslocation` |

The **effective** position is the reference, except in `mobile` mode while there is a current fix. A station whose measured position differs from the reference keeps using the reference until someone on the server adopts the new position. This is how stations behave today.

If the reference file is missing, the effective position is the latest fix (if any); otherwise there is none.

Where the daemon keeps its data:

| Path | Contents | Lifetime |
| --- | --- | --- |
| `/run/tslocation/` | Measured and effective position, for other services ([Outputs](#files-in-runtslocation)) | until shutdown |
| `/var/lib/tslocation/state.json` | Coarse check state: the known cells and the latest fine fix | persistent (the root file system's overlay is persistent) |
| `/data/<host>/tslocation/` | Log of fixes, tracks and cells ([Outputs](#files-in-data)) | persistent, never rotated |

## Modes

The mode is set by the server in the settings file (see [Settings](#settings)).

### `off`

No position checks and no reports. The effective position is the reference. GNSS still runs when the clock needs it (see [Time](#time)).

### `stationary`

For stations that stay in one place. GNSS runs only for a **fine fix**: the receiver is switched on, the daemon waits for a fix, averages the positions for `fix_duration`, and switches the receiver off again. Fine fixes are expensive in power, so they are only made when they are needed:

1. **At boot**, a [coarse check](#coarse-check). A fine fix follows if the coarse check sees a change, if there is no fine fix yet, or if the last one is older than `fix_max_age`. Stations with a WittyPi schedule may boot several times a day, so a fine fix at every boot would cost too much.
2. **While running**, a coarse check every `check_interval`, with the same rule.
3. A fine fix further than `threshold` from the reference sets the state to **`deviating`**. While deviating, a fine fix is made every `recheck_interval`.
4. When `settle_count` fixes in a row agree within their accuracy, the state becomes **`proposed`**. Their averaged position is reported as the **proposed reference**. The user can adopt it on the server, which writes `geolocation` through the normal config deployment.
5. When a fine fix is within `threshold` of the reference again, the state goes back to **`confirmed`**.

### `mobile`

For stations that move. GNSS stays on. A fix is recorded every `track_interval` or every `track_distance`, whichever comes first, to the track file. It is sent over MQTT at the slower `publish_interval`, to keep cellular traffic small. The effective position is the latest fix. If there is no fix, the last fix is used while it is younger than `fix_timeout`, then the reference.

### States

| State | Meaning |
| --- | --- |
| `unknown` | No fine fix yet |
| `confirmed` | Last fine fix within `threshold` of the reference |
| `deviating` | Last fine fix further than `threshold` from the reference |
| `proposed` | Deviating, and `settle_count` fixes agree; a proposed reference is reported |
| `tracking` | `mobile` mode with a current fix |
| `no_fix` | GNSS ran for `fix_timeout` without a fix |

## Coarse check

The coarse check decides whether a fine fix is needed, without switching the GNSS receiver on. It does not compute coordinates: that would need an online lookup service, and cell-based positions are too coarse to notice that a station was moved by 50 m.

Instead, the daemon keeps the list of **cells seen at the confirmed position**: every serving cell (MCC, MNC, TAC/LAC, cell ID) that ModemManager reports (its `3gpp` location source) while the station is at a confirmed position.

- A serving cell that is in the list is normal: the network hands a station over between nearby cells even when the station stands still. Nothing happens.
- A serving cell that is not in the list triggers a fine fix. If the fix confirms the position, the cell is added to the list. After a few days at a site the list is complete and these extra fixes stop.
- A fine fix at a new position (state `deviating`) starts a new list.

The list is kept in `/var/lib/tslocation/state.json`, together with the latest fine fix, which the boot check compares against `fix_max_age`. The root file system's overlay is persistent, so both survive reboots.

Neighbour cells (ModemManager's `GetCellInfo`) would make the check more precise, but most of the AT- and PPP-based modems we use only report the serving cell. Visible Wi-Fi networks can be added to the check where `wlan0` is not running as an access point; on stations where it is, a scan would interrupt the access point.

A station without a modem gets no coarse check. It only makes a fine fix at boot when the last one is older than `fix_max_age`.

The cells are also reported to the server (see [MQTT](#mqtt)), so the server can look up a rough position for a station that has no GNSS fix.

## Receivers

gpsd is the only program that reads position data. `tslocation` takes its fixes from gpsd (`localhost:2947`) for every type of receiver. Each type only needs its own way to be switched on and off.

### GNSS in the LTE modem (supported)

ModemManager switches the modem's GNSS on and off, and gpsd reads the positions:

- `tslocation` enables ModemManager's **`gps-unmanaged`** location source (`mmcli -m <n> --location-enable-gps-unmanaged`, over D-Bus). ModemManager starts the modem's GNSS but does not read the modem's NMEA port, so gpsd can.
- A udev rule gives the modem's NMEA port a stable name and adds it to gpsd (`gpsdctl add`). `/etc/default/gpsd` keeps `DEVICES=""` and `USBAUTO="false"`.
- Disabling the source switches GNSS off. While it is off, gpsd sees a silent device.
- Where the modem supports it, `tslocation` injects assistance data (`InjectAssistanceData`) before a fix, so the first fix comes sooner.

ModemManager's other GPS modes (`gps-nmea`, `gps-raw`) make ModemManager read the NMEA port itself, which leaves gpsd and chrony without data. They are not used.

### USB receivers (later)

gpsd reads them directly, and ModemManager has no part in it. ModemManager has to be kept from probing their serial port with AT commands, with `ID_MM_DEVICE_IGNORE` in udev, as in [`50-vedirect.rules`](../etc/udev/rules.d/50-vedirect.rules). ModemManager already ignores many GPS receivers, including u-blox. Switching off is a standby command sent through gpsd (`ubxtool` for u-blox), or the receiver stays on. Whether gpsd reads the receiver makes no difference to power; only switching the receiver itself does.

### geoclue

geoclue is not used:
- Its Wi-Fi and cell sources resolve positions through a web service.
- It reads the modem's GNSS in `gps-nmea` mode, which takes the NMEA port away from gpsd and chrony.
- It has no gpsd source.
- It would return the reference position from `/etc/geolocation` as if it were measured.

Only the format of `/boot/firmware/geolocation` comes from geoclue. The `geoclue-2.0` package can be removed from the image.

## Time

On a station without network, GNSS is the only time source. chrony reads the time from gpsd (`refclock SHM 0`, [gps.conf](../etc/chrony/conf.d/gps.conf)). When GNSS is switched off most of the time, chrony only gets time during fine fixes.

So in every mode, including `off`, `tslocation` makes a fine fix when chrony has not used a time source for longer than `time_max_age`. In `off` mode, that fix is not reported. The accuracy is that of NMEA without PPS, around 100 ms, the same as today.

## Outputs

### Files in `/run/tslocation`

Services read the location from files, which they can watch with inotify or a systemd `.path` unit. Both files are written atomically (write a temporary file, then rename). They exist as soon as the daemon has started, and are created from the reference if there is no fix yet.

`/run/tslocation/location.json`:

```json
{
  "mode": "stationary",
  "state": "confirmed",
  "effective": {"lat": 50.81, "lon": 8.77, "alt": 210.0, "accuracy": 5.0, "source": "reference"},
  "reference": {"lat": 50.81, "lon": 8.77, "alt": 210.0, "accuracy": 5.0},
  "fix": {"time": "2026-10-22T14:00:00+02:00", "lat": 50.8101, "lon": 8.7702, "alt": 212.3,
          "accuracy": 4.1, "sats": 9, "hdop": 0.9},
  "deviation_m": 18.2,
  "proposed": null
}
```

- `effective.source` is `reference` or `gnss`.
- `fix` is the latest fine fix, or `null`.
- `proposed` is the proposed reference (`lat`, `lon`, `alt`, `accuracy`) in state `proposed`, otherwise `null`.

`/run/tslocation/geolocation` holds the effective position in geoclue format. `/etc/geolocation` points to this file instead of `/boot/firmware/geolocation`, so tsschedule and other existing readers get the effective position without a change.

### gpsd

Services that need positions continuously in `mobile` mode connect to gpsd (`localhost:2947`, JSON).

### MQTT

Same conventions as [Telemetry](telemetry.md#mqtt): CSV, JSON and CBOR with fixed columns, `time` and `synced` first, QoS 0.

| Topic | Columns after `time;synced` | Retained | Sent |
| --- | --- | --- | --- |
| `<host>/tslocation/fix/<format>` | `source`, `lat`, `lon`, `alt`, `accuracy`, `sats`, `hdop`, `deviation_m` | no | every fine fix; in `mobile` mode every `publish_interval` |
| `<host>/tslocation/state/<format>` | `mode`, `state`, `effective_lat`, `effective_lon`, `deviation_m`, `proposed_lat`, `proposed_lon`, `proposed_alt`, `proposed_accuracy` | yes | on every change |
| `<host>/tslocation/cell/<format>` | `mcc`, `mnc`, `tac`, `cell_id`, `known` | no | when the serving cell changes |

Bridge line for the cellular connection:

```
topic +/tslocation/+/cbor out 1
```

### Files in `/data`

`/data/<host>/tslocation/<kind>/<host>_<YYYY-MM-DD>_<kind>.csv`, with `<kind>` `fix`, `track` (`mobile` mode) and `cell`. The columns are those of the MQTT topic. The clock handling for readings taken before the clock is synced is the same as in [Telemetry](telemetry.md#clock). Fixes are an exception: their time comes from GNSS, so `synced` is true.

### tsconfig

`GET /api/location` returns `location.json`. The status page shows the reference and the latest fix on the map, the deviation and the state.

## Settings

`/boot/firmware/tslocation.yml` is set by the server, like `envsense.yml`. A missing file or key takes the default.

| Key | Default | Meaning |
| --- | --- | --- |
| `mode` | `stationary` | `off`, `stationary` or `mobile` |
| `receiver` | `modem` | `modem` (later `usb`) |
| `fix_duration` | `60 s` | How long a fine fix averages positions |
| `fix_timeout` | `300 s` | How long GNSS may run without a fix |
| `fix_max_age` | `7 d` | Fine fix at boot when the last one is older |
| `check_interval` | `1 h` | Coarse check while running |
| `threshold` | `50 m` | Distance from the reference that counts as deviating |
| `recheck_interval` | `6 h` | Fine fix interval while deviating |
| `settle_count` | `3` | Agreeing fixes for a proposed reference |
| `track_interval` | `5 s` | `mobile`: record a fix at least this often |
| `track_distance` | `10 m` | `mobile`: record a fix after this distance |
| `publish_interval` | `60 s` | `mobile`: MQTT rate |
| `time_max_age` | `24 h` | Fine fix for the clock when chrony has had no source for longer |

The defaults are a starting point and still need to be tested in the field.

## Open points

- **Modem support for `gps-unmanaged`**: not every ModemManager plugin supports it or recognises the NMEA port. To check, per modem with GNSS:
  ```
  mmcli -m 0 --location-status
  mmcli -m 0 --location-enable-gps-unmanaged && gpspipe -w -n 10
  ```
- **Assistance data and cell info** per modem: whether `InjectAssistanceData` and `GetCellInfo` work.
- **Power cost of a fine fix** per modem: time to the first fix with and without assistance data, and the current drawn while GNSS runs, to choose `fix_max_age` and `check_interval`.

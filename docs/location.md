# Location (`tslocation`)

> **Status: first implementation.** What is not implemented yet, and what still has to be verified on hardware, is listed under [Open points](#open-points).

Until now, a station's location has been the fixed position in `/boot/firmware/geolocation`. `tslocation.service` adds measured positions for stations that can be moved, and tracks for stations that move (transect walks). It runs in one of three modes. It reports what it measures to the server and never changes the configured position itself.

Like `tstelemetry`, its code is a package of [tsconfig](../usr/local/src/tsconfig) (`app/location`), but it runs as a process of its own: `tslocation.service` runs `tslocationd`, as `pi`. Most of the work is done by gpsd and ModemManager. The daemon decides when the GNSS receiver runs, compares positions, and publishes the results.

## Positions

The daemon keeps three positions apart:

| Position | Meaning | Where | Written by |
| --- | --- | --- | --- |
| **reference** | Where the station is supposed to be | `/boot/firmware/geolocation` (geoclue format: lat, lon, alt, accuracy) | the server or operator only, **never by the device** |
| **measured** | The latest GNSS fix | `/run/tslocation/` | `tslocation` |
| **effective** | What other services should use | `/run/tslocation/` | `tslocation` |

The **effective** position is the reference, except in `mobile` mode while there is a current fix. A station whose measured position differs from the reference keeps using the reference until someone on the server adopts the new position. This is how stations behave today.

If the reference file is missing, the effective position is the latest fix (if any); otherwise there is none. Without a reference, every fine fix counts as deviating, so agreeing fixes settle into a proposed reference, which the server can adopt as the first one.

Where the daemon keeps its data:

| Path | Contents | Lifetime |
| --- | --- | --- |
| `/run/tslocation/` | Measured and effective position, for other services ([Outputs](#files-in-runtslocation)) | until shutdown |
| `/var/lib/tslocation/state.json` | The state, the known cells, the latest fine fix and the run of agreeing fixes (see [States](#states)) | persistent (the root file system's overlay is persistent) |
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

For stations that move. GNSS stays on. A fix is recorded every `track_interval` or every `track_distance`, whichever comes first, to the track file and the `track` topic. The receiver reports once per GNSS second, and the interval is counted in GNSS time, so with the default of 1 s every second of the track is a point, aligned to the GNSS second. (gpsd sends several reports per second, one per NMEA sentence; only the first of each second counts. A PPS pulse is not needed for this, and USB modems do not provide one.) The bridge decides whether the track leaves the station: at 1 s it is about 3600 messages an hour. The effective position is the latest fix. If there is no fix, the last fix is used while it is younger than `fix_timeout`, then the reference.

The state is `unknown` until the first fix arrives, or until GNSS has run for `fix_timeout` without one (`no_fix`).

### States

| State | Meaning |
| --- | --- |
| `unknown` | No fine fix yet, or no receiver could be switched on |
| `confirmed` | Last fine fix within `threshold` of the reference |
| `deviating` | Last fine fix further than `threshold` from the reference |
| `proposed` | Deviating, and `settle_count` fixes agree; a proposed reference is reported |
| `tracking` | `mobile` mode with a current fix |
| `no_fix` | GNSS ran for `fix_timeout` without a fix |

The fixes that "agree" are the latest fine fixes that are within their accuracy of each other (every two of them no further apart than the sum of their accuracies), at most `settle_count`. A fix that does not agree with them starts a new run. The proposed reference is their average, and its accuracy is the mean of theirs. The run is kept in `state.json`, so a station that boots several times a day still settles. While `no_fix`, the daemon remembers whether the last fix was deviating, so the `recheck_interval` still applies.

## Coarse check

The coarse check decides whether a fine fix is needed, without switching the GNSS receiver on. It does not compute coordinates: that would need an online lookup service, and cell-based positions are too coarse to notice that a station was moved by 50 m.

Instead, the daemon keeps the list of **cells seen at the confirmed position**: every serving cell (MCC, MNC, TAC/LAC, cell ID) that ModemManager reports (its `3gpp` location source) while the station is at a confirmed position.

- A serving cell that is in the list is normal: the network hands a station over between nearby cells even when the station stands still. Nothing happens.
- A serving cell that is not in the list triggers a fine fix. If the fix confirms the position, the cell is added to the list. After a few days at a site the list is complete and these extra fixes stop.
- A fine fix at a new position (state `deviating`) starts a new list. Further fixes at that new position add their cells to it, so a deviating station is not re-checked at every coarse check.

The list is kept in `/var/lib/tslocation/state.json`, together with the latest fine fix, which the boot check compares against `fix_max_age`. The root file system's overlay is persistent, so both survive reboots.

Neighbour cells (ModemManager's `GetCellInfo`) would make the check more precise, but most of the AT- and PPP-based modems we use only report the serving cell. Visible Wi-Fi networks can be added to the check where `wlan0` is not running as an access point; on stations where it is, a scan would interrupt the access point. *Neither is implemented yet.*

A station without a modem gets no coarse check. It only makes a fine fix at boot when the last one is older than `fix_max_age`.

The cells are also reported to the server (see [MQTT](#mqtt)), so the server can look up a rough position for a station that has no GNSS fix.

## Receivers

gpsd is the only program that reads position data. `tslocation` takes its fixes from gpsd (`localhost:2947`) for every type of receiver. Each type only needs its own way to be switched on and off.

### GNSS in the LTE modem (supported)

ModemManager switches the modem's GNSS on and off, and gpsd reads the positions:

- `tslocation` enables ModemManager's **`gps-unmanaged`** location source (`mmcli -m <n> --location-enable-gps-unmanaged`, over D-Bus). ModemManager starts the modem's GNSS but does not read the modem's NMEA port, so gpsd can.
- A udev rule, [`80-tslocation-gnss.rules`](../etc/udev/rules.d/80-tslocation-gnss.rules), gives the port that ModemManager marks as the modem's NMEA port (`ID_MM_PORT_TYPE_GPS`) a name next to the kernel's (`/dev/ttyUSB1` → `/dev/ttyUSBgnss1`) and has [`tsos-gpsd-add@.service`](../etc/systemd/system/tsos-gpsd-add@.service) add it to gpsd (`gpsdctl add`) once `gpsd.socket` is up. Run from the rule directly, `gpsdctl` would start a gpsd of its own at boot, which takes the socket's port. `/etc/default/gpsd` keeps `DEVICES=""` and `USBAUTO="false"`, which also keeps Debian's `gpsdctl@.service` out, and runs gpsd read-only (`-b`): gpsd's probes would block on the NMEA port while the GNSS is off (seen with a Quectel EG21-G), and with them all of gpsd.
- `tslocationd` runs as `pi`. ModemManager only lets the active local session switch location sources, so [`40-tsos-modemmanager-location.rules`](../etc/polkit-1/rules.d/40-tsos-modemmanager-location.rules) grants `pi` the actions `org.freedesktop.ModemManager1.Location` and `org.freedesktop.ModemManager1.Device.Control` (see [Security Design](security.md#location-daemon)).
- Disabling the source switches GNSS off. While it is off, gpsd sees a silent device.
- Where the modem supports it, `tslocation` injects assistance data (`InjectAssistanceData`) before a fix, so the first fix comes sooner. *Not implemented yet.*

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

So in every mode, including `off`, `tslocation` makes a fine fix when chrony has not used a time source for longer than `time_max_age`. In `off` mode, that fix is not reported. The accuracy is that of NMEA without PPS, around 100 ms, the same as today. How the clock gates the observation services: [time.md](time.md).

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
  "fixing": false,
  "proposed": null
}
```

- `effective.source` is `reference` or `gnss`.
- `fix` is the latest fine fix, or `null`.
- `proposed` is the proposed reference (`lat`, `lon`, `alt`, `accuracy`) in state `proposed`, otherwise `null`.
- `fixing` is true while a fine fix runs.

`/run/tslocation/geolocation` holds the effective position in geoclue format. `/etc/geolocation` points to this file instead of `/boot/firmware/geolocation`, so tsschedule and other existing readers get the effective position without a change.

### gpsd

Services that need positions continuously in `mobile` mode connect to gpsd (`localhost:2947`, JSON).

### MQTT

Same conventions as [Telemetry](telemetry.md#mqtt): CSV, JSON and CBOR with fixed columns, `time` and `synced` first, QoS 0.

| Topic | Columns after `time;synced` | Retained | Sent |
| --- | --- | --- | --- |
| `<host>/tslocation/fix/<format>` | `source`, `lat`, `lon`, `alt`, `accuracy`, `sats`, `hdop`, `deviation_m` | no | every fine fix |
| `<host>/tslocation/track/<format>` | as `fix` | no | `mobile` mode: every track point |
| `<host>/tslocation/state/<format>` | `mode`, `state`, `effective_lat`, `effective_lon`, `deviation_m`, `proposed_lat`, `proposed_lon`, `proposed_alt`, `proposed_accuracy` | yes | on every change; in `mobile` mode when the mode or state changes |
| `<host>/tslocation/cell/<format>` | `mcc`, `mnc`, `tac`, `cell_id`, `known` | no | when the serving cell changes |

- `source` is the receiver the fix came from (`modem`).
- The `time` of a fix is its GNSS time. `alt` is above mean sea level, null for a 2D fix. `accuracy` is gpsd's estimated horizontal error (`eph`) in metres.
- In `off` mode nothing is published, and `cell` messages are not sent either.

Bridge line for the cellular connection (it includes the `track` topic of mobile stations; list `fix`, `state` and `cell` instead to leave the track on the station):

```
topic +/tslocation/+/cbor out 1
```

### Files in `/data`

`/data/<host>/tslocation/<kind>/<host>_<YYYY-MM-DD>_<kind>.csv`, with `<kind>` `fix`, `track` (`mobile` mode) and `cell`. The columns are those of the MQTT topic. The clock handling for readings taken before the clock is synced is the same as in [Telemetry](telemetry.md#clock). Fixes are an exception: their time comes from GNSS, so `synced` is true, and they go to their day's file at once.

### tsconfig

`GET /api/location` returns `location.json`. The status page shows the reference and the latest fix on the map (a violet dot with its accuracy, refreshed every 10 s), zoomed so both are visible when the map opens, and the deviation and the state.

In `stationary` mode, **Measure with GPS** on the status page makes a fine fix at once (`POST /api/location/fix`, which sends `fix` to the control socket without waiting). The fix counts like any other: it is reported, and it can move the state.

### Control socket and `tslocation`

The daemon answers requests on `/run/tslocation/tslocation.sock` (mode 0660, owner `pi`: `pi` and `root` can use it). The protocol is that of `solarlifed` and `smartsolard`: one JSON object per line in both directions, `{"id": 1, "cmd": "status", "args": {}}` → `{"id": 1, "ok": true, "result": {...}}` or `{"id": 1, "ok": false, "error": {"type": "...", "message": "..."}}`. There is no authentication beyond the file permissions.

| Command | Arguments | Result |
| --- | --- | --- |
| `status` | | `version`, `uptime_s`, `receiver`, `next_check_in_s`, `failures` (what currently fails), `location` (as `location.json`) |
| `fix` | `wait` (default true) | a fine fix now, `stationary` mode only; with `wait` the location after it, else `{"requested": true}`. Errors `not_available` (another mode), `no_receiver`, `no_fix` |
| `cells` | | `current` (the serving cell), `current_known`, `known` (the cells seen at this position) |
| `config` | | `path` of the settings file and the `settings` in effect (durations in seconds) |
| `watch` | | streams: `{"id": ..., "ok": true, "event": {...}}` with the content of `location.json`, at once and at every change, until the client closes the connection (in `mobile` mode once per GNSS second) |

Other error types: `bad_request`, `unknown_command`, `internal`.

`tslocation` is the command line client (part of tsconfig):

```
tslocation status            mode, state, positions, deviation, problems
tslocation fix [--no-wait]   make a fine fix now and print it
tslocation watch             follow the location as it changes
tslocation cells             the serving cell and the cells known at this position
tslocation config            the settings in effect, and which come from tslocation.yml
tslocation mode [MODE]       show the mode, or set it in tslocation.yml and restart tslocation
```

`tslocation` without a command shows the status. Every command takes `--json` for the daemon's answer. `mode` writes the settings file through tsconfig's privileged write path, as the settings page does, and restarts the service (`--no-restart` only writes). Exit codes: 0 ok, 1 the daemon answered with an error, 2 usage error, 3 the daemon cannot be reached.

## Settings

`/boot/firmware/tslocation.yml` is set by the server, like `envsense.yml`. A missing file or key takes the default; an invalid file is logged and ignored (all defaults apply). Durations are seconds (`3600`) or a string such as `60s`, `1h`, `7d`; distances are metres. The daemon reads the file when it starts. tsconfig accepts it in config bundles (validated with the daemon's own settings model) and restarts `tslocation.service` after writing it.

tsconfig edits the file in **System Settings > Location**, on a station and in a server's config groups (where it is part of the versioned group files and deployed with them). The mode is a normal setting; the other keys are shown in expert mode. A field left empty is not written, so the daemon's default applies, shown as placeholder (`GET /api/tslocation/defaults`). The image ships the file with `mode` only, so a later change of a default reaches stations that never set the key.

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
| `track_interval` | `1 s` | `mobile`: record a fix at least this often (GNSS time) |
| `track_distance` | `10 m` | `mobile`: record a fix after this distance |
| `time_max_age` | `24 h` | Fine fix for the clock when chrony has had no source for longer |

The defaults are a starting point and still need to be tested in the field.

## Open points

- **Not implemented yet:** assistance data (`InjectAssistanceData`), neighbour cells and Wi-Fi for the coarse check, USB receivers (`receiver: usb`).
- **Verified:** Quectel EG21-G (`2c7c:0121`, firmware EG21GGBR07A11M1G): ModemManager supports `gps-unmanaged` and marks `ttyUSB1` as the NMEA port; gpsd reads it, and a fine fix of 60 s gave 180 positions (8 satellites, ±17 m). Switching a source needs `Device.Control`, reading the serving cell `Location`.
- **Modem support for `gps-unmanaged`**: not every ModemManager plugin supports it or recognises the NMEA port. To check, per modem with GNSS:
  ```
  mmcli -m 0 --location-status
  mmcli -m 0 --location-enable-gps-unmanaged && gpspipe -w -n 10
  ```
- **Assistance data and cell info** per modem: whether `InjectAssistanceData` and `GetCellInfo` work.
- **Power cost of a fine fix** per modem: time to the first fix with and without assistance data, and the current drawn while GNSS runs, to choose `fix_max_age` and `check_interval`.

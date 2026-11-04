# Time

An observation is only worth something if its time can be compared with other stations and with the real world. Many stations have no network, and some have no RTC. So tsOS splits its services in two groups:

- **Station services** run, manage and report on the station itself. They start at boot, with whatever clock there is: they are needed to get a trusted clock, or to see why there is none. What they report is marked as synced or not.
- **Observation services** observe the world: they record detections, audio and measurements. They start only once the clock has been set from a trusted source. Without one, they do not start at all.

## Trusted sources

The clock counts as trusted once one of these has set it:

| Source | How | Notes |
|---|---|---|
| NTP | chrony, Debian's default pools | needs a network connection (LAN, WLAN or LTE) |
| GNSS | chrony reads gpsd's shared memory: `refclock SHM 0` (NMEA) and `SHM 1` (PPS), [gps.conf](../etc/chrony/conf.d/gps.conf) | The LTE modem's GNSS is off most of the time. `tslocationd` makes a fine fix whenever chrony has had no source since it started, or for longer than `time_max_age` (24 h), in every mode, including `off` ([location.md](location.md#time)). Without PPS, the accuracy is around 100 ms |
| RTC | checked by `tsscheduled` at its start (WittyPi 4, or the Raspberry Pi 5's own RTC) | see [RTC check](#rtc-check) |

Two things set the clock at boot without making it trusted:

- systemd moves the clock forward to the mtime of `/var/lib/systemd/timesync/clock`. The image build touches that file, so the clock never starts before the build date.
- The kernel reads the RTC, if there is one.

## The gate: `time-sync.target`

`time-sync.target` is reached only once the clock is trusted. There are two ways to get there.

1. **chrony syncs.** `chrony-wait.service` (chrony's own unit, enabled in the image) runs `chronyc waitsync` and is ordered before `time-sync.target`. The drop-in [override.conf](../etc/systemd/system/chrony-wait.service.d/override.conf) removes its 3-minute timeout. Without that, `chrony-wait` would fail after 3 minutes, and `time-sync.target` would be reached anyway, because it only `Wants=` `chrony-wait`.
2. **The RTC passes the check.** `tsscheduled` touches `/run/systemd/timesync/synchronized`. [chrony-wait-stop.path](../etc/systemd/system/chrony-wait-stop.path) sees the file and starts [chrony-wait-stop.service](../etc/systemd/system/chrony-wait-stop.service), which stops `chrony-wait`. Then `time-sync.target` is reached. `tsschedule.service` is ordered before `time-sync.target`.

Nothing else writes `/run/systemd/timesync/synchronized`. chrony does not, and `systemd-timesyncd` is not installed.

### RTC check

At its start, `tsscheduled` ([scheduled.py](../usr/local/src/tsschedule/tsschedule/scheduled.py)) trusts the RTC only if both of these hold:

- **Not before the last known time.** The RTC is not older than the newest of `/etc/fake-hwclock.data`, the mtime of `/var/lib/systemd/timesync/clock` and the mtime of `/var/lib/chrony/chrony.drift`. An RTC that lost its battery fails this test.
- **Matches the system clock.** The RTC is within 5 s of the system clock.

If a test fails, `tsscheduled` logs `RTC is implausible` or `RTC does not match system clock` and exits with 3. systemd starts it again after 300 s.

The check only gives a lower bound: an RTC that is ahead of the real time passes. The mtime of `timesync/clock` is the build date, because nothing updates it after the build.

## Station services

These start at boot without waiting for `time-sync.target`. Those that publish records (telemetry, charge controllers, location) give each one a `synced` column. Readings for the daily files are spooled until the sync and re-timed from `CLOCK_BOOTTIME` then ([telemetry.md](telemetry.md#clock)).

| Service | Repository |
|---|---|
| `tstelemetry.service` | tsOS-base (tsconfig) |
| `smartsolar.service`, `solarlife.service` | tsOS-base (pysmartsolar, pysolarlife) |
| `tslocation.service` | tsOS-base (tsconfig). GNSS fixes take their time from GNSS, so they are always `synced` |
| `tsconfig.service`, `tsconfig-ble.service` | tsOS-base |
| `tsschedule.service` | tsOS-base. Needs `time-set.target` only; it is one of the ways to `time-sync.target` |

## Observation services

These wait for a trusted clock and do not start without one. They do not spool or re-time anything: what they write always has a trusted time. A station that never gets a trusted clock records nothing, rather than records operators might take for real.

| Service | Repository |
|---|---|
| `envsense.service` | tsOS-base |
| `radiotracking.service` | tsOS-vhf |
| `soundscapepipe.service`, `lightbarrier.service` | tsOS-audio |

Every observation service has both lines in its unit:

```ini
[Unit]
After=time-sync.target
Requires=time-sync.target
```

`After=` alone would also wait at boot, but only because `chrony-wait` happens to pull in `time-sync.target`. `Requires=` makes the dependency explicit.

## A station without a trusted clock

At boot the observation services' start jobs wait, and so does `multi-user.target`. Everything else runs: SSH, Mosquitto and the bridge, and the station services. Over MQTT, every station record has `synced` false, except GNSS fixes.

- `systemctl list-jobs` shows the observation services `waiting` and `chrony-wait.service` `running`.
- `systemctl is-system-running` says `starting`.
- `chronyc tracking` shows `Reference ID ... ()` and `Leap status : Not synchronised`. `chronyc sources` shows which sources chrony has.
- `journalctl -u tsschedule` shows why the RTC was not trusted.

To get a trusted clock:

- connect the station to a network;
- or have `tslocationd` take a GNSS fix (`tslocation fix`, or **Measure with GPS** in tsconfig) under open sky.

The waiting services then start on their own. tsOS does not write the RTC itself. Once chrony has synced, `rtcsync` in Debian's default `chrony.conf` has the kernel copy the time to the RTC every 11 minutes, so the RTC passes the check at the next boot.

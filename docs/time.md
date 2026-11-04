# Time

An observation is only worth something if its time can be compared with other stations and with the real world. Many stations have no network, and some have no RTC. So tsOS splits its services in two groups:

- **Station services** run, manage and report on the station itself. They start at boot, with whatever clock there is: they are needed to get a trusted clock, or to see why there is none. Their readings over MQTT carry no time; the receiver stamps them on arrival.
- **Observation services** observe the world: they record detections, audio and measurements. They start only once the clock has been set from a trusted source. Without one, they do not start at all.

chrony is the only authority for whether the clock is trusted: it is once chrony has selected a source. From that follow the kernel's clock state (`STA_UNSYNC`, which chrony clears), `time-sync.target` and every service's check.

## Trusted sources

| Source | chrony's reference | How | Notes |
|---|---|---|---|
| NTP | the server's address | Debian's default pools | needs a network connection (LAN, WLAN or LTE) |
| GNSS | `GPS`, `PPS` | gpsd's shared memory: `refclock SHM 0` (NMEA) and `SHM 1` (PPS), [gps.conf](../etc/chrony/conf.d/gps.conf) | The LTE modem's GNSS is off most of the time. `tslocationd` makes a fine fix whenever chrony has had no source since it started, or for longer than `time_max_age` (24 h), in every mode, including `off` ([location.md](location.md#time)). Without PPS, the accuracy is around 100 ms |
| RTC | `RTC` | `tsscheduled` checks the RTC at its start and then sends samples of it to chrony's SOCK reference clock, [rtc.conf](../etc/chrony/conf.d/rtc.conf) | WittyPi 4, or the Raspberry Pi 5's own RTC; see [RTC](#rtc). The RTC drifts, so chrony ranks it behind NTP and GNSS |

chrony keeps the sources apart: `chronyc tracking` names the one it follows, and tstelemetry's `timesync` collector reports it as `none`, `rtc`, `ntp` or `gnss`, with chrony's bound on the error ([telemetry.md](telemetry.md#collectors)). Whether the clock is precise (NTP, GNSS) or only set from the RTC does not matter for which services run.

Three things set the clock at boot without making it trusted:

- systemd moves the clock forward to the mtime of `/var/lib/systemd/timesync/clock`. The image build touches that file, so the clock never starts before the build date.
- The kernel reads the RTC, if there is one.
- `fake-hwclock`, where installed, restores the time of the last shutdown. tsscheduled only uses it as a lower bound for the RTC; it never makes the clock trusted.

## The gate: `time-sync.target`

`time-sync.target` is reached only once chrony has a source. `chrony-wait.service` (chrony's own unit, enabled in the image) runs `chronyc waitsync` and is ordered before `time-sync.target`. The drop-in [override.conf](../etc/systemd/system/chrony-wait.service.d/override.conf) removes its 3-minute timeout. Without that, `chrony-wait` would fail after 3 minutes, and `time-sync.target` would be reached anyway, because it only `Wants=` `chrony-wait`.

There is no other way to the target: the checked RTC also arrives through chrony.

## RTC

### The check

At its start, `tsscheduled` ([scheduled.py](../usr/local/src/tsschedule/tsschedule/scheduled.py)) trusts the RTC only if all of these hold:

- **It keeps time.** On the WittyPi 4, the PCF85063's oscillator-stop flag is clear; on the Raspberry Pi 5, the kernel can read the RTC. An RTC that lost its power fails this test.
- **Not before the last known time.** The RTC is not older than the newest of `/etc/fake-hwclock.data`, the mtime of `/var/lib/systemd/timesync/clock` and the mtime of `/var/lib/chrony/chrony.drift`.
- **Matches the system clock.** The RTC is within 5 s of the system clock.

If a test fails, `tsscheduled` logs `RTC lost its time`, `RTC is implausible` or `RTC does not match system clock` and exits with 3. systemd starts it again after 300 s. chrony gets nothing from the RTC then.

The check only gives a lower bound: an RTC that is ahead of the real time passes. The mtime of `timesync/clock` is the build date, because nothing updates it after the build.

### Feeding chrony

Once the check passed, `tsscheduled` sends chrony a sample every second through the socket `/run/chrony/rtc.sock` ([chronysock.py](../usr/local/src/tsschedule/tsschedule/chronysock.py)): the system time at the start of an RTC second, and how far the RTC is ahead of it. chrony treats the RTC as a reference clock with `refid RTC` ([rtc.conf](../etc/chrony/conf.d/rtc.conf)). Every 4 s (`poll 2`), chrony takes the median of 3 samples (`filter 3`), so a single bad sample is dropped. It selects the RTC after three such polls: on a station without network or GNSS, `time-sync.target` is reached about 15 s after tsscheduled has started, about 30 s after boot. `delay 2` adds 1 s to the RTC's distance, so NTP and GNSS always win chrony's selection as soon as they are there. tsscheduled predicts each second's start from the last one and reads the RTC only shortly before it, a few register reads per sample.

`tsschedule.service` starts after `chrony.service`, which creates the socket. If chrony is not running, the failure is logged once, and tsscheduled keeps trying.

### Writing the RTC

tsOS does not write the RTC itself. Once chrony has a source, `rtcsync` in Debian's default `chrony.conf` has the kernel copy the system time to the RTC every 11 minutes. That also happens when the RTC is chrony's only source, which keeps it as it is. After a sync from NTP or GNSS, the RTC passes the check at the next boot.

### Accuracy

The RTC counts whole seconds, and the kernel writes it with a phase error: where its second begins is off from the true second by up to several hundred milliseconds (170 to 540 ms on a Raspberry Pi 5 in testing). A clock set from the RTC is that far off, on top of the RTC's drift since its last write. chrony's error bound (`error_s` in `timesync`, about 1 s for the RTC) covers it. Observations from stations whose clock comes from the RTC can therefore not be compared to better than about half a second, e.g. for the signal times of radiotracking across stations; NTP and GNSS are within milliseconds.

## Station services

These start at boot without waiting for `time-sync.target`.

- **MQTT:** readings carry no time, are QoS 0 and are not retained ([MQTT](mqtt.md#retained-messages)). A reading that arrives is current; one that does not is lost. The receiver stamps it on arrival. There are no online/offline topics: a station or service that stops shows as missing readings.
- **Files:** rows under `/data` are only written once the clock is trusted, with `time` first. Before that, readings only go over MQTT; nothing is spooled or re-timed ([telemetry.md](telemetry.md#clock)).
- **The clock itself** is a reading: tstelemetry's `timesync` collector reports chrony's source, its error bound and the station's clock as a value, which the receiver can compare with the arrival time.

| Service | Repository | Notes |
|---|---|---|
| `tstelemetry.service` | tsOS-base (tsconfig) | Journal entries forwarded over MQTT keep `time` and `synced`: they are events, and can come from an earlier boot ([logging.md](logging.md#forwarding-over-mqtt)) |
| `smartsolar.service`, `solarlife.service` | tsOS-base (pysmartsolar, pysolarlife) | |
| `tslocation.service` | tsOS-base (tsconfig) | GNSS fixes and track points lead with their GNSS `time`, which is always trusted, and go to their files at once |
| `tsconfig.service`, `tsconfig-ble.service` | tsOS-base | |
| `tsschedule.service` | tsOS-base | Needs `time-set.target` only; it feeds the checked RTC to chrony |

## Observation services

These wait for a trusted clock and do not start without one. Their records carry `time` and are QoS 1, so the bridge queues them during an outage ([MQTT](mqtt.md#qos-decides-what-is-queued)). They do not spool or re-time anything: what they write always has a trusted time. A station that never gets a trusted clock records nothing, rather than records operators might take for real.

| Service | Repository |
|---|---|
| `envsense.service` | tsOS-base |
| `radiotracking.service` | tsOS-vhf |
| `lotekfskd.service` | tsOS-fsk |
| `soundscapepipe.service`, `lightbarrier.service` | tsOS-audio |

Every observation service has both lines in its unit:

```ini
[Unit]
After=time-sync.target
Requires=time-sync.target
```

`After=` alone would also wait at boot, but only because `chrony-wait` happens to pull in `time-sync.target`. `Requires=` makes the dependency explicit.

## A station without a trusted clock

At boot the observation services' start jobs wait, and so does `multi-user.target`. Everything else runs: SSH, Mosquitto and the bridge, and the station services. Their readings go out over MQTT as usual, but nothing is written to their files, and `timesync` reports `source` `none`.

- `systemctl list-jobs` shows the observation services `waiting` and `chrony-wait.service` `running`.
- `systemctl is-system-running` says `starting`.
- `chronyc tracking` shows `Reference ID ... ()` and `Leap status : Not synchronised`. `chronyc sources` shows which sources chrony has, `RTC` among them once tsscheduled feeds it.
- `journalctl -u tsschedule` shows why the RTC was not trusted.

To get a trusted clock:

- connect the station to a network;
- or have `tslocationd` take a GNSS fix (`tslocation fix`, or **Measure with GPS** in tsconfig) under open sky.

The waiting services then start on their own.

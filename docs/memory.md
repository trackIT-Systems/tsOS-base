# Memory Pressure and the OOM Killer

## Problem

tsOS runs without swap on disk (SD card wear). When the station runs out of memory, the kernel's OOM killer acts only when an allocation fails outright. Long before that, the kernel reclaims the page cache, including the code of running programs, and reads it back from the SD card on the next access. The station then spends most of its time waiting for the card: services time out, SSH and the web UI stop answering, but PID 1 keeps feeding the [hardware watchdog](watchdog.md). This can last for hours.

## systemd-oomd

[`systemd-oomd`](https://www.freedesktop.org/software/systemd/man/latest/systemd-oomd.service.html) is systemd's userspace OOM killer. It acts on memory pressure instead of failed allocations. Pressure (PSI, `/proc/pressure/memory`) is the share of time in which tasks were stalled waiting for memory, including the time spent re-reading evicted page cache. When the pressure of a monitored cgroup stays above its limit, oomd kills the descendant unit with the most memory reclaim activity, as a whole cgroup (`SIGKILL`). The unit's `Result=` is then `oom-kill`, and systemd restarts it according to its `Restart=`.

### Configuration

| File | Setting |
| --- | --- |
| `boot/firmware/cmdline.txt` | `psi=1`: the Raspberry Pi kernels have PSI built in but disabled (`CONFIG_PSI_DEFAULT_DISABLED=y`) |
| `tsOS-base.Pifile` | installs `systemd-oomd` and enables `systemd-oomd.service` |
| `etc/systemd/system/system.slice.d/50-oomd.conf` | `ManagedOOMMemoryPressure=kill` on `system.slice`: all system services |
| `etc/systemd/system/user.slice.d/50-oomd.conf` | `ManagedOOMMemoryPressure=kill` on `user.slice`: SSH and console sessions, user services |

Limits are the package defaults: pressure above 60% (`DefaultMemoryPressureLimit`) for 20 s (`DefaultMemoryPressureDurationSec`, Debian's `/usr/lib/systemd/oomd.conf.d/10-oomd-defaults.conf`). Debian also ships `ManagedOOMMemoryPressure=kill` with a 50% limit for `user@.service` and `ManagedOOMSwap=auto` for `-.slice`; the latter never acts without swap.

A unit can lower its chance of being picked with `ManagedOOMPreference=avoid`, or be excluded with `ManagedOOMPreference=omit` (only for unit files owned by root). tsOS sets neither.

### Requirements

`systemd-oomd.service` does not start (condition not met, no error) unless:

- the cgroup v2 `memory` controller is available (`/sys/fs/cgroup/cgroup.controllers`). The 6.18 Raspberry Pi kernels enable it by default.
- `/proc/pressure/{cpu,io,memory}` exist, i.e. `psi=1` is on the command line.

### Checking a station

```sh
systemctl status systemd-oomd   # active (running)
oomctl                          # monitored cgroups, current pressure and limits
cat /proc/pressure/memory       # "some avg10=..." per pressure window
journalctl -u systemd-oomd      # "Killed /system.slice/<unit> due to memory pressure ..."
```

A unit killed by oomd shows `Result: oom-kill` in `systemctl status <unit>`.

## Related

- [Hardware Watchdog](watchdog.md): recovery from panics, hung storage and a stopped PID 1

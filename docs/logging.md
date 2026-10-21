# Logging

How tsOS services log, so the journal can be filtered by service and severity, stays quiet in normal operation, and selected messages can be forwarded over MQTT without filling a cellular link.

Every service logs to the systemd journal, stored persistently (`Storage=persistent` in [journald.conf](../etc/systemd/journald.conf)). There are no per-service log files.

## Identifiers

Each journal entry carries two names:

| Field | Set by | Used for |
| --- | --- | --- |
| `_SYSTEMD_UNIT` | systemd, always correct | `journalctl -u <unit>`, forwarding selection |
| `SYSLOG_IDENTIFIER` | the program, or systemd on its behalf | the `name[pid]:` prefix in `journalctl` output |

For stdout and stderr, systemd takes `SYSLOG_IDENTIFIER` from the executable that `ExecStart=` starts. A unit that starts its program through a wrapper therefore logs under the wrapper's name: `ExecStart=/usr/bin/env tstelemetry` logs as `env`, and `ExecStart=python3 -m uvicorn ...` logs as `python3`.

Rules:
- `ExecStart=` calls the installed program directly (`tstelemetry`, `tsscheduled`), not `python3 -c` or `python3 -m`.
- Where a wrapper cannot be avoided (`/usr/bin/env`, `python3 -m`, `sh -c`), the unit sets `SyslogIdentifier=` to the program's name.
- The identifier is the program's name, which may differ from the unit's name (`tsschedule.service` runs `tsscheduled`).

Check a unit with `journalctl -u <unit> -o verbose -n 1 | grep SYSLOG_IDENTIFIER`.

## Severity

journald stores a priority with every entry, the syslog severities of [RFC 5424](https://www.rfc-editor.org/rfc/rfc5424#section-6.2.1). `journalctl -p warning` shows warnings and worse. Forwarding filters on this priority, so every message must carry the right one.

Python's levels map to the priorities as follows:

| Python level | Priority | Use it when |
| --- | --- | --- |
| `CRITICAL` | 2 `crit` | the service cannot continue and is about to exit |
| `ERROR` | 3 `err` | an operation failed and needs attention: a reading, a write, a request to hardware |
| `WARNING` | 4 `warning` | something unexpected happened and was handled: a retry, a fallback to defaults, a missing optional device |
| `INFO` | 6 `info` | a one-off event: start, stop, configuration loaded, connected, clock synced, update installed |
| `DEBUG` | 7 `debug` | everything repeated or detailed: polling, requests, per-reading values, protocol traces |

Priorities 0 (`emerg`), 1 (`alert`) and 5 (`notice`) are not used by tsOS services.

### Quiet in normal operation

A station that works logs nothing at the default level, `WARNING`, except a few `INFO` lines when services start.

- **Log changes of state, not states.** A failure that repeats every minute is logged once when it starts, again only when the error changes, and once when it recovers (`... works again`). The repeats go to `DEBUG`. `Daemon._failed()` and `Daemon._succeeded()` in [tstelemetry](../usr/local/src/tsconfig/app/telemetry/daemon.py) are the pattern to follow.
- **Nothing periodic above `DEBUG`.** Data that is read periodically belongs in telemetry, not in the log.
- **Shipped units do not pass `-v`.** `-v` (INFO) and `-vv` (DEBUG) are for debugging on a station, set temporarily with a drop-in (`systemctl edit <unit>`).
- **The default level is `WARNING`.** It can be changed with `LOG_LEVEL` or `-v`, as in [logging_config.py](../usr/local/src/tsconfig/app/logging_config.py).

### Python conventions

- One logger per module: `logger = logging.getLogger(__name__)`. Do not log to the root logger or through `logging.info()`.
- No `print()` for diagnostics. `print()` is for a command's output on a terminal (e.g. `tstelemetry --once`).
- Pass arguments, do not format: `logger.warning("Cannot read %s: %s", path, e)`, not an f-string. The message is then only formatted when the level is enabled.
- Tracebacks only at `ERROR`, via `logger.exception()` in an `except` block. At lower levels, log the exception's type and text. When a traceback helps with debugging, add it at `DEBUG` (`exc_info=True`).
- Messages are English, one sentence, capitalized, without a trailing period. They name what they are about (`Cannot open /dev/ttyUSB0: ...`, not `Open failed`).
- No secrets: passwords, tokens, keys and full configuration files are never logged, at any level.

## Message format

Each entry is a set of [journal fields](https://www.freedesktop.org/software/systemd/man/latest/systemd.journal-fields.html). The message text holds only what a reader needs. Everything else goes in separate fields:

| Field | Content |
| --- | --- |
| `MESSAGE` | `<logger name>: <message>`, e.g. `app.telemetry.daemon: modem failed: TimeoutError` |
| `PRIORITY` | the priority from [Severity](#severity) |
| `SYSLOG_IDENTIFIER` | see [Identifiers](#identifiers) |
| `CODE_FILE`, `CODE_LINE`, `CODE_FUNC` | where the message was logged |

- **No timestamp** in the message: journald records the time of every entry.
- **No level name** in the message: `PRIORITY` carries it, and `journalctl` colors by it.
- **The logger name stays** in the message. It names the module (`__name__`), costs a few bytes, and is what a reader looks for first.
- **The location (`CODE_*`) is never in the message.** It stays on the station, where `journalctl -o verbose` shows it, and is not forwarded. This keeps forwarded messages short without losing the location.
- **A traceback is part of `MESSAGE`,** as one entry with several lines, not one entry per line.

### How a program sets the fields

**Python services** write to the journal directly, through journald's [native protocol](https://systemd.io/JOURNAL_NATIVE_PROTOCOL/), which sets all fields above. They do this when systemd has connected them to the journal: systemd then sets `JOURNAL_STREAM` (see [systemd.exec](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#%24JOURNAL_STREAM)). Otherwise, e.g. on a terminal or in tests, they write `<LEVEL> <logger name>: <message>` to stderr. [logging_config.py](../usr/local/src/tsconfig/app/logging_config.py) provides this for tsconfig and its daemons. Services in other repositories (pysmartsolar, pysolarlife, tsscheduled, tsupdate) do the same, or at least the stdout prefix below.

**Shell scripts and programs that only write to stdout** start each line with the priority in angle brackets, as defined in [sd-daemon(3)](https://www.freedesktop.org/software/systemd/man/latest/sd-daemon.html): `<4>Cannot reach the modem`. journald removes the prefix and sets `PRIORITY` (unit option `SyslogLevelPrefix=`, on by default). A line without a prefix is stored as `info`. A shell script can also use `systemd-cat -p warning`.

**Third-party services** (NetworkManager, ModemManager, chrony, mosquitto, the kernel) already log with priorities. They are left as they are.

## Forwarding over MQTT

> Planned, see [issue #31](https://github.com/trackIT-Systems/tsOS-base/issues/31). This section is the intended design. It changes as it is implemented.

`tstelemetry` forwards selected journal entries to the local broker, alongside its [telemetry](telemetry.md). There is no third-party log shipper. The cellular bridge decides which topics leave the station, as it does for telemetry.

### Selection

All units are forwarded at `warning` and worse. This includes the kernel, which has no unit and is named `kernel`. Units are not listed one by one: an unexpected failure is most often in a unit nobody thought of, such as a full file system, the OOM killer or a failing SD card.

The selection is set in `/etc/tsconfig/tstelemetry.yml`, not in `tsconfig.yml`. `tsconfig.yml`'s `services` list says what the web UI shows, which is a different question, and `tstelemetry` does not depend on tsconfig's settings. The settings are:

- a default priority threshold (`warning`)
- per-unit overrides: a higher threshold for a noisy unit, a lower one for a unit under investigation, or off

### Limits

Volume is bounded by rate limits, not by compression. Payloads are not compressed, so every MQTT client can read them.

- **Merge repeats:** the same unit and message within 10 minutes is sent once. When the window ends, one entry with the number of repeats follows.
- **Rate per unit:** at most a burst of 10 entries, then 1 per minute. Excess entries are dropped and counted.
- **Budget per station:** at most 100 entries per hour across all units.
- **Count drops:** dropped entries are published as counts per unit, so a gap is visible.
- **Truncate:** messages are cut to 256 characters. Tracebacks are not forwarded, only their last line.

The numbers are starting values, to be checked against what real stations log.

A `journal` collector also publishes the number of entries per unit and priority every 10 minutes. It costs a few bytes, shows which station has trouble and where, and is sent even when the limits drop entries.

### Topics

Open: whether the unit is part of the topic.

| | `<host>/tsconfig/journal/<format>` | `<host>/tsconfig/journal/<unit>/<format>` |
| --- | --- | --- |
| Unit | a column | in the topic, and a column |
| Selecting units | on the station only (`tstelemetry.yml`) | also in the bridge (`topic +/tsconfig/journal/tsschedule/cbor out 1`) and by the subscriber |
| Fits the telemetry scheme | yes: `journal` is one more collector | adds a level below the collector |
| Overhead | — | the unit name in every message's topic, some 10–20 bytes |

Either way, formats and columns follow the [telemetry conventions](telemetry.md#mqtt): CSV, JSON and CBOR, with `time` and `synced` first, then `unit`, `identifier`, `priority`, `message` and `repeated`.

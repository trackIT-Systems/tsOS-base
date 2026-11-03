# MQTT (Mosquitto)

Every daemon on the station publishes to the local Mosquitto broker. A **bridge** forwards a selection of topics to the server over the uplink (LTE, Wi-Fi). While the uplink is down, the station's records wait in Mosquitto. This page describes what is kept, for how long, and which settings a bridge must have.

The local broker listens on loopback only, see [Security](security.md#mqtt-over-websocket). Its configuration is [etc/mosquitto/mosquitto.conf](../etc/mosquitto/mosquitto.conf); the bridge comes from the config bundle as `/boot/firmware/mosquitto.d/server.conf`.

## What survives an outage

### QoS decides what is queued

A message is delivered at the lower of the publish QoS and the subscription QoS, so `out 1` in a bridge topic line does not make a QoS 0 message QoS 1. While the uplink is down, Mosquitto queues QoS 1 messages for the bridge and **drops QoS 0 messages** (`queue_qos0_messages` is off).

This is intended. Records are QoS 1. Health is QoS 0: it is only useful live, and every value is also in the station's daily CSV files under `/data`.

| Publisher | Topics | QoS | During an outage |
| --- | --- | --- | --- |
| radiotracking (tsOS-vhf) | `<host>/radiotracking/...` | 1 | queued |
| lotekfskd (tsOS-fsk) | `<host>/lotekfsk/...` | 1 | queued |
| soundscapepipe, lightbarrier | `<host>/soundscapepipe/...`, `<host>/lightbarrier/...` | 1 | queued |
| tstelemetry ([Telemetry](telemetry.md)) | `<host>/tsconfig/<collector>/...` | 0 | dropped |
| journal forwarding ([Logging](logging.md#forwarding-over-mqtt)) | `<host>/tsconfig/journal/...`, `<host>/tsconfig/journalstats/...` | 0 | dropped |
| tslocationd ([Location](location.md)) | `<host>/tslocation/...` | 0 | dropped |
| smartsolard, solarlifed, envsense | `<host>/smartsolar/...`, `<host>/solarlife/...`, `<host>/envsense/...` | 0 | dropped |
| tstelemetry state | `<host>/tsconfig/state` | 1, retained | latest value kept |

Retained messages are kept as one value per topic, independent of the queue.

### Persistence

Mosquitto holds the queue in memory and saves it to `/var/lib/mosquitto/mosquitto.db` every 5 minutes (`autosave_interval 300`) and on a clean shutdown. A power cut (empty battery, WittyPi cut, brown-out) loses the messages of the last 5 minutes at most. They are still in the station's files under `/data`.

Each save rewrites the whole database to a new file and renames it over the old one, so a save costs the size of the queue at that moment. While the uplink is up, the queue stays near empty and a save is a few KB, about 1 MB of SD card writes per day. During an outage, a full queue is 26 MB per save, about 7.5 GB per day of outage.

`autosave_on_changes` would save after a number of queued messages instead, writing nothing on an idle station and nothing more once the queue is full. It is not used because the loss on a power cut then depends on the message rate: a station that queues one message every 10 s would wait hours for a save.

### Queue limits

| Setting | Value | Default |
| --- | --- | --- |
| `max_queued_messages` | 100000 | 1000 |
| `max_queued_bytes` | 32 MiB (payload only) | unlimited |
| `max_inflight_messages` | 100 | 20 |

The limits apply per client, so also to the bridge's outgoing queue. Beyond them, Mosquitto drops new messages and logs `Outgoing messages are being dropped for client local.<remote_clientid>`. The oldest messages are kept. `max_inflight_messages` is the number of QoS 1 messages the bridge sends before the server acknowledges the first. At 100 and a round trip of 1 s over LTE, a full queue drains in about 17 minutes.

Measured with Mosquitto 2.0.21 and a bridge to an unreachable server: 100000 QoS 1 messages of 85 bytes (the size of a CBOR matched record) on a 45-byte topic make a database of 26.5 MB (264 bytes per message), use about 50 MB of memory, and count 8.5 MB against `max_queued_bytes`. The message limit is reached first; the byte limit only matters if the bridge forwards large messages, such as JSON.

How long 100000 messages last depends on the rate of the QoS 1 topics the bridge forwards (all formats count, each topic line separately):

| QoS 1 messages per second | Outage covered |
| --- | --- |
| 0.1 | 11 days |
| 1 | 28 hours |
| 5 | 5.5 hours |

Forward CBOR only, and matched records rather than every receiver's detections, to make the queue last.

The database is on the overlay partition (`upperfs`), which it shares with the journal, daemon state and every change to the root filesystem. At these limits it stays below about 60 MB, small against the partition.

## Bridge settings

The bridge is part of the config bundle, so its content is the operator's. A bridge for tsOS needs:

- **Session kept over reconnects.** `cleansession false` (Mosquitto's default for bridges) and a stable client ID. The default `remote_clientid` is `<hostname>.<connection name>`, unique per station; leave it unset unless the bundle is per station. `local_clientid` defaults to `local.<remote_clientid>`.
- **QoS 1 topic lines** (`out 1`), so that QoS 1 records stay QoS 1.
- **TLS** with `bridge_cafile`, and credentials (`remote_username`, `remote_password`).
- **Timing for LTE.** The defaults fit: `keepalive_interval 60`, and reconnects with a backoff of 5 to 30 s (`restart_timeout`).
- **Optional: `notifications`.** On by default: the bridge publishes its connection state, retained, to `$SYS/broker/connection/<remote_clientid>/state` on both brokers. The server only receives it if its ACL lets the station write that topic.

Example (`<server>` and the password come from the backend's template):

```
connection <server>
address <server>:8883
remote_username station
remote_password <password>
bridge_cafile /boot/firmware/mosquitto.d/server.crt
cleansession false

# health, live only (QoS 0)
topic +/tsconfig/+/cbor out 1
topic +/tsconfig/state out 1
topic +/tsconfig/journal/+/emerg/cbor out 1
topic +/tsconfig/journal/+/alert/cbor out 1
topic +/tsconfig/journal/+/crit/cbor out 1
topic +/tsconfig/journal/+/err/cbor out 1
topic +/tsconfig/journal/+/warning/cbor out 1
topic +/tslocation/+/cbor out 1
topic +/smartsolar/+/cbor out 1
topic +/solarlife/+/+/cbor out 1
topic +/solarlife/+/cbor out 1
topic +/envsense/+/json out 1

# records, queued (QoS 1), per variant
topic +/radiotracking/matched/cbor out 1
topic +/radiotracking/state/cbor out 1
topic +/lotekfsk/+/cbor out 1
topic +/soundscapepipe/detection/cbor out 1
topic +/soundscapepipe/state/cbor out 1
topic +/lightbarrier/event/cbor out 1
topic +/lightbarrier/state/cbor out 1
```

The topics of each publisher are documented with it: [Telemetry](telemetry.md#mqtt), [Logging](logging.md#topics), [Location](location.md), and the variant repositories (radiotracking in tsOS-vhf, `docs/lotekfsk.md` in tsOS-fsk).

## After an outage

On reconnect, the bridge sends the queue first, oldest first, then new messages. QoS 0 health that is published meanwhile arrives interleaved with the older records. QoS 1 means at least once, so a record can arrive twice after a reconnect. Consumers sort by the `time` each record carries, not by arrival, and must accept duplicates. Records taken before the clock was synced carry `synced` false.

## An unreadable database

A truncated or corrupt `mosquitto.db` stops Mosquitto from starting (`Error: Couldn't open database.`), and every daemon would lose its local broker. Mosquitto's save-and-rename keeps the old database if the power fails during a save, so this needs a damaged file system.

When `mosquitto.service` fails, its `OnFailure=` ([drop-in](../etc/systemd/system/mosquitto.service.d/tsos-db-recover.conf)) starts [`tsos-mosquitto-db-recover`](../usr/local/sbin/tsos-mosquitto-db-recover). If the failed run could not open the database, it moves the database to `mosquitto.db.unreadable-<time>`, logs a warning and starts Mosquitto again with an empty one. The queue is lost. Any other failure, such as a broken `mosquitto.d` file, leaves the database alone. Only the latest unreadable database is kept.

## Retained messages

Retained messages stay in the database until they are replaced or cleared. A daemon that renames or drops a retained topic clears the old one (publishes an empty retained message), otherwise it stays on every station that ran the old version.

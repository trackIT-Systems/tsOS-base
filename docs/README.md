# tsOS-base Developer Documentation

Technical documentation for developers working on tsOS-base.

## Documentation

- **[Architecture](architecture.md)** - System architecture and design
- **[Build System](build.md)** - Build process and Pifile structure
- **[Project Structure](structure.md)** - Repository organization
- **[Updatability](updatability.md)** - Dual-boot update mechanism and tryboot
- **[Hardware Watchdog](watchdog.md)** - Raspberry Pi hardware watchdog timer configuration
- **[Memory Pressure](memory.md)** - `systemd-oomd`: killing the unit under memory pressure before the station thrashes
- **[Security Design](security.md)** - `root`/`pi` privilege separation model
- **[Telemetry](telemetry.md)** - `tstelemetry`: device health over MQTT and into daily CSV files
- **[Location](location.md)** - `tslocationd`: reference, measured and effective position, modes, GNSS through ModemManager and gpsd
- **[Logging](logging.md)** - Identifiers, severities and message format of service logs, and forwarding over MQTT
- **[Time](time.md)** - Trusted clock sources, the `time-sync.target` gate, and which services wait for it
- **[MQTT](mqtt.md)** - Mosquitto and the bridge: what is queued during an outage, persistence, queue limits, required bridge settings and topics

## Quick Reference

**Build**: `docker-compose run --rm pimod pimod.sh tsOS-base.Pifile`

**Base**: Raspberry Pi OS Lite (Debian Trixie)  
**Tool**: [pimod](https://github.com/Nature40/pimod)  
**Architecture**: arm64

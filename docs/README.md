# tsOS-base Developer Documentation

Technical documentation for developers working on tsOS-base.

## Documentation

- **[Architecture](architecture.md)** - System architecture and design
- **[Build System](build.md)** - Build process and Pifile structure
- **[Project Structure](structure.md)** - Repository organization
- **[Updatability](updatability.md)** - Dual-boot update mechanism and tryboot
- **[Hardware Watchdog](watchdog.md)** - Raspberry Pi hardware watchdog timer configuration

## Quick Reference

**Build**: `docker-compose run --rm pimod pimod.sh tsOS-base.Pifile`

**Base**: Raspberry Pi OS Lite (Debian Trixie)  
**Tool**: [pimod](https://github.com/Nature40/pimod)  
**Architectures**: arm64, armhf

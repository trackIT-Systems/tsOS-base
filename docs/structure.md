# Project Structure

## Directory Layout

```
tsOS-base/
├── boot/                    # Boot partition files
│   ├── cmdline.txt         # Kernel command line
│   ├── firmware/           # Firmware partition files
│   │   ├── mqttutil.conf  # MQTT reporting config
│   │   └── mosquitto.d/   # MQTT broker configs
│   └── ...
├── etc/                     # System configuration
│   ├── systemd/system/     # Systemd service files
│   ├── netplan/            # Network configuration
│   ├── mosquitto/          # Mosquitto config
│   ├── caddy/              # Caddy web server config
│   ├── filebrowser/        # Filebrowser config
│   ├── chrony/             # Time sync config
│   └── ...
├── usr/                     # User-space programs
│   └── local/bin/          # Custom binaries
├── var/                     # Variable data
│   └── lib/                # Persistent state
├── home/pi/                 # Pi user home (git submodules)
│   ├── tsconfig/           # Configuration service
│   ├── wittypi4/           # WittyPi support
│   ├── pymqttutil/         # MQTT utilities
│   └── ...
├── .github/workflows/       # CI/CD workflows
├── docker-compose.yml      # Build environment
├── tsOS-base.Pifile        # Build config (arm64)
└── tsOS-base-armhf.Pifile # Build config (armhf)
```

## Key Directories

### `boot/`

Files copied to boot partition (writable at runtime):
- `cmdline.txt` - Kernel parameters
- `firmware/` - Firmware partition contents
  - Runtime configuration files
  - Device tree overlays

### `etc/`

System configuration files:
- `systemd/system/` - Custom systemd services
- `netplan/` - NetworkManager network configs
- Service-specific configs (mosquitto, caddy, etc.)

### `home/pi/`

Git submodules containing Python packages and tools:
- Each submodule is installed via `pip install -e`
- `.git` directories are preserved during build
- Permissions set to `pi:pi`

### `usr/local/bin/`

Custom compiled binaries:
- `filebrowser` - Downloaded and installed
- `uhubctl` - Compiled from source
- `gitui` - Downloaded binary

## Build Artifacts

- `tsOS-base-arm64.img` - Final arm64 image
- `tsOS-base-armhf.img` - Final armhf image
- `.cache/` - Cached base images (created by pimod)

## Git Submodules

Submodules in `home/pi/`:
- `tsconfig` - Main configuration service
- `wittypi4` - WittyPi hardware support
- `pymqttutil` - MQTT system reporting
- `pysmartsolar` - SmartSolar integration
- `vedirect_dump` - VE.Direct protocol
- `uhubctl` - USB hub control
- `Witty-Pi-4` - WittyPi reference
- `.oh-my-zsh` - Zsh framework

Submodules are installed during build by copying `.git` directories and running `pip install -e`.

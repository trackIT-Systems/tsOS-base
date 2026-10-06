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
│   ├── filebrowser/        # FileBrowser Quantum config
│   ├── chrony/             # Time sync config
│   └── ...
├── usr/                     # User-space programs
│   └── local/
│       ├── bin/            # Custom binaries
│       └── src/            # Application git submodules
├── var/                     # Variable data
│   └── lib/                # Persistent state
├── opt/
│   └── oh-my-zsh/           # Zsh framework, shared by pi and root
├── home/pi/                 # Pi user home
│   └── .ssh/               # SSH keys
├── root/                    # Root's manufacturer-controlled files
│   └── .ssh/               # SSH keys (separate from pi's)
├── .github/workflows/       # CI/CD workflows
├── docker-compose.yml      # Build environment
└── tsOS-base.Pifile        # Build config (arm64)
```

## Key Directories

### `boot/`

Files copied to boot partition (root-owned at runtime, `0755` - readable by everyone, writable
by root only; operator changes go through `tsconfig`'s privileged write path, see
[Security Design](security.md)):
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

Pi user home:
- `.ssh` - SSH authorized keys
- Permissions set to `pi:pi`

### `opt/oh-my-zsh/`

Zsh framework, shared by both `pi` and `root` (a single install, not one per account - both
accounts' `.zshrc` point `ZSH=` at this same path). Permissions set to `root:root`, mode `755`
- readable by both, writable by neither, same as `usr/local/src/`.

### `usr/local/src/`

Git submodules containing Python packages and tools:
- Each submodule is installed via `pip install -e`
- `.git` directories are preserved during build
- Permissions set to `root:root`, mode `755` - `pi` can read/traverse but not write (see
  [Security Design](security.md))

### `usr/local/bin/`

Custom binaries:
- `gitui` - Downloaded binary

FileBrowser Quantum is downloaded at build time and installed to `/usr/bin/filebrowser`.

## Build Artifacts

- `tsOS-base-arm64.img` - Final arm64 image
- `.cache/` - Cached base images (created by pimod)

## Git Submodules

Submodules in `usr/local/src/`:
- `tsconfig` - Main configuration service
- `pymqttutil` - MQTT system reporting
- `pysmartsolar` - SmartSolar integration
- `vedirect_dump` - VE.Direct protocol
- `tsupdate`, `tsschedule`, `tsflash`, `pysolarlife`, `vcgencmd`, `pyenvsense`

Submodule in `opt/`:
- `oh-my-zsh` - Zsh framework, shared by `pi` and `root`

Submodules are installed during build by copying `.git` directories and running `pip install -e`.

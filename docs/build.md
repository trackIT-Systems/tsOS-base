# Build System

## Overview

tsOS-base uses [pimod](https://github.com/Nature40/pimod) to build custom Raspberry Pi OS images. The build process modifies a base Raspberry Pi OS image by applying changes defined in `.Pifile` files.

## Build Files

- `tsOS-base.Pifile` - arm64 build (Raspberry Pi 3+)
- `tsOS-base-armhf.Pifile` - armhf build (older Pi models)

Both files are nearly identical, differing only in the `ARCH` variable.

## Build Process

1. **Base Image**: Downloads Raspberry Pi OS Lite image (Debian Trixie)
2. **Modifications**: Applies changes via Pifile commands:
   - Package installation (`RUN apt-get install`)
   - File installation (`INSTALL`)
   - Configuration changes (`RUN`)
   - Service enablement (`RUN systemctl enable`)
3. **Output**: Produces `tsOS-base-${ARCH}.img`

## Pifile Structure

### Key Sections

1. **Base Image** (`FROM`): Raspberry Pi OS source
2. **OS Metadata** (`RUN tee /etc/os-release`): Version info from git tags
3. **Package Installation**: Core Debian packages
4. **Custom Files** (`INSTALL`): Copies project directories to image
5. **Git Submodules**: Installs `.git` directories for submodules
6. **Configuration**: Systemd services, permissions, hardware setup
7. **Cleanup** (`ZERO`): Zero-fills unused space

### Important Build Details

- **Image Expansion**: `PUMP 1000M` expands image by 1GB
- **Versioning**: Uses `git describe --tags --always` for version
- **Python Packages**: Installed with `--no-deps` flag (dependencies handled via apt)
- **DKMS Modules**: WittyPi RTC module compiled for kernel version
- **Device Tree**: Custom overlays compiled and installed

## Building Locally

```sh
# Build arm64
docker-compose run --rm pimod pimod.sh tsOS-base.Pifile

# Build armhf
docker-compose run --rm pimod pimod.sh tsOS-base-armhf.Pifile
```

## CI/CD

GitHub Actions builds on tag push:
- Uses `Nature40/pimod@v0.8.0` action
- Builds both architectures
- Packages images as `.zip` files
- Uploads to GitHub Releases

See `.github/workflows/build.yml` for details.

## Adding Components

### New Package

Add to appropriate `RUN apt-get install` section in Pifile.

### New Service

1. Add service file to `etc/systemd/system/`
2. Enable in Pifile: `RUN systemctl enable <service>.service`
3. Add dependencies/configuration as needed

### New Python Package

1. Add as git submodule in `home/pi/`
2. Install in Pifile: `RUN python3 -m pip install --no-deps -e /home/pi/<package>`
3. Install apt dependencies separately if needed

### Custom Files

Place files in directory structure matching target filesystem:
- `etc/` → `/etc/`
- `boot/` → `/boot/`
- `usr/` → `/usr/`

Use `INSTALL` command in Pifile to copy.

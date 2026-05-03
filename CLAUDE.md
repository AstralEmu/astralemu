# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AstralEmu is a unified multi-device Linux emulation distribution image builder. It produces ready-to-flash images for multiple devices (Raspberry Pi 4, Raspberry Pi 5, Nintendo Switch, and more) from a single codebase. All shell scripts use bash with `set -e`.

## Key Commands

```bash
# List available devices and services
./bin/autobuild --list-images

# Build a specific image (full pipeline)
./bin/autobuild --image rpi4/default+emulations
./bin/autobuild --image rpi5/debian/default+emulations
./bin/autobuild --image switch/default+emulations+desktop

# Build all images from .github/images.txt
./bin/autobuild --all-images

# Run individual stages (useful for development)
./bin/autobuild --image rpi4/default+emulations --stage 1   # Download + setup ISO
./bin/autobuild --image rpi4/default+emulations --stage 2   # QEMU setup
./bin/autobuild --image rpi4/default+emulations --stage 3   # Output format modules

# Skip stages (resume from existing work)
./bin/autobuild --image rpi4/default+emulations --skip-download
./bin/autobuild --image rpi4/default+emulations --skip-qemu

# Upgrade only (skip full build, just upgrade packages in cached work-image via chroot)
./bin/autobuild --image rpi4/default+emulations --upgrade-only
```

### Image Name Format

```
<device>/<distro>/<services>   # Full: rpi4/debian/default+emulations
<device>/<services>            # 1st distro default: rpi4/default+emulations
<device>                       # Base only: rpi4
```

## Architecture

### Build Pipeline (3 stages)

The `bin/autobuild` orchestrator:

1. **Stage 1** — Downloads base cloud image, generates cloud-init user-data from `devices.yml` (`DEVICE_USER` is the single source of truth), builds a combined `setup.sh` from all service modules, packages everything into `setup.iso`
2. **Stage 2** — Boots QEMU with the cloud image + seed.img + setup.iso. Cloud-init creates the user, mounts the ISO, runs `setup.sh`, then powers off. Verifies `/root/setup-completed` flag exists in the image afterward
3. **Stage 3** — Sources the output format module (`output_formats/<name>/build.sh`) and calls `output_<name>()` to produce the final deliverable from the QEMU work image

### How Services Get Combined

`build_services_setup()` in `bin/autobuild` is the key function. It:

1. Resolves service dependencies via `depends.sh` files (recursive, depth-first)
2. Creates a combined `setup.sh` by concatenating each service's `setup.sh` (skipping shebang/set-e lines), prefixed with device variables and auto-generated repo config from `devices.yml`
3. Copies all `setupfiles/` directories into a combined setupfiles tree
4. Builds `services-first-boot.sh` by injecting each service's `first-boot/init.sh` before the `# ====== END SERVICES INITIALIZATION ======` marker
5. Packages everything into an ISO mounted as a virtio drive in QEMU

### Service Resolution (2 levels, device-specific wins)

```
devices/<device>/services/<name>/   <- checked first (e.g. kernel, firmware)
services/<name>/                    <- shared fallback (e.g. emulations, desktop)
```

The `resolve_service_path()` function handles this. A service directory can contain:

| File | Purpose |
|------|---------|
| `setup.sh` | Runs inside QEMU during stage 2 (package installation, config) |
| `packages.yml` | Multi-distro package list, installed via `pkg_service_install <name>` (see below) |
| `depends.sh` | Declares `DEPENDS_ON="service1 service2"` for dependency ordering |
| `setupfiles/` | Files copied into the ISO, available at `/etc/setupfiles/` inside QEMU |
| `first-boot/init.sh` | Injected into `services-first-boot.sh`, runs on first real boot |
| `motd.sh` | Copied to `setupfiles/motd.d/<service>.sh` |

### The `prepare` Service (special)

`services/prepare/setup.sh` is **always** auto-injected first (regardless of `depends.sh`) and exposes the package abstraction used everywhere else. New services should call these helpers instead of `apt-get`/`dnf`/`pacman` directly:

- `pkg_update` — refresh package indexes
- `pkg_install <pkg>...` — install via `$PKG_MANAGER` (apt / dnf / pacman, auto-detected)
- `pkg_service_install <name>` — install the packages declared in `services/<name>/packages.yml` for the current distro

`packages.yml` format (multi-distro, all keys optional):

```yaml
packages:
  apt:    [...]   # base for any apt distro (Debian + Ubuntu)
  ubuntu: [...]   # merged with apt[] when DISTRO_ID=ubuntu
  debian: [...]   # merged with apt[] when DISTRO_ID=debian
  fedora: [...]   # used by dnf
  arch:   [...]   # used by pacman
```

### Service Script Conventions

Scripts in `setup.sh` run inside the QEMU guest as root. They should:
- Prefer the `pkg_*` helpers from `prepare` over raw `apt-get`/`dnf`/`pacman` — the codebase supports apt, dnf, and pacman, not just Debian/Ubuntu
- Use `export DEBIAN_FRONTEND=noninteractive` and `APT_OPTS="--no-install-recommends -y"` when apt-specific code is unavoidable
- Branch on `$PKG_MANAGER` (`apt`/`dnf`/`pacman`) or `$DISTRO_ID` (`ubuntu`/`debian`/`fedora`/`arch`) when behavior must differ between distros
- Reference device variables via exported env vars (see below)
- Use `$PKG_DEVICE_ID` suffix for device-specific packages (e.g. `emulationstation-de-$PKG_DEVICE_ID`)
- Place persistent configs under `$DEVICE_HOME` (e.g. `/home/switch/.config/`)

### Key Variables Available to Services

Set by `bin/autobuild` and exported before service scripts run:

| Variable | Example | Source |
|----------|---------|--------|
| `$DEVICE_ID` | `switch` | `devices.yml` |
| `$DEVICE_POWER` | `3` (1-5) | **Remote**: fetched from [astralemu-packages/devices.yml](https://raw.githubusercontent.com/AstralEmu/astralemu-packages/refs/heads/main/devices.yml) via `pkg_device_id` — filters emulators by device capability. Do not edit locally |
| `$DEVICE_ARCH` | `arm64` | `devices.yml` |
| `$DEVICE_USER` | `switch` | `devices.yml` — single source of truth for user creation |
| `$DEVICE_HOME` | `/home/switch` | Derived |
| `$DATA_ROOT` | `/sd` | `devices.yml` — where ROMs/saves go (defaults to `$DEVICE_HOME`) |
| `$PKG_DEVICE_ID` | `l4t` | `devices.yml` — suffix for device-specific packages |
| `$DISTRO_ID` | `ubuntu` | `devices.yml` |

### Device Configuration

`devices.yml` is the central config defining all devices with QEMU settings, output formats, distros, and repos. Power scores live in [astralemu-packages](https://github.com/AstralEmu/astralemu-packages) (single source of truth) and are fetched at build time via `pkg_device_id` — never add a `power:` field to the local `devices.yml`. Each device also has:

- `devices/<id>/config.sh` — Device-specific shell variables NOT in devices.yml (e.g. `RASPIOS_URL`, partition sizes, compression settings). Sourced by autobuild and appended to the temp config
- `devices/<id>/cloudinit/` — Optional meta-data/user-data templates (autobuild now generates user-data from `DEVICE_USER`)

### Output Format Modules

Each module in `output_formats/<name>/build.sh` defines an `output_<name>()` function that takes the QEMU work image (`$WORK_IMAGE`) and produces a deliverable:

- **rpi** — Downloads RaspiOS vendor image -> merges rootfs via `merge-debian-raspios.sh` -> PiShrink + xz -> flashable `.img.xz`
- **hekate** — Extracts rootfs -> SquashFS + FAT32-split -> homefs ext4 -> custom initramfs -> kernel/DTB/coreboot -> Hekate SD card folder structure

Adding a new format: create `output_formats/<name>/build.sh` with `output_<name>()`, add `<name>` to the device's `output:` list in `devices.yml`.

## Adding a New Device

1. Add entry in `devices.yml` (id, name, arch, user, pkg_device_id, runner, qemu, output, distros with repos)
2. Create `devices/<id>/config.sh` with device-specific variables
3. Create `devices/<id>/services/base/setup.sh` for kernel/firmware/drivers
4. Create `devices/<id>/services/base/setupfiles/services-first-boot.sh` and `.service`
5. Create `devices/<id>/cloudinit/meta-data` (optional, autobuild generates a default)

## Adding a New Service

1. Create `services/<name>/setup.sh` (or `devices/<device>/services/<name>/setup.sh` for device-specific)
2. Add `packages.yml` listing packages per distro family, then call `pkg_service_install <name>` from `setup.sh`
3. Optionally add `depends.sh` with `DEPENDS_ON="service1 service2"`. The `prepare` service (which provides the `pkg_*` helpers) is auto-injected first — no need to depend on it explicitly
4. Optionally add `first-boot/init.sh` for tasks needing real hardware
5. Optionally add `setupfiles/` for static files needed during setup

## GitHub Actions CI/CD

- **Triggers**: Weekly Thursday 4AM UTC (after package builds Sun/Wed), manual dispatch
- **Matrix**: Auto-generated from `.github/images.txt` + runner from `devices.yml`
- **Pipeline**: detect-images -> stage1-2 (parallel per image) -> create-release -> stage3-output (parallel) -> cleanup-release
- **Releases**: main -> stable, test/preview -> pre-releases, empty releases auto-deleted
- **Cache**: Base images cached by `devices.yml` hash. Work-images cached by a fingerprint that includes every resolved service's `setup.sh` + `packages.yml` + `depends.sh`, plus `bin/autobuild` and `devices/<id>/config.sh` (see `build_services_setup()` in `bin/autobuild`). Cache hit = `--upgrade-only` (chroot pkg upgrade), cache miss = full build (stage 1+2). Editing a service's `packages.yml` invalidates the cache and triggers a full rebuild for any image that pulls that service in

## Technical Notes

### Boot Modes

- **cloud-init** (`build_format: cloud-init` in `devices.yml`): Generates seed.img ISO with user-data/meta-data, cloud-init creates user and runs setup
- **firstboot** (`build_format: docker` or other): Injects a systemd service into the rootfs via loop mount

### Why RaspiOS Kernel for RPi

The Raspberry Pi kernel includes RP1 southbridge drivers (Ethernet, USB, GPIO) not yet in mainline Linux. The `base` service installs it via APT with pinning.

### Why Custom Initramfs for Switch

The Switch uses a read-only SquashFS rootfs with tmpfs overlays. The initramfs (`output_formats/hekate/create-initramfs.sh`) handles SquashFS assembly from FAT32-split parts and overlay mounting.

### Switch L4T Package Installation

NVIDIA L4T/switch-bsp packages check `/proc/device-tree/compatible` in preinst scripts, which doesn't exist in QEMU. The Switch base service downloads debs, strips preinst scripts with `dpkg-deb -R`/`-b`, then installs with `dpkg --unpack --force-depends`.

## Dependencies

```bash
# Core
sudo apt install -y yq wget xz-utils genisoimage

# Stage 2 (QEMU)
sudo apt install -y qemu-system-aarch64 qemu-utils qemu-efi-aarch64

# Output modules
sudo apt install -y parted e2fsprogs dosfstools rsync squashfs-tools
```

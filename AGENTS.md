# AGENTS.md — AstralEmu Quick Reference

## Core Commands

```bash
./bin/autobuild --list-images              # List devices/services
./bin/autobuild --image rpi4/default+emulations
./bin/autobuild --image <name> --stage 1|2|3
./bin/autobuild --image <name> --skip-download|--skip-qemu
./bin/autobuild --image <name> --upgrade-only  # chroot pkg upgrade on cached work-image
```

## Build Pipeline (3 Stages)

1. **Stage 1** — Download base cloud image, generate cloud-init from `DEVICE_USER`, combine service `setup.sh` scripts into one, create `setup.iso`
2. **Stage 2** — QEMU boots with work-image + seed.img + setup.iso (virtio). Cloud-init runs `setup.sh` inside guest, powers off. Verifies `/root/setup-completed`
3. **Stage 3** — Source `output_formats/<name>/build.sh`, call `output_<name>()` to produce final deliverable

## Service Resolution (Critical)

Services resolve 2-level: `devices/<device>/services/<name>/` wins over `services/<name>/`

**Special `prepare` service**: Auto-injected first, provides `pkg_*` helpers. Do NOT depend on it explicitly.

**Dependency ordering**: `depends.sh` declares `DEPENDS_ON="svc1 svc2"`. Resolver does depth-first recursion — dependencies run before dependents.

**Combined setup.sh structure**:
```bash
# Device variables (DEVICE_ID, DEVICE_USER, etc.)
# prepare/setup.sh content
# service1/setup.sh (depends resolved first)
# service2/setup.sh
# ... cleanup, /root/setup-completed flag
```

## Package Helpers (from `prepare`)

Always use these in `setup.sh` instead of raw apt/dnf/pacman:

```bash
pkg_update                    # Refresh indexes
pkg_install <pkg>...          # Install via $PKG_MANAGER
pkg_service_install <name>    # Install from services/<name>/packages.yml
pkg_clean                     # Cleanup
```

**`packages.yml` format**:
```yaml
packages:
  apt:    [common apt pkgs]
  ubuntu: [ubuntu-specific]   # merged with apt[] when DISTRO_ID=ubuntu
  debian: [debian-specific]   # merged with apt[] when DISTRO_ID=debian
  fedora: [dnf pkgs]
  arch:   [pacman pkgs]
```

## Key Variables (Exported to Services)

| Variable | Example | Note |
|----------|---------|------|
| `$DEVICE_ID` | `switch` | From devices.yml |
| `$DEVICE_POWER` | `3` | **Remote**: fetched from astralemu-packages via `pkg_device_id`. Filters emulators by capability |
| `$DEVICE_ARCH` | `arm64` | |
| `$DEVICE_USER` | `switch` | Single source of truth for user creation |
| `$DEVICE_HOME` | `/home/switch` | Derived |
| `$DATA_ROOT` | `/sd` | ROMs/saves location (defaults to `$DEVICE_HOME`) |
| `$PKG_DEVICE_ID` | `l4t` | Package suffix (e.g. `emulationstation-de-l4t`) |
| `$DISTRO_ID` | `ubuntu` | |
| `$PKG_MANAGER` | `apt`| `dnf`|`pacman` | Auto-detected |

## Cache Behavior (CI/CD)

**Work-image cache key** includes:
- `devices.yml`, `bin/autobuild`, remote `devices.yml` (power scores)
- All resolved service `setup.sh` + `packages.yml` + `depends.sh`
- Device `config.sh`

**Cache hit** → `--upgrade-only` (chroot pkg upgrade, no QEMU)
**Cache miss** → Full build (stage 1+2)

Editing a service's `packages.yml` invalidates cache for all images using that service.

## Technical Quirks

**Switch L4T packages**: Preinst scripts check `/proc/device-tree/compatible` (missing in QEMU). Base service strips preinst via `dpkg-deb -R`/`-b`, installs with `dpkg --unpack --force-depends`.

**Raspberry Pi kernel**: Uses RaspiOS kernel (not mainline) for RP1 southbridge drivers. Installed via APT pinning.

**Switch rootfs**: Read-only SquashFS + tmpfs overlay. Custom initramfs (`output_formats/hekate/create-initramfs.sh`) handles FAT32-split reassembly.

**Boot modes**:
- `cloud-init` (`build_format: cloud-init`): seed.img + cloud-init
- `firstboot` (`build_format: docker`|`tarball`): systemd service injected via loop mount

## Script Conventions

Service `setup.sh` scripts run as root inside QEMU guest:

```bash
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# Use pkg_* helpers
pkg_service_install emulations

# Branch on distro if needed
if [ "$DISTRO_ID" = "debian" ]; then
  :
fi

# Place configs under $DEVICE_HOME
mkdir -p "$DEVICE_HOME/.config/emulationstation"
```

## File Locations

```
devices.yml                          # Central device config (local)
devices/<id>/config.sh               # Device-specific vars (RASPIOS_URL, etc.)
devices/<id>/services/<name>/        # Device-specific services (kernel, firmware)
services/<name>/                     # Shared services (emulations, desktop)
output_formats/<name>/build.sh       # Output module (output_<name>() function)
.github/images.txt                   # CI build list
```

## Adding a Service

1. Create `services/<name>/setup.sh` → call `pkg_service_install <name>`
2. Add `services/<name>/packages.yml` with multi-distro package lists
3. Optional: `depends.sh`, `first-boot/init.sh`, `setupfiles/`, `motd.sh`

## Adding a Device

1. Add entry in `devices.yml` (id, arch, user, pkg_device_id, runner, qemu, output, distros)
2. Create `devices/<id>/config.sh`
3. Create `devices/<id>/services/base/` for kernel/firmware
4. Power scores: edit [astralemu-packages/devices.yml](https://github.com/AstralEmu/astralemu-packages), NOT local file

## Prerequisites

```bash
sudo apt install -y yq wget xz-utils genisoimage \
  qemu-system-aarch64 qemu-utils qemu-efi-aarch64 \
  parted e2fsprogs dosfstools rsync squashfs-tools
```

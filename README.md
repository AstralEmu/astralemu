<p align="center">
  <img src="https://github.com/AstralEmu/.github/raw/refs/heads/main/profile/banner-astralemu.svg" alt="AstralEmu" width="100%"/>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/build-daily-f2d974?style=flat-square" alt="Build"/>
  <img src="https://img.shields.io/badge/base-Ubuntu%20|%20Debian%20|%20Arch%20|%20UBlue-1a1a4e?style=flat-square" alt="Base"/>
  <img src="https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square" alt="License"/>
</p>

# AstralEmu

A minimal Linux distribution built for emulation. AstralEmu strips the base system down to the essentials and layers on optimized emulators, a dynamic performance manager, and a clean EmulationStation DE frontend — everything tuned for your specific hardware.

---

## Architecture

```
┌──────────────────────────────────────────────────┐
│                EmulationStation DE               │  ← Custom theme
├──────────┬──────────┬───────────┬────────────────┤
│   XFCE   │  Plasma  │   Kodi    │   Waydroid     │  ← Optional services
│          │  Mobile  │           │                │    (one at a time)
├──────────┴──────────┴───────────┴────────────────┤
│          Performance Manager (per-emu)           │  ← CPU/GPU/RAM tuning
├──────────────────────────────────────────────────┤
│       Emulators + RetroArch (daily builds)       │  ← LTO=thin + jemalloc
├──────────────────────────────────────────────────┤
│   Ubuntu / Debian / Arch Linux / Universal Blue  │  ← Minimal base image
└──────────────────────────────────────────────────┘
```

## Image Builder

The build system is a GitHub Actions workflow that dynamically manages every axis of the build matrix:

- **Services** — Which optional services to bundle (XFCE, Plasma Mobile, Kodi, Waydroid)
- **Source image** — Ubuntu, Debian, Arch, or Universal Blue base
- **Export format** — Raw, compressed, flashable images
- **Filesystem shrink** — Automatic image compaction
- **CPU architecture** — ARM64, x86_64, and device-specific targets
- **Schedule** — Full rebuild every 24 hours

## Package Repositories

AstralEmu maintains its own APT, DNF, and Pacman repositories. Every standalone emulator and RetroArch core is rebuilt daily from source with:

- **Architecture-specific compilation** — Packages are built targeting the exact CPU features of each supported device
- **LTO=thin** — Link-time optimization for smaller, faster binaries
- **jemalloc** — Replaces the default allocator for better memory performance
- **Hardware dependencies** — Device-specific packages for embedded targets (RK3588, etc.)

## Performance Manager

Each hardware target gets a dedicated performance package that dynamically adjusts system parameters when an emulator or service launches:

| Parameter | What it does |
|---|---|
| CPU governor | Switches between powersave, performance, schedutil per emulator |
| GPU governor | Adjusts GPU frequency scaling |
| RAM governor | Tunes memory controller frequency |
| Overclock / Underclock | Per-emulator CPU, GPU, and RAM clock targets |
| CPU pinning | Assigns emulator processes to specific cores (big.LITTLE aware) |
| Power safety | Automatically limits clocks on battery or low-power adapters |

All of this happens transparently — the user just launches a game.

## Service Management

AstralEmu enforces a single-service model:

1. **ES-DE** is the default and always-running frontend
2. When the user launches an optional service (XFCE, Kodi, Plasma Mobile, Waydroid), **ES-DE stops**
3. When the optional service exits, **ES-DE restarts automatically**

This guarantees that only one graphical service runs at any time, maximizing available resources.

## Updates

| Base | Update method |
|---|---|
| Universal Blue | Native `rpm-ostree` image-based updates |
| Ubuntu / Debian / Arch | Reproduced atomic-style update flow mirroring the UBlue model |

Updates are seamless and happen in the background.

## Getting Started

1. Download the image for your device from the [releases page](https://github.com/AstralEmu/astralemu/releases)
2. Flash it to your SD card or eMMC
3. Boot and play

Full setup guides and device compatibility are available on the [documentation site](https://astralemu.github.io).

## Contributing

Contributions are welcome — whether it's adding support for a new device, packaging an emulator, improving the performance profiles, or working on the documentation. Check out the [Discussions](https://github.com/orgs/AstralEmu/discussions) to get started.

---

<p align="center">
  <a href="https://astralemu.github.io">Documentation</a> •
  <a href="https://github.com/orgs/AstralEmu/discussions">Community</a> •
  <a href="https://github.com/AstralEmu/astralemu-packages">Packages</a>
</p>

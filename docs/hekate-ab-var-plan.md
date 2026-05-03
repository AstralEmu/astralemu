# Hekate A/B + /var Unified Plan

## Audit Summary

### Current Architecture

```
SD card (FAT32):
/switchroot/<name>/{Image, initramfs.img, boot.scr, nx-plat.dtimg, coreboot.rom}
/linux_img/<name>/rootfs/{rootfs.squashfs.part000, .part001, ...}
/linux_img/<name>/homefs/{homefs.ext4.part000, .part001, ...}
/bootloader/ini/<name>.ini
```

Boot chain: Hekate → coreboot → bl31/bl33 → U-Boot → boot.scr → kernel + initramfs → switch_root → systemd

Runtime mounts:
- `/` = squashfs read-only (single slot, no rollback)
- `/home` = ext4 writable (loop/dm-linear, expandable via daemon)
- `/etc` = overlay (lower=squashfs, upper=homefs/.overlays/etc/upper)
- `/var` = overlay (lower=squashfs, upper=homefs/.overlays/var/upper)
- `/sd` = FAT32 moved from initramfs

### Critical Bugs Found

| # | Severity | Bug |
|---|----------|-----|
| 1 | CRITICAL | Blank homefs created without mkfs.ext4 → mount fails → shell drop |
| 2 | CRITICAL | No e2fsck before resize2fs; no fsck on boot |
| 3 | CRITICAL | No dmsetup suspend before reload (comment says suspend, code doesn't) |
| 4 | HIGH | loop→dm transition umounts /home without error recovery; if mount fails, /home gone |
| 5 | MEDIUM | 21 loop device limit caps homefs at ~20 GB |
| 6 | MEDIUM | No shrink/cleanup path — parts only grow |
| 7 | MEDIUM | sparse dd on FAT32 writes full 1.9 GB (FAT32 doesn't support sparse) |
| 8 | MEDIUM | Cross-arch initramfs: losetup/dmsetup libs copied from x86_64 host |
| 9 | MEDIUM | No checksum verification on squashfs parts |
| 10 | LOW | set -e contradicts if [ $? -ne 0 ] error handling pattern |
| 11 | LOW | root=/dev/ram0 misleading in boot.scr |
| 12 | LOW | Duplicate init embedded in create-initramfs.sh (overwritten by external file) |
| 13 | HIGH | No A/B slot mechanism — single rootfs, no rollback |
| 14 | HIGH | /var as overlay incompatible with bootc (must be real persistent fs) |

---

## New Design: A/B Slots + /var Unified

### Principles

1. A/B slot for rootfs: two squashfs, one active, one for updates
2. /var as dedicated persistent ext4 partition (no overlay)
3. /etc as overlay (lower=active slot squashfs, upper=/var/astralemu/etc-overlay)
4. /home → bind mount from /var/home (bootc-aligned standard)
5. Same design for all distros: SquashFS A/B for debian/ubuntu/fedora, ostree-in-squashfs for ublue
6. Boot verification: SHA256 checksum on every squashfs part, boot counter for auto-rollback

### New SD Card Layout

```
/linux_img/<name>/
  slot/
    a/                                           ← Slot A
      rootfs.squashfs.part000 [,.part001, ...]
      rootfs.squashfs.sha256
    b/                                           ← Slot B
      rootfs.squashfs.part000 [,...]
      rootfs.squashfs.sha256
  slot                                           ← text file: "a" or "b"
  slot-a.tries                                   ← boot counter (3→2→1→0 = fallback)
  slot-b.tries                                   ← boot counter
  var/
    var.ext4.part000 [,.part001, ...]             ← /var persistent (ext4, expandable)
```

### Initramfs Boot Sequence

```
1. Mount SD card (FAT32) → /sd
2. Read /sd/linux_img/<name>/slot → active slot (a or b)
3. Read /sd/linux_img/<name>/slot-<X>.tries → boot attempt counter
4. Verify SHA256 of active slot's squashfs parts
5. If checksum fails OR no tries left → try other slot → update slot file
6. Assemble squashfs (loop or dm-linear) → mount read-only → /rootfs
7. Assemble varfs (loop or dm-linear) → mount ext4 rw → /rootfs/var
8. fsck varfs if dirty (e2fsck -p)
9. Mount overlay /etc (lower=/rootfs/etc, upper=/rootfs/var/astralemu/etc-overlay/upper)
10. Setup /rootfs/var/home if not exists
11. Bind mount /rootfs/var/home → /rootfs/home (if DATA_ROOT=/sd)
12. Bind mount /rootfs/var/home → /rootfs/sd/<name>/home (or /rootfs/home for traditional)
13. Move /sd → /rootfs/sd
14. Write /rootfs/run/astralemu-info (slot, varfs dev, etc.)
15. switch_root /rootfs /sbin/init
```

### A/B Update Mechanism

- astralemu-update tool runs on the live system
- Writes new squashfs parts into inactive slot
- Verifies SHA256
- Sets slot file to new slot, tries = 3
- Reboots
- On successful boot: astralemu-slot-verify.service marks slot as good (clears tries counter)
- On failed boot: tries counter decremented; at 0, fallback to other slot

### Homefs → Varfs Rename

- homefs-expand-daemon.sh → varfs-expand-daemon.sh (mounts /var, same dm-linear+resize2fs)
- homefs-expand.service → varfs-expand.service
- /var is the expandable filesystem (same mechanism as current homefs)
- /home is a bind mount from /var/home

### Bug Fixes in Implementation

| Fix | Description |
|-----|-------------|
| SHA256 verification | Every squashfs part gets a .sha256 during build, verified in initramfs |
| e2fsck before mount | Add e2fsck -p to initramfs before mounting varfs |
| e2fsck before resize2fs | Add to varfs-expand-daemon |
| dmsetup suspend | Add dmsetup suspend before reload in daemon |
| Remove blank homefs path | Never create blank varfs in initramfs; always ship pre-formatted |
| Increase loop devices | Create 64 loop devices in initramfs (loop0–loop63) |
| Fix cross-arch initramfs | Copy libs from WORK_IMAGE chroot, not from build host |
| Remove root=/dev/ram0 | Remove root= parameter from boot.scr (initramfs handles everything) |
| Remove duplicate init | create-initramfs.sh: only use external init file, remove embedded heredoc |
| Fix sparse dd on FAT32 | Use dd with count=PART_SIZE_MB instead of seek (writes full file anyway on FAT32) |
| Fix set -e in daemon | Remove set -e, use explicit error handling throughout |

### Bootc/Silverblue Compat

For ublue builds on Switch:
- bootc-image-builder produces a raw disk with ostree deployment
- output_hekate extracts /usr from the ostree deployment, packs it into squashfs (slot a)
- /var is the same persistent ext4 partition
- ostree's /etc three-way merge works because /etc is an overlay on top of /usr/etc
- A/B updates are the same slot mechanism — write new ostree squashfs to inactive slot

### File Changes

| # | File | Change |
|---|------|--------|
| 1 | `devices/switch/initramfs/init` | Full rewrite: slot A/B, checksum, varfs, overlay /etc only |
| 2 | `devices/switch/initramfs/scripts/mount-rootfs.sh` | Support slot A/B, SHA256 verification |
| 3 | `devices/switch/initramfs/scripts/mount-homefs.sh` | Rename to mount-varfs.sh, mount on /rootfs/var, add e2fsck |
| 4 | `devices/switch/initramfs/scripts/setup-overlays.sh` | Overlay /etc only (lower=slot, upper=/var/astralemu/etc-overlay) |
| 5 | NEW | `devices/switch/initramfs/scripts/verify-slot.sh` — slot selection, checksum, fallback |
| 6 | `output_formats/hekate/build.sh` | Generate slot-a layout, SHA256, varfs, slot file, slot-a.tries |
| 7 | `output_formats/hekate/create-initramfs.sh` | Remove embedded init, copy libs from chroot, create 64 loop devs |
| 8 | `output_formats/hekate/split-image.sh` | No changes (used for both squashfs and varfs) |
| 9 | `devices/switch/services/base/setupfiles/homefs-expand-daemon.sh` | Rename to varfs-expand, mount on /var, add e2fsck, dmsetup suspend, error handling |
| 10 | `devices/switch/services/base/setupfiles/homefs-expand.service` | Rename to varfs-expand.service |
| 11 | `devices/switch/services/base/setup.sh` | Bind mount /var/home → /home, create /var/home/.overlays, update service names |
| 12 | `devices/switch/config.sh` | Add VARFS_PART_SIZE_MB, SLOT_A/B naming |
| 13 | NEW | `devices/switch/services/base/setupfiles/astralemu-slot-verify.service` |
| 14 | NEW | `devices/switch/services/base/setupfiles/astralemu-slot-verify.sh` |
| 15 | `output_formats/hekate/build.sh` boot.scr | Remove root=/dev/ram0 |

### Implementation Order

1. Fix initramfs (init, scripts, verify-slot) — this is the boot foundation
2. Fix create-initramfs.sh (cross-arch, loop devs, remove duplicate)
3. Fix build.sh (A/B layout, SHA256, varfs, slot files, boot.scr)
4. Fix runtime (varfs-expand daemon, astralemu-slot-verify, /var/home bind)
5. Fix setup.sh (service names, /var/home, overlays)
6. Fix config.sh (varfs params)
7. Test end-to-end
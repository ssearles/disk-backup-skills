---
name: rescuetzilla-backup-workflow
description: >
  Set up and maintain a multi-machine disk-image backup workflow with Rescuezilla
  on Linux/Omarchy: choosing backup media and filesystems, partition layout,
  labelling and identifying drives, copying image sets between disks, keeping
  two independent copies in sync, restoring an image, and troubleshooting
  "disk not found" or writes failing on the backup target. Triggers: rescuetzilla,
  clonezilla backup, image laptop disks, backup six laptops, backup drive not
  writable, backup to external hard drive, copy backup images between disks,
  grsync setup for backups, exfat vs ntfs for backup disk, second copy of
  backups, restore a laptop image, 3-2-1 backup on Linux. Excludes
  application-level file sync (Syncthing, rsync-only workflows), server
  backup systems, and ZFS/Btrfs/LVM storage pools.
---

# Rescuezilla Backup Workflow

Field-tested on Omarchy (Arch/Hyprland) backing up six laptops to two external
2 TB USB drives. Omarchy-agnostic — Rescuezilla boots its own Linux, so only
the host-side steps are distro-specific.

**Confidence markers:** `[PROVEN]` directly observed, `[INFERRED]` concluded
from output but not isolated in a test.

---

## The architecture

Two identical external drives, each holding a full set of per-machine image
directories:

```
BACKUPS/                       <- drive 1
├── LenovoT440p_boot/2026-10-08-1701-img-rescuezilla/
│   ├── sda2.dd-ptcl-img.gz.aa … .al
│   ├── sda-pt.sf, sda-mbr, disk, parts
│   └── Info-*.txt, blkdev.list, blkid.list
├── Lenovo_T420_boot/
├── HP-Pav(new)-15-ab243cl_boot/
└── …one directory per disk half

BACKUPS-2/                     <- drive 2, byte-identical
```

**Rule:** every backup goes to both drives. Never to just one. A single drive
cannot protect against a single drive.

---

## Media choice

2 TB 2.5" 5400 rpm drives were adequate; ~118 GB used across six machines
leaves plenty of headroom for a decade of backups.

**Prefer two drives over one larger one.** Two independent drives fail
independently. One 4 TB disk is one failure domain.

### Filesystem: exFAT

For backup media written by Rescuezilla (Linux) and sometimes read on Windows:

| Format | Verdict |
|---|---|
| **exFAT** | ✅ **Use this.** No size limit, no dirty-flag trap, robust directories |
| NTFS | ⚠️ Windows Fast Startup leaves it dirty; Linux then mounts read-only |
| FAT32 | ❌ 4 GB file limit; fragile directories — the original problem |

See `linux-disk-diagnostics` for the full comparison and migration procedure.

For 2 TB, format with 32 MB clusters, sized for multi-GB image splits:

```bash
sudo mkfs.exfat -n BACKUPS -c 32M /dev/disk/by-id/ata-<model>_<serial>-part1
```

### Keep the drives unpartitioned-predictable

One partition spanning the whole disk. No separate EFI or swap — this is data
media, and every extra structure is another thing to go wrong.

---

## Setting up a drive

Full procedure in `linux-disk-diagnostics`. The essentials:

```bash
# 1. Identify — never by /dev/sdX
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,LABEL,MOUNTPOINT
DEV=/dev/disk/by-id/ata-<model>_<serial>

# 2. Verify serial before anything destructive
[ "$(lsblk -ndo SERIAL "$DEV" | tr -d ' ')" = "EXPECTED" ] || exit 1

# 3. Unmount, zero, partition
sync && udisksctl unmount -b "${DEV}-part1"
sudo dd if=/dev/zero of="$DEV" bs=1M count=200 conv=fsync status=none
sudo parted -s "$DEV" mklabel gpt
sudo parted -s -a optimal "$DEV" mkpart primary 1MiB 100%

# 4. CRITICAL: unmount AFTER partprobe — udisks2 auto-mounts
sudo partprobe "$DEV"; sudo udevadm settle; sleep 3
sudo umount "${DEV}-part1" 2>/dev/null

# 5. Format
sudo mkfs.exfat -n BACKUPS -c 32M "${DEV}-part1"
```

Label drives distinctly — `BACKUPS` and `BACKUPS-2` — so you can tell them
apart with both plugged in. Same name on both is a mistake you will make.

---

## Taking a backup

1. Write the Rescuezilla USB stick (or boot it from an existing one)
2. Boot the target laptop, **select the internal disk as SOURCE**
3. **Select the external drive as DESTINATION**
4. Choose a save location — a directory named for the machine and disk half:
   `LenovoT420_boot/`, `Lenovo_T420_caddy/`
5. Run, then verify the image completes without error before rebooting
6. Eject cleanly — Rescuezilla handles this, but don't yank the USB

**Back up both halves.** Images commonly span two partitions; a `_boot` without
its `_caddy` partner is not a complete restore. The caddy partition is often
where the user's actual data lives.

### After every backup

Sync to the second drive (below). Do this immediately — the value of the second
copy is highest right after a new image exists.

---

## Copying images between drives

### rsync, and the trailing slash

`[PROVEN]` This decides the directory layout and is the single most common
footgun:

| Source | Result |
|---|---|
| `/run/media/steven/BACKUPS-2` | Creates a **`BACKUPS-2/` wrapper folder** |
| `/run/media/steven/BACKUPS-2/` | Copies the **contents** — correct |

The wrapper appears because GUIs fill in paths without a trailing slash.
**In any GUI file manager, type the path yourself** — there is no other way to
express "the contents of."

### Prefer Grsync for routine syncing

```bash
sudo pacman -S grsync        # Arch; grsync in Debian/Ubuntu repos
```

Settings that matter:

| Option | State | Why |
|---|---|---|
| **Preserve time** | ✅ on | Lets repeat runs skip unchanged files |
| Verbose | ✅ on | See per-file progress |
| Delete on destination | ⬜ **off** | Stops accidental erasure propagating |
| Ignore existing | ⬜ off | Blindly trusts existence; misses silent corruption |
| Preserve permissions / owner / group | ⬜ off | exFAT has no such concepts; rsync would error per file |

Grsync's two top buttons matter:

- **ⓘ (blue) — Preview.** Dry run, transfers nothing. Read the byte count: a
  few thousand bytes means nothing was copied, which is correct for a preview.
- **⭕ (green +) — Execute.** The real transfer.

**Save sessions as presets** (Sessions → Save As) so paths — trailing slash
included — are stored correctly.

`[PROVEN]` No file manager exposes a "default to copy, never move" setting for
drag-and-drop. GTK-level behaviour, not a per-app preference. Workarounds:
hold **Ctrl** while dropping, **right-click drag** for an explicit Copy/Move
menu, or use **Ctrl+C / Ctrl+V** which is unambiguous.

### Routine sync procedure

```
1. Rescuezilla backup completed on drive 1
2. Plug in drive 2 if not attached
3. grsync → select preset → click ⭕
4. Only the new directory transfers
```

Expect ~10 minutes for ~74 GB at 135 MB/s. Check real throughput first — a
USB2 link caps around 40 MB/s:

```bash
for d in /sys/bus/usb/devices/*/; do
  p=$(cat $d/product 2>/dev/null)
  [ -n "$p" ] && echo "$(basename $d): $(cat $d/speed) Mbit/s  '$p'"
done
```

A USB3 device in a USB3 port appears on **both** the 480 and 5000 buses.
Appearing only at 480 means the port, cable, or enclosure is the limit — try
another port before blaming the drive.

### Never interrupt a copy

`[PROVEN]` Killing `rsync --remove-source-files` or a cross-device `mv`
mid-flight leaves duplicates: files copied to the destination with originals
not yet deleted. Recoverable, but alarming. Recover by wiping the
half-finished destination and re-running cleanly.

Run long transfers in the background so a tool timeout cannot kill them:

```bash
nohup ./copy.sh > /tmp/copy.log 2>&1 &
```

---

## Verifying a copy

`[PROVEN]` Sort both sides before diffing — parallel `xargs` emits results in
completion order, so identical hashes in different order read as a false
MISMATCH:

```bash
( cd "$SRC" && find . -type f -print0 | xargs -0 sha256sum | sort ) > src.sums
( cd "$DST" && find . -type f -print0 | xargs -0 sha256sum | sort ) > dst.sums
diff -q src.sums dst.sums && echo IDENTICAL
```

`[INFERRED]` Sequential (no `-P N`) took ~30 min for 118 GB; `-P 4` took ~6 h,
apparently from four processes contending for one USB controller. Not
benchmarked — use one process.

Also compare plainly, which catches gross problems fast:

```bash
echo "src: $(find "$SRC" -type f | wc -l) files, $(du -sb "$SRC" | cut -f1) bytes"
echo "dst: $(find "$DST" -type f | wc -l) files, $(du -sb "$DST" | cut -f1) bytes"
```

---

## Restoring

1. Boot the target laptop from the Rescuezilla USB
2. **Select the image directory** from the backup drive as SOURCE
3. Select the laptop's internal disk as DESTINATION
4. **Verify the target disk twice** — this overwrites everything on it
5. Restore, then remove the USB and reboot

Restoring is the only operation that can destroy a laptop. Confirm the disk
model, size, and that no backup drive is selected as the destination.

---

## Troubleshooting

### Rescuezilla refuses to restore — image larger than the target disk

`[PROVEN]` — Rescuezilla will not restore an image whose partition layout does
not fit the destination. This happens whenever the image was taken from a
physically larger laptop than the one being restored to.

The fix is to shrink the cloned partition so it fits, using GParted, which ships
alongside Rescuezilla on the same flash drive. Shrink the image on the backup
drive, then re-attempt the restore.

**The part that throws you:** Omarchy's root partition is encrypted, so GParted
cannot read or resize it until the container is unlocked. Select the encrypted
partition and use its **gear (key) icon** to unlock it. The passphrase is **the
Omarchy login password from the machine the image was taken from** — not a
separate disk password.

```
Image:  512 GB laptop  ->  Target:  256 GB laptop   => refuses to restore
                                                     => shrink in GParted first
```

Full procedure in `reference.md` under "Shrinking an image to fit".

### "Disk not found" or destination not writable in Rescuezilla

- **exFAT on very old Rescuezilla builds** — check the version; older releases
  lack exFAT write support. exFAT is kernel-native in Linux, so this only
  affects genuinely old Rescuezilla.
- **Drive not unmounted on the host** — boot Rescuezilla from USB while the
  external drive is still mounted in the running OS can cause conflicts.
  Unmount before rebooting into Rescuezilla.
- **USB port speed** — USB2 works, just slowly. Not a failure.

### Writes fail intermittently on a backup drive

Check spin-up counters on the *host* before suspecting the media:

```bash
sudo smartctl -A -d sat /dev/disk/by-id/ata-<model>_<serial> \
  | grep -E 'Power_On_Hours|Start_Stop_Count|Power_Cycle_Count'
```

High `Start_Stop_Count` relative to `Power_On_Hours` means power is being cut
to a spinning disk — an enclosure or host-suspend problem, not a failing drive.
Symptom is a filesystem found dirty at every boot.

### A backup directory is missing after a crash

`[PROVEN]` fsck on FAT32 dropped an unrecoverable corrupted directory rather
than restoring it. On exFAT this is far less likely, but not impossible — which
is the argument for two copies rather than one.

**Check the second drive first.** If it holds the directory, copy it back. If
neither has it, the only recourse is re-imaging from the source laptop.

### SMART self-tests abort on the drive

Some USB-SATA bridges reset the disk on any ATA passthrough, making offline
self-tests impossible to run *and* observe. Use a full-surface read instead —
see `linux-disk-diagnostics`.

---

## Habits that prevent problems

- **Eject cleanly.** `sync` then unmount. Pulling a spinning disk is what makes
  filesystems dirty.
- **Sync to drive 2 immediately** after each backup.
- **Verify after every migration or format**, not just after copies.
- **Label drives distinctly.**
- **Keep a third copy off-site.** Two drives in the same drawer protect against
  accidental deletion, not against theft or fire.

## Reference

`reference.md` — image-set anatomy, layout conventions, restore checklist, and
the full session timeline.
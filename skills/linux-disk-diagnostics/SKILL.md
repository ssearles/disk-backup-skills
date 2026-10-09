---
name: linux-disk-diagnostics
description: >
  Diagnose and safely repair external USB hard drives on Linux/Omarchy: disks
  that mount read-only or not at all, FAT32 corruption and "volume was not
  properly unmounted", SMART self-tests that abort, verifying disk surface
  health, repartitioning and reformatting without destroying the wrong drive,
  and copying backup images between disks. Triggers: external drive not
  mounting, disk mounted read-only, USB hard drive disappeared, FAT32 dirty,
  fsck on external drive, corrupted directory, smartctl self-test aborted,
  test hard drive for bad sectors, check if disk is dying, reformat external
  drive to exfat or NTFS, disk and destination, copy backups between disks,
  verify a copy, rsync between external drives, device busy when running
  mkfs, udisks mounted the partition automatically, dual boot data disk that
  Windows and Linux both read. Excludes ZFS/Btrfs pool repair and LVM.
---

# Linux Disk Diagnostics

Field-tested on Omarchy (Arch/Hyprland) with 2.5" USB-attached drives behind
JMicron SATA bridges. Procedures are general to Linux on any distro; only
package names and mount paths are Omarchy-specific.

**Confidence markers used throughout:**
- `[PROVEN]` — directly observed and diagnosed on real hardware
- `[INFERRED]` — conclusion reached from output, not isolated in a controlled test

---

## Rule 0 — never touch a disk by device letter

`/dev/sdX` letters **change between reboots and even between hotplugs.** In the
session this came from, the same physical disk was `sdc` at the start of the
day and `sdd` by evening. Typing the wrong letter wipes the wrong drive.

Always resolve by serial number:

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,MOUNTPOINT
```

Then use the by-id path, which contains the serial:

```bash
/dev/disk/by-id/ata-TOSHIBA_MQ04ABD200_18N8P0BKT
/dev/disk/by-id/ata-TOSHIBA_MQ04ABD200_18N8P0BKT-part1
```

Embed the expected serial in any script and abort on mismatch. Two guards are
better than one: check the serial, **and** check that the disk does *not*
already contain the filesystem UUID you are trying to protect.

```bash
real=$(lsblk -ndo SERIAL /dev/disk/by-id/ata-<model>_<serial> | tr -d ' ')
[ "$real" = "EXPECTED_SERIAL" ] || { echo "ABORT: wrong disk"; exit 1; }
```

**Beware `dirname` on by-id paths.** They are flat symlinks with no `/` before
the filename, so `dirname` returns the containing *directory* and `lsblk`
returns empty:

```bash
# WRONG - returns /dev/disk/by-id, lsblk gives empty serial
lsblk -ndo SERIAL "$(dirname "$DEV" | sed 's/-part1$//')"

# RIGHT
lsblk -ndo SERIAL "${DEV%-part1}"
```

---

## Read-only mounts

### Distinguish the mechanism before acting

Three different causes, three different fixes. Check each:

```bash
lsblk -o NAME,RO,RM,STATE /dev/sdX
udisksctl info -b /dev/sdX | grep ReadOnly
dmesg | grep -iE 'fat|ext4|read-only|remount' | tail -20
```

| Kernel log | Meaning | Fix |
|---|---|---|
| `Filesystem has been set read-only` | Driver hit corruption and refused writes | `fsck` first |
| `Read-only file system` after I/O errors | Hardware/transport failure | Stop, surface test |
| `RO 1` in `lsblk`, no kernel message | Genuinely write-protected (hardware lock switch) | Check the lock |
| `udev` shows `ID_FS_RW` absent | No signal — attribute often simply not emitted | Ignore it |

`[PROVEN]` In the source session the initial hypothesis was "udisks2 mounted it
read-only by policy because the volume was dirty." The journal showed the
**kernel vfat driver** set it read-only itself after logging
`error, corrupted directory`. Same conclusion, wrong mechanism — and the
policy explanation would have led to skipping the `fsck` that actually fixed it.

### Repair

```bash
udisksctl unmount -b /dev/sdX1          # no root needed
sudo fsck.vfat -a /dev/sdX1
udisksctl mount -b /dev/sdX1
```

`fsck` writes `FSCK0000.REC` recording what it changed. Harmless, deletable.

**Do not force `mount -o remount,rw`** on a filesystem the kernel flagged as
having corrupt structures. You risk writing into damaged metadata.

---

## Verifying disk health

### SMART: read it, but know the limits

```bash
sudo smartctl -a -d sat /dev/disk/by-id/ata-<model>_<serial>
```

Key attributes — all should be 0 on a healthy disk:

| Attribute | Why it matters |
|---|---|
| `Reallocated_Sector_Ct` | Sectors remapped because they failed |
| `Current_Pending_Sector` | Sectors awaiting remap |
| `Offline_Uncorrectable` | Sectors that could not be read |
| `Reported_Uncorrect` | Reads that failed and were reported to the host |
| `End-to-End_Error` | Integrity failures in transit |
| `UDMA_CRC_Error_Count` | Cable/bridge signalling errors |

Two counters that look alarming but usually aren't:

- `Power-Off_Retract_Count` with a value like `317827579978` — meaningless on
  many Toshiba drives.
- `G-Sense_Error_Rate` high — accumulated shock count. Not damage, but the disk
  gets yanked while spinning. Handle it carefully.
- `Runtime_Bad_Block` — ambiguous; often a factory baseline. Judge it by
  whether `Reallocated_Sector_Ct` is nonzero, not by the number itself.

### Self-tests abort on cheap USB bridges

`[PROVEN]` A JMicron bridge enumerating as **UAS** aborted every extended
self-test. Decoding the self-test status byte makes the cause unambiguous:

```
Self-test execution status: (  25)  The self-test routine was aborted by the host.
```

`0x19` = `0b00011001`:
- bits 7–5 = `000` → completed
- **bit 4 = `1` → aborted by host**
- bits 3–0 = `1001` → 90% remaining

Identify the transport:

```bash
lsusb -t                      # if available
dmesg | grep -E 'uas|usb-storage'
ls -l /sys/block/sdX/device/    # ../driver symlink
```

If a self-test aborts with `aborted by the host` and high percentage
remaining, the bridge resets the disk on any ATA passthrough command.
**This makes the test impossible to run and observe**, because checking on it
is what kills it. Use the surface scan instead.

### Surface scan — the robust alternative

Read every sector directly. No ATA passthrough, so nothing can abort it, and
progress can be watched safely.

```bash
sudo dd if=/dev/disk/by-id/ata-<model>_<serial> of=/dev/null \
     bs=4M iflag=direct conv=noerror,sync status=progress 2>scan.log
```

- `conv=noerror` — continue past a bad sector instead of stopping, so one
  defect does not mask the rest.
- `conv=sync` — pad short reads.
- Read-only. Nothing is written.

Verify coverage:

```bash
grep -c 'Input/output error' scan.log   # expect 0
tr '\r' '\n' < scan.log | grep -vE 'bytes \(' | grep -v '^$'
```

Expect `476932+1 records in` for a 2 TB disk at `bs=4M`. The `+1` is the final
partial block, not a fault.

Time it: 2 TB at ~135 MB/s is ~4.3 h. Check real throughput before trusting
an estimate:

```bash
r=$(awk '{print $3}' /sys/block/sdX/stat); sleep 3
r2=$(awk '{print $3}' /sys/block/sdX/stat)
echo "$(( (r2-r)*512/3/1048576 )) MB/s"
```

**Limitation:** a plain read carries no checksum. Silent corruption returns
data without an I/O error and will pass. This test proves *readability*, not
*correctness*.

---

## Repartitioning and formatting

### The udisks2 auto-mount trap

`[PROVEN]` `partprobe` makes the kernel re-read the partition table, and
**udisks2 immediately auto-mounts the new partition.** `mkfs` then fails:

```
open failed : /dev/...-part1, Device or resource busy
```

Fix: unmount **after** `partprobe`, not before.

```bash
sudo parted -s "$DEV" mklabel gpt
sudo parted -s -a optimal "$DEV" mkpart primary 1MiB 100%
sudo partprobe "$DEV"; sudo udevadm settle; sleep 3
sudo umount "${DEV}-part1" 2>/dev/null      # <-- required
sudo mkfs.exfat -n LABEL -c 32M "${DEV}-part1"
```

Also unmount beforehand — that alone is not enough.

### Check exit codes and verify the result

`[PROVEN]` A script using `set -uo pipefail` **without `-e`** printed
"Phase 1 done" over a failed `mkfs`. Never report success without asserting it:

```bash
set -euo pipefail
actual_fs=$(lsblk -ndo FSTYPE "${DEV}-part1" | tr -d ' ')
[ "$actual_fs" = "exfat" ] || { echo "ABORT: got '$actual_fs'"; exit 1; }
```

`mkfs.exfat` printing `Partition table: none` while probing is **normal**, not
an error.

---

## Choosing a filesystem for cross-platform backup media

For a disk that must be written from Linux and read from Windows:

| Format | Use when | Avoid when |
|---|---|---|
| **exFAT** | Backup images, Linux + Windows access | You need Unix permissions |
| **NTFS** | General storage, Windows-first | Linux and Windows both write it (see below) |
| **ext4 / btrfs** | Linux-only | Windows must read it |

**exFAT for backup media specifically**, because:

- **NTFS has a Windows trap.** Windows *Fast Startup* (`hiberboot`) leaves NTFS
  volumes marked dirty on hibernation. Linux then mounts them **read-only** —
  the same symptom as corruption. Disable Fast Startup, or use exFAT.
- **FAT32 has a 4 GB file-size limit.** Rescuezilla splits are 2 GB by default
  so it often goes unnoticed, but a 3.73 GB part is uncomfortably close.
- **FAT32 directory corruption is the failure mode this skill exists to
  prevent.** Its directory tables are fragile under abrupt power loss.

`-c 32M` sets a 32 MB cluster size — appropriate for multi-GB image files and
meaningfully faster than exFAT's 128 KB default when writing them.

**exFAT has no permissions model.** Leave "Preserve permissions/owner/group"
off in any GUI sync tool or rsync will emit errors for every file.

### Check for conversion problems before formatting

```bash
find "$SRC" -type f -size +4G              # exceeds FAT32 limit
find "$SRC" | awk '{ if (length($0) > 200) print length($0), $0 }'
find "$SRC" 2>/dev/null | grep -nE '[<>:"|?*\\]'
find "$SRC" ! -type f ! -type d            # symlinks, sockets, devices
```

For case-insensitive filesystems, check for collisions **within each
directory** — identical names in different directories are fine:

```bash
find "$SRC" -type d | awk -F/ '{print tolower($NF)"\t"$0}' | sort \
  | awk -F'\t' '{c[$1]++; p[$1]=p[$1]" || "$2} END {for (k in c) if (c[k]>1) print c[k], k, p[k]}'
```

---

## Copying between disks

### rsync trailing slash decides the layout

`[PROVEN]` This is the single most common footgun:

| Source path | Result |
|---|---|
| `/mnt/BACKUPS-2` | Creates a **`BACKUPS-2/` wrapper folder** in the destination |
| `/mnt/BACKUPS-2/` | Copies the **contents**, no wrapper |

The wrapper appears because Grsync and other GUIs fill in the path without a
trailing slash, and rsync reads that as "copy this directory." Note the folder
is not invented — it reproduces the source's own name, which for a mount point
equals the volume label.

**In a GUI file manager there is no way to express "the contents of" other than
typing the trailing slash yourself.** Type the path; don't use the picker.

### Move vs copy across filesystems

`[PROVEN]` `mv` between two *mount points on different physical disks* falls
back to copy-then-delete. It is **not** an instant rename, even though both
paths may report the same `st_dev`-like appearance if compared naively. Check
they are genuinely the same filesystem before assuming.

### Never interrupt a copy-and-delete

`[PROVEN]` Interrupting `rsync --remove-source-files` or a cross-device `mv`
leaves **duplicates** — some files copied to the destination with originals
not yet removed. This looks alarming but is recoverable:

```bash
# Count unique relative paths across both locations vs the source
{ find "$A" -type f | sed "s|$A/||"; find "$B" -type f | sed "s|$B/||"; } | sort -u | wc -l
```

If the union equals the source file count, nothing is lost. Recover by wiping
the half-finished destination and re-running cleanly.

**Put long transfers in the background with `nohup` and a log**, so a tool
timeout cannot kill them partway:

```bash
nohup /path/to/copy.sh > /tmp/copy.log 2>&1 &
```

---

## Verifying a copy

### Sort both sides before diffing

`[PROVEN]` A false "MISMATCH" report is easy to produce. Parallel `xargs`
emits results in **completion order**, so identical hashes appear in different
order and `diff` flags every file as changed.

```bash
( cd "$SRC" && find . -type f -print0 | xargs -0 -P 4 sha256sum | sort ) > src.sums
( cd "$DST" && find . -type f -print0 | xargs -0 -P 4 sha256sum | sort ) > dst.sums
diff -q src.sums dst.sums && echo IDENTICAL
```

`[INFERRED]` The reordering is the established behaviour of parallel `xargs`
output; it was not isolated in a controlled test. The **practical** guidance —
always sort before diffing — is safe regardless.

### Do not parallelise across one USB bus

`[INFERRED]` Running `xargs -P 4` made a 30-minute verification take ~6 hours.
Four processes contending for one USB controller appears to be the cause, but
this was not benchmarked. **Use one process at a time** and expect ~117 GB in
~30 minutes at 135 MB/s. Sorting two files of checksums is trivial CPU work.

Compare sequential timing before blaming the hardware:

```bash
python3 -c "print(f'{118*1024**3/135e6/60:.0f} min at 135 MB/s')"
```

### Log progress so it is observable

Buffering tools (`sort`) write nothing until they finish. Append per-file
instead, and let the watcher exit with the job:

```bash
tail --pid=$(pgrep -f verify.sh | head -1) -f verify-progress.log
```

`tail -f` alone never exits and looks hung after completion. `tail --pid` does.

---

## Preventing recurrence

- **Unmount before unplugging.** `sync` then unmount. Pulling a spinning disk
  is what creates dirty filesystems.
- **Check spin-up counters.** High `Start_Stop_Count` relative to
  `Power_On_Hours` means power is being cut while the disk spins — an enclosure
  or suspend problem, not a platters problem.
- **Keep two copies.** One drive cannot protect against one drive. Then keep a
  third off-site: one location does not survive theft or fire.

## Reference

`reference.md` — command cookbook, error-message decoder, and the full worked
timeline from the session this skill came from.
# Reference — Rescuezilla Backup Workflow

Companion to `SKILL.md`. Image-set anatomy, conventions, restore checklist, and
the session timeline.

---

## Image-set anatomy

A Rescuezilla save is a directory of split image parts plus metadata:

```
2026-10-08-1701-img-rescuezilla/
├── sda2.dd-ptcl-img.gz.aa      <- split parts, .aa .ab .ac ... sequentially
├── sda2.dd-ptcl-img.gz.ab
├── sda2.dd-ptcl-img.gz.ac
├── …                           <- .dd = raw/partition-table-clone
├── sda1.vfat-ptcl-img.gz.aa    <- separate partition imaged separately
├── sda-mbr                     <- partition table / boot record
├── sda-pt.sf, sda-pt.parted    <- partition descriptions
├── sda-chs.sf                  <- CHS geometry (for very old BIOSes)
├── sda-hidden-data-after-mbr   <- gap between MBR and first partition
├── sda-gpt.*                   <- GPT artefacts, if applicable
├── efi-nvram.dat               <- EFI variables, when relevant
├── disk                        <- list of which partitions are included
├── parts                       <- partition list for restore
├── Info-img-id.txt             <- unique image identifier
├── Info-smart.txt              <- SMART dump taken at backup time
├── Info-dmi.txt                <- motherboard/BIOS
├── Info-lshw.txt, Info-lspci.txt
├── Info-packages.txt           <- package list (only if imaging unpartitioned)
├── Info-OS-prober.txt
├── blkdev.list, blkid.list, dev-fs.list
├── clonezilla-img              <- format marker
├── rescuezilla.description.txt <- user-entered notes
└── blkid.list, clonezilla-img
```

### Extensions

| Pattern | Meaning |
|---|---|
| `.dd-ptcl-img.gz.*` | Partition-table-aware raw clone of a partition |
| `.vfat-ptcl-img.gz.*` | FAT partition image |
| `.ext4-ptcl-img.gz.*` | ext4 partition image |
| `sda-mbr`, `sdb-mbr` | Master boot record — needed for boot |
| `efi-nvram.dat` | EFI variables — needed for some Windows/Linux dual boots |
| `sda-gpt.*` | GPT header/table backup |

**Keep the non-image files.** A set of `.gz.aa` parts without `sda-mbr` and
`Info-smart.txt` may not restore cleanly.

### Split size

2 GB by default, which is why FAT32's 4 GB limit was survivable — but the
largest observed part was 3.73 GB, uncomfortably close. On exFAT there is no
limit.

---

## Directory naming convention

```
<machine>_<diskhalf>/<timestamp>-img-rescuezilla/
```

Examples:

```
LenovoT440p_boot/        Lenovo_T420_caddy/
HP-Pav(new)-15-ab243cl_boot/    HP Pavilion 15-p043cl_boot/
```

Observed inconsistency worth avoiding going forward: the same laptop appears
as `LenovoT440p` and `Lenovo_T420` — underscore used both to join machine and
disk half *and* inside machine names. Pick one separator and apply it
consistently, e.g. `Lenovo_T440p_boot`.

Machine names containing parentheses are fine on exFAT and NTFS. Avoid on
FAT32-era tooling and in shell scripts without quoting.

---

## Restore checklist

Restoring is the only operation that destroys a laptop. Walk this in order.

```
1. Image directory on the backup drive     -> SOURCE
2. Target laptop's internal disk           -> DESTINATION
3. Confirm destination is the internal disk
     - NOT the backup drive
     - check model name and size twice
4. Confirm no USB drive is selected as destination
5. Confirm the image FITS the destination
     - Rescuezilla refuses to restore an image
       larger than the target disk
     - if it refuses, see "Resizing partitions
       when the disks differ in size"
6. Restore
7. Remove USB stick
8. Reboot, confirm the laptop boots
9. If the image was SMALLER than the disk,
   grow the partition to fill it
     - GParted, gear icon, same login password
10. Sanitize inherited identity if it was a clone
     -> ssearles/cloned-machine-identity
```

Rescuezilla overwrites the entire destination disk. There is no undo.

---

## Resizing partitions when the disks differ in size

`[PROVEN]` — required whenever the image was taken from a disk of a different
size than the destination. Which direction you need to go depends on which disk
is bigger, and the two cases are not symmetric.

| Case | When | When to resize |
|---|---|---|
| Image **larger** than target | Restoring onto a physically smaller laptop | **Before** the restore — Rescuezilla refuses otherwise |
| Image **smaller** than target | Restoring onto a larger laptop | **After** the restore — the partition just sits unused |

GParted is included on the Rescuezilla flash drive, so no separate download is
needed.

```
512 GB image -> 256 GB laptop   Rescuezilla REFUSES  -> shrink first
256 GB image -> 512 GB laptop   restores fine       -> grow afterwards (optional)
```

### Why GParted appears to hang

Omarchy encrypts the root partition with LUKS. GParted cannot read or resize an
encrypted container until it is unlocked, and it does not prompt for the
passphrase on its own — it waits for you to ask.

The layout on a restored Omarchy machine looks like this:

```
/dev/sda1   vfat          /boot          unencrypted
/dev/sda2   crypto_LUKS   -> btrfs       encrypted   <-- the one to resize
```

### The passphrase

Select the encrypted partition and click its **gear (key) icon**. The passphrase
is **the Omarchy login password from the original machine** — the user whose
image this is, not a separate disk or encryption password.

The gear icon is easy to miss because it sits on the partition row rather than
in a menu. If GParted will not let you resize a partition, the container is
still locked — this is almost always why, and almost never a fault with the
disk.

### Shrinking, before the restore

1. Boot the target laptop from the Rescuezilla USB
2. Open **GParted** from the desktop
3. Select the target disk, then select the **encrypted partition**
4. Click its **gear (key) icon** and enter the passphrase
5. Resize it down until the layout fits the destination disk
6. Apply, then return to Rescuezilla and start the restore

### Growing, after the restore

Once Rescuezilla has finished and the machine boots, the partition is whatever
size the image carried — smaller than the disk around it. Reopen GParted on the
restored system and grow it to fill:

1. Boot the restored Omarchy system normally
2. Open **GParted**
3. Select the internal disk and the **encrypted partition**
4. **Gear (key) icon again**, same login password
5. Drag the right edge out to the end of the disk
6. Apply

Growing is the safer of the two operations — nothing is moved off the end of the
filesystem, so there is no data to lose. Doing it after the restore rather than
before means you never shrink a partition you are not certain about.

### How small is safe

`[PROVEN]` — both Rescuezilla and GParted display a disclaimer that not all
resizes will succeed. The warning is accurate and gives no usable rule.

The rule that worked in practice: **stay above the size of the coloured band**
representing the installed partition in the GParted disk graphic. Dragging the
partition edge below that band is what turns a routine resize into a failed
one; staying above it worked every time.

```
GParted disk graphic

  [====== LUKS/btrfs ======][------ free ------]
  ^^^^^ the coloured band    ^^^^^ do not shrink past this

  safe:     [=====================]
  too small: [=====]            <-- below the band, fails
```

The band is a proxy for the filesystem's actual minimum. Staying above it
leaves GParted enough room to move the end of the filesystem without running
out, which is what the resize operation is actually trying to do.

### Shrinking the container, not necessarily the filesystem

`[INFERRED]` — it should be enough to resize the **LUKS container** and leave
the btrfs filesystem inside it at its current size. btrfs will simply stop using
the tail of the partition, and growing back later is easier than shrinking btrfs
offline. Shrinking btrfs itself is possible but is a more delicate operation
than resizing the outer container, and is not necessary just to make an image
fit.

Confirm what GParted actually resized before leaving — the partition row should
show a new device size after the operation completes.

### After any restore: sanitize the identity

If the restore was a **clone** of another machine rather than a fresh install,
the machine carries the source machine's hostname, machine-id, and journal.
That is a separate problem with its own fix — see
[`cloned-machine-identity`](https://github.com/ssearles/cloned-machine-identity).

---

## Layout conventions

| | |
|---|---|
| Drive 1 label | `BACKUPS` |
| Drive 2 label | `BACKUPS-2` |
| Filesystem | exFAT, 32 MB clusters |
| Partition | one, spanning the whole disk, GPT |
| Top level | one directory per machine/disk-half |

No separate EFI, swap, or recovery partitions — this is data media.

---

## Drive capacity planning

Observed usage across six laptops: ~118 GB of 2 TB (~7%).

Rough planning at ~40 GB per full laptop image set:

| Machines | Est. need | Headroom on 2 TB |
|---|---|---|
| 6 | ~118 GB observed | comfortable |
| 12 | ~240 GB | comfortable |
| 25 | ~500 GB | comfortable |
| 50 | ~1 TB | tight |

Growth is not linear — image sets are full-disk clones, so a reinstalled
laptop uses the same space regardless of how much data it holds. Plan for
re-images, not for data growth.

---

## Session timeline — six-laptop backup build

Setup: Omarchy on `lenovot440p`, two 2 TB external drives, Rescuezilla for
per-machine images.

**Starting point.** Drive 1 was FAT32, mounted read-only every boot. One
backup directory (`HP-Pav(new)-15-ab243cl_caddy`) was lost and unrecoverable.
Full diagnostics in `linux-disk-diagnostics`.

**Health verification.** Toshiba 2 TB passed a full-surface read: 100%
coverage, zero read errors, 4.83 h at 115 MB/s. SMART error counters all zero.

**Filesystem decision.** exFAT chosen over NTFS because Windows Fast Startup
leaves NTFS dirty and Linux then mounts it read-only — the same symptom as
corruption. Over FAT32 because of the 4 GB limit and directory fragility.

**Second drive.** New Seagate formatted exFAT, GPT, 32 MB clusters, label
`BACKUPS-2`.

**First copy.** 118 GB in ~15 min at 135 MB/s. A USB port swap took the
enclosure from 480 to 5000 Mbit/s — it had always been USB3-capable.

**Verification.** SHA256 both sides. The first attempt falsely reported
mismatches because parallel `xargs` reordered output and `diff` was applied
unsorted. Sorted comparison: 144/144 identical, 29 minutes.

**Obstacle.** The first verification took ~6 hours rather than 30 minutes.
`-P 4` was the cause; sequential completed in 29.

**Format and refill.** Original Toshiba reformatted exFAT (`BACKUPS`). Grsync
copy produced a `BACKUPS-2` wrapper folder because the source path lacked a
trailing slash. Corrected with a trailing-slash source.

**Second move.** Repairing that nesting used `rsync --remove-source-files`, and
a tool timeout killed it partway, leaving duplicates. Recoverable: the union
across both locations still covered all 144 files. Wiped and redone with a
backgrounded copy.

**Final state.** Two exFAT drives, 144 files each, 126,667,273,629 bytes each,
identical structure. Grsync configured with trailing-slash source.

**Still outstanding.** `HP-Pav(new)-15-ab243cl_caddy` was lost in the original
FAT32 corruption and never re-imaged. Its `_boot` partner is intact. Requires
booting that laptop and running Rescuezilla again.

### Failure modes worth remembering

| Symptom | Cause |
|---|---|
| Extra folder level after GUI copy | Source path missing trailing slash |
| Files appear twice | Copy/delete interrupted partway |
| `Device or resource busy` on mkfs | udisks2 auto-mounted after `partprobe` |
| "MISMATCH" with identical hashes | Unsorted diff over parallel output |
| Verification 12× slower than expected | `-P N` contending for one USB bus |
| Blank completion screen that won't close | Modal dialog awaiting Close |
| Rescuezilla refuses to restore | Image partition larger than the destination disk |
| GParted won't resize the root partition | LUKS container still locked — use its gear icon |
| Resize fails despite unlocking | Edge dragged below the partition's coloured band |

**Rule that would have prevented most of these:** never put a timeout on a
command the user must not interrupt. Background it with `nohup` and a log.
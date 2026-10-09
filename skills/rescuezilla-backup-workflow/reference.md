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
5. Restore
6. Remove USB stick
7. Reboot, confirm the laptop boots
```

Rescuezilla overwrites the entire destination disk. There is no undo.

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

**Rule that would have prevented most of these:** never put a timeout on a
command the user must not interrupt. Background it with `nohup` and a log.
# Reference — Linux Disk Diagnostics

Companion to `SKILL.md`. Command cookbook, error decoder, and the worked
timeline that produced the guidance.

---

## Error-message decoder

### `Filesystem has been set read-only`

Kernel driver detected corruption and refused further writes. Not a policy
decision, not a hardware lock. `fsck` is the fix.

### `error, corrupted directory (invalid entries)`

The specific structures `fsck` will repair. On FAT32 a single corrupt directory
can lose an entire subdirectory's worth of data.

### `Volume was not properly unmounted. Some data may be corrupt.`

Clean unmount did not happen — power was cut, or the disk was pulled while
spinning. Correlate with `Power_On_Hours` and `Start_Stop_Count`.

### SMART self-test status byte

The ATA self-test execution status byte, decoded. Bits 7–5 are the test state,
bit 4 the "aborted by host" flag, bits 3–0 the remaining percentage.

| Value | Meaning |
|---|---|
| `0xF9` (249) | In progress, 90% remaining — normal just after starting |
| `0x19` (25) | **Aborted by host**, 90% remaining |
| `0x00` | Completed, no error |

`aborted by host` with high percentage remaining means something reset the
drive mid-test. On a cheap UAS bridge, the usual trigger is any ATA passthrough
command — including `smartctl -c`, i.e. **checking on the test is what kills
it.**

### `SMART Status not supported: Incomplete response, ATA output registers missing`

Normal for cheap SAT bridges. The `SMART overall-health self-assessment test
result: PASSED` line beneath it is the real answer.

### `open failed: Device or resource busy` (mkfs)

udisks2 auto-mounted the partition after `partprobe`. Unmount after, not before.

### `GDBus.Error:org.freedesktop.UDisks2.Error.AlreadyMounted`

udisks mounted it automatically. Harmless — the volume is already available at
the stated path.

---

## Command cookbook

### Identity — always start here

```bash
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,UUID,MODEL,SERIAL,TRAN,MOUNTPOINT,RO,RM
ls -l /dev/disk/by-id/ | grep -vE 'usb-|wwn-'
sudo smartctl -i -d sat /dev/disk/by-id/ata-<model>_<serial>
```

### Mount state

```bash
findmnt -S /dev/sdc1 -o SOURCE,TARGET,FSTYPE,OPTIONS
udisksctl info -b /dev/sdc1 | grep -E 'ReadOnly|IdLabel|IdType'
```

### Mounted filesystem health (udev attributes)

```bash
udevadm info --query=property --name=/dev/sdc1 | grep -E 'ID_FS|ID_PART_TABLE'
```

### Drive activity without iostat

```bash
r=$(awk '{print $3}' /sys/block/sdX/stat); sleep 3
r2=$(awk '{print $3}' /sys/block/sdX/stat)
echo "$(( (r2-r)*512/3/1048576 )) MB/s read"
```

`/sys/block/sdX/stat` fields: 1=reads completed, 2=reads merged, 3=**sectors
read**, 8=sectors written. Multiply sector counts by 512.

### Who has a device open

```bash
sudo lsof /dev/sdX1
fuser -vm /dev/sdX1
```

### USB link speed and transport

```bash
for d in /sys/bus/usb/devices/*/; do
  p=$(cat $d/product 2>/dev/null)
  [ -n "$p" ] && echo "$(basename $d): $(cat $d/speed) Mbit/s  ver=$(cat $d/version)  '$p'"
done

ls -l /sys/block/sdX/device/../driver   # uas vs usb-storage
```

A USB3 device in a USB3 port enumerates on **both** `usb1` (480) and `usb2`
(5000). Appearing only on `usb1` means the link is running at High-Speed —
caused by the port, the cable, or the enclosure. Try another port before
concluding the enclosure is USB2-only.

### Check filesystem, read-only, while mounted

Never run `fsck` on a mounted filesystem. To check without repairing, unmount
first, then:

```bash
sudo fsck.vfat -n /dev/sdc1    # -n = read-only, report only
```

### Space and comparison before copying

```bash
df -h --output=size,used,avail "$SRC" "$DST"
need=$(du -sb "$SRC" | cut -f1)
avail=$(df -B1 --output=avail "$DST" | tail -1 | tr -d ' ')
[ "$avail" -gt "$need" ] && echo "space OK"
```

### Time a transfer

```bash
python3 -c "
gb, rate = 118, 135e6
print(f'{gb*1024**3/rate/60:.0f} min at {rate/1e6:.0f} MB/s')"
```

---

## Filesystem summary for backup media

| | FAT32 | exFAT | NTFS | ext4 |
|---|---|---|---|---|
| Windows read | ✅ | ✅ | ✅ | ❌ needs tools |
| Windows write | ✅ | ✅ | ✅ | ❌ |
| Linux read/write | ✅ | ✅ | ⚠️ see below | ✅ |
| Max file size | **4 GB** | none | none | none |
| Unix permissions | ❌ | ❌ | ⚠️ | ✅ |
| Journal | ❌ | ❌ | ✅ | ✅ |
| Journals/directory fragility | **poor** | moderate | good | good |

**NTFS on Linux:** kernel-native `ntfs3` (since 5.9) is good, and
`ntfs-3g` is a fallback. The trap is Windows Fast Startup leaving the volume
dirty — Linux then mounts it read-only.

Confirm driver availability:

```bash
grep -wE 'ntfs3|exfat|ext4|btrfs' /proc/filesystems
modinfo exfat ntfs3 2>/dev/null | grep -E 'filename|^$'
which mkfs.exfat fsck.exfat
```

---

## Filesystem migration checklist

Before wiping a disk that holds backups:

1. **Confirm the copy verified** — SHA256 both sides, sorted diff
2. **Check conversion hazards** — >4 GB files, path length, illegal characters,
   case collisions, symlinks
3. **Unmount cleanly** — `sync && udisksctl unmount -b /dev/sdX1`
4. **Zero the first 200 MB** — destroys stale superblocks:
   `sudo dd if=/dev/zero of="$DEV" bs=1M count=200 conv=fsync status=none`
5. **Partition** — `parted -s mklabel gpt` then `mkpart primary 1MiB 100%`
6. **`partprobe`, `udevadm settle`, sleep, THEN unmount**
7. **Format** — `mkfs.exfat -n LABEL -c 32M "${DEV}-part1"`
8. **Assert the result** — never trust the command's silence
9. **Copy back, verify again**

---

## Worked timeline — 2 TB Toshiba, read-only mount

Session source: Omarchy on `lenovot440p`, kernel 7.2.5, smartmontools 7.5.

**Symptom.** Disk mounted read-only every boot. `ls` on one subdirectory
returned `Input/output error`. Other directories read cleanly.

**Root cause chain.** Kernel logged `Volume was not properly unmounted`, then
`error, corrupted directory (invalid entries)`, then `Filesystem has been set
read-only`. The third line is the mechanism. Not hardware write-protected:
`lsblk` showed `RO 0` and udisks `ReadOnly: false`.

**Why the volume kept going dirty.** `Power_On_Hours: 1841` with
`Start_Stop_Count: 7960` — 4.3 spin-ups per runtime hour. A USB-SATA bridge
power-cycling when the host suspends. Enclosure problem, not platters.

**Repair.** `fsck.vfat -a`, remount, 200 MB write/read/md5 round-trip. Verified.

**Outstanding task.** Extended SMART self-test, deferred — the drive had last
been fully checked at hour 67 and was now past 1841.

**Obstacle.** SMART self-test aborted three times. Diagnosed from the status
byte (`0x19`, aborted by host, 90% remaining) plus the journal showing each
abort immediately followed a `smartctl` query. Bridge was UAS
(`scsi host3: uas`, `JMicron Tech 1201`). Ruled out autosuspend
(`runtime_suspended_time: 0`) and USB disconnects (no kernel log entries).

**Resolution.** Full-surface `dd` read, 100% coverage, **zero read errors** in
4.83 h at 115 MB/s. Confirmed healthy alongside all-zero SMART error counters.

**Migration.** New 2 TB Seagate formatted exFAT (`BACKUPS-2`), copied, verified
144/144 files by SHA256. Original Toshiba reformatted exFAT (`BACKUPS`), refilled.

**Final state.** Two exFAT disks, identical 144-file sets,
126,667,273,629 bytes each. Grsync configured with the trailing-slash source.

**Still outstanding.** `HP-Pav(new)-15-ab243cl_caddy` was lost to the original
corruption and never re-imaged. Its partner `HP-Pav(new)-15-ab243cl_boot` is
intact. Requires re-imaging from that laptop.

### What the session cost

Time lost to self-inflicted problems, recorded so the next one avoids them:

- `dirname` on a by-id path → empty serial → guard aborted correctly but
  uselessly
- `xargs -P 4` for verification → 30 min became 6 h; also produced the false
  MISMATCH from unsorted diff
- `set -uo pipefail` without `-e` → success message printed over a failed `mkfs`
- tool timeouts killing a cross-device `mv` mid-flight → duplicate files
- unverified assumptions stated as fact (the trailing-slash claim was backwards
  at one point; "same filesystem, instant rename" was wrong across two disks)

**Rule that would have prevented most of it:** never put a timeout on a command
the user must not interrupt. Run it in the background with `nohup` and a log.
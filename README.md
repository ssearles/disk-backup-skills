# Disk & Backup Skills for AI Coding Agents

Two [agent skills](https://github.com/anthropics/skills) covering external-disk
diagnostics and a Rescuezilla backup workflow, written on Omarchy (Arch/Hyprland)
from a real troubleshooting session.

They came out of fixing a genuine problem: a 2 TB backup disk that mounted
read-only at every boot after a power cut, losing one backup directory. The
disk turned out to be perfectly healthy — the filesystem format was the
problem.

## Skills

### `linux-disk-diagnostics`

Diagnosing and safely repairing external USB drives.

- Read-only mount triage — three different causes, three different fixes
- SMART interpretation, including why offline self-tests abort on cheap USB
  bridges and what to use instead
- Full-surface verification with `dd`
- Safe repartitioning and reformatting
- Filesystem selection for drives shared between Linux and Windows
- Verifying copies without producing false mismatches

### `rescuezilla-backup-workflow`

Running multi-machine disk-image backups.

- Media and filesystem choice
- Drive setup, labelling, identification
- Copying image sets between disks
- Keeping two independent copies in sync with Grsync
- Restoring an image
- Troubleshooting backup-target failures

## Why these exist

The session that produced these cost roughly twelve hours, and most of it went
to traps that aren't documented anywhere:

| Trap | Consequence |
|---|---|
| Disk letters change between reboots | Risk of wiping the wrong drive |
| `partprobe` makes udisks2 auto-mount | `mkfs` fails with `Device or resource busy` |
| A GUI sync tool omits the trailing slash | Creates a spurious wrapper folder |
| Parallel `xargs` reorders checksum output | False "MISMATCH" reports |
| `xargs -P 4` over one USB bus | 30-minute job takes 6 hours |
| Interrupting a copy-and-delete | Leaves duplicate files |
| Cheap UAS bridges abort SMART self-tests | Test can't be run *or* observed |
| Image larger than the target disk | Rescuezilla refuses to restore until the partition is shrunk |
| Omarchy root is LUKS-encrypted | GParted cannot resize it until unlocked with the original login password |

Each is documented with the evidence that identified it.

## Installation

```bash
git clone https://github.com/ssearles/disk-backup-skills.git
cp -r disk-backup-skills/skills/* ~/.agents/skills/
```

Skills live in `~/.agents/skills/`. Each is a folder containing a `SKILL.md`
with YAML frontmatter — the `description` field determines when an agent loads
it, so it is written as trigger vocabulary.

If you use Omarchy, `~/.config/hypr/` and `~/.config/omarchy/` can be
git-version-controlled too, so config changes survive a reinstall.

## Confidence markers

Claims are tagged throughout:

- **`[PROVEN]`** — directly observed and diagnosed on real hardware
- **`[INFERRED]`** — concluded from output, not isolated in a controlled test

The distinction matters: some guidance is established by measurement, some is
reasoned from symptoms. Treat them accordingly.

## Requirements

Linux with `smartmontools`, `util-linux` (`badblocks`), `exfatprogs`,
`e2fsprogs`, `parted`. `grsync` for the GUI sync workflow. `rsync` throughout.

Verified on Omarchy with kernel 6.x and smartmontools 7.5, with 2.5" 5400 rpm
drives behind JMicron USB-SATA bridges.

## Related

Restoring an image leaves the machine carrying the source machine's
machine-id, hostname, and journal. That is a different problem from imaging
one, so it lives in its own repo:
[`cloned-machine-identity`](https://github.com/ssearles/cloned-machine-identity).

## Licence

MIT — use, modify, redistribute freely.
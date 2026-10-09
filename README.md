# Disk & Backup Skills for AI Coding Agents

Three [agent skills](https://github.com/anthropics/skills) covering external-disk
diagnostics, a Rescuezilla backup workflow, and the identity cleanup a restored
image needs — all written on Omarchy (Arch/Hyprland) from real sessions.

The first two came out of fixing a genuine problem: a 2 TB backup disk that
mounted read-only at every boot after a power cut, losing one backup
directory. The disk turned out to be perfectly healthy — the filesystem
format was the problem.

The third came from restoring an image to a laptop and finding it was still
carrying the source machine's hostname, machine-id, and eight days of its
logs.

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

### `cloned-machine-identity`

The cleanup a machine needs after being restored from a disk image.

- Detecting a clone from a stale hostname and inherited journal
- Regenerating a duplicate machine-id
- Fixing a hostname that names the wrong laptop
- Clearing logs carried over from the source machine
- SSH host key checks — when there is nothing to regenerate
- Rolling the fix across a fleet and proving the IDs are distinct

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
| A restored image carries the source machine's identity | Duplicate machine-id, wrong hostname, another laptop's logs |

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

## Licence

MIT — use, modify, redistribute freely.
---
name: cloned-machine-identity
description: >
  De-duplicate a Linux machine that was created from a disk image — Rescuezilla,
  Clonezilla, dd, or a bare-metal restore — and sanitize the identity it
  inherited from the source machine: the machine-id, the hostname, and the
  system journal. Covers diagnosing a cloned machine, regenerating a duplicate
  machine-id, correcting a hostname that names the wrong laptop, clearing
  inherited logs, and rolling the fix across a fleet of restored machines.
  Triggers: cloned machine identity, duplicate machine-id, machine id collision,
  same hostname on two machines, wrong hostname after restore, disk image clone,
  rescuetzilla clone feature, clonezilla restore, restore image to new laptop,
  sanitize restored system, inherited logs from another machine, DHCP collision
  after clone, machine-id duplicate on network, linux host identity after
  imaging, fleet imaging cleanup. Excludes: Windows and macOS product keys and
  activation, BIOS/UEFI firmware settings, disk partitioning and imaging
  mechanics, ZFS/Btrfs pool repair, and Kubernetes node identity.
---

# Cloned Machine Identity

A disk image is a byte-for-byte snapshot of a filesystem. That includes files
nobody thinks of as configuration — the ones that identify *which machine this
is*. Restore one onto different hardware and you get a working system carrying
the source machine's identity.

This is not a theoretical problem. Restoring an image to a laptop is the
intended workflow, and every restore does this.

## Field note

`[PROVEN]` — found on Omarchy (Arch/Hyprland) on an HP Pavilion 15
(i5-6200U, 2016), restored via the Rescuezilla clone feature from an image of
a Lenovo T440p. The restored system booted fine, reported the right hardware
from DMI, and was still calling itself `lenovot440p` with that machine's
machine-id and eight days of its logs. DMI reported the new laptop correctly
— the identity files simply never got revisited, because nothing in a normal
boot process checks them.

The giveaway is that the hostname describes hardware that is not there.

## What a restore actually inherits

| Artifact | Path | Symptom if inherited |
|---|---|---|
| machine-id | `/etc/machine-id` | Duplicate ID across two live machines |
| hostname | `/etc/hostname` | Terminal prompts, mDNS, DHCP leases name the wrong machine |
| journal | `/var/log/journal/` | Logs from another computer, tagged with its hostname |
| D-Bus ID | `/var/lib/dbus/machine-id` | Usually a symlink to the above — follows automatically |

`[PROVEN]` on current systems for the symlink; `[INFERRED]` for the "older
systems kept a separate copy" case, which was not observed here.

Note what is *not* inherited: DMI data (vendor, model, serial) comes from the
motherboard, not the filesystem. That is why the hardware looked correct while
the identity did not.

## Diagnosing before you fix

Check whether the machine is a clone, and from what:

```bash
# Does the hostname name hardware that isn't present?
hostname
cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name

# The machine-id, and how long it has been that value
cat /etc/machine-id
ls -l /etc/machine-id        # date here is often the restore date

# Logs from another machine, tagged with its hostname
journalctl --no-pager -o json | head -200 \
  | python3 -c "import sys,json; print({json.loads(l).get('_HOSTNAME') for l in sys.stdin if l.strip()})"
```

If the journal's oldest entries carry a different hostname than the current one,
the machine is a clone. On the Pavilion that check returned
`{'lenovot440p'}` while `hostname` reported the same value — both pointed at
the source machine, which is what identified it as a restore rather than a
fresh install.

## The fix

`[PROVEN]` — all three steps run to completion on the Pavilion, machine-id
verified changed, journal verified cleared.

Three steps, all needing root:

```bash
# 1. Fresh machine-id. It MUST be removed first -- systemd-machine-id-setup
#    only generates when the file is missing or empty.
sudo rm -f /etc/machine-id
sudo systemd-machine-id-setup

# 2. Correct hostname
sudo hostnamectl set-hostname hp-pavilion-15

# 3. Drop the inherited journal
sudo journalctl --rotate --vacuum-time=1s
```

Reboot afterwards so mDNS, DHCP, and anything else cached picks up the new
name.

`fix-cloned-machine-identity.sh` in this skill's directory wraps all three,
takes the hostname as an argument, and is safe to re-run.

## Verifying

```bash
cat /etc/machine-id     # must differ from the source machine's
hostname                # must describe this machine
journalctl --no-pager | wc -l
grep -rl "$OLD_HOSTNAME" /etc/   # should return nothing
```

Confirm the new machine-id is actually different rather than assuming:

```bash
NEW=$(cat /etc/machine-id)
[[ "$NEW" != "$OLD_MACHINE_ID" ]] && echo "regenerated" || echo "UNCHANGED — still a duplicate"
```

## SSH host keys — check, but usually fine

Duplicated SSH host keys are the most famous clone artifact, because they
produce `REMOTE HOST IDENTIFICATION HAS CHANGED` on every machine that ever
connected to the source. They only exist if `sshd` generated them:

```bash
ls /etc/ssh/ssh_host_*_key.pub 2>/dev/null && \
  for f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$f"; done
```

If that listing is empty, there is nothing to regenerate. Compare fingerprints
against the source machine before regenerating — if they match, regenerate:

```bash
sudo rm -f /etc/ssh/ssh_host_*
sudo systemctl restart sshd
```

On the Pavilion there were no host keys at all, so this was skipped `[PROVEN]`.
Check rather than assume in either direction.

## Caveats

**The journal vacuum is not selective.** `--vacuum-time=1s` removes *all* logs
older than the cutoff, including the restored machine's own history. It cannot
target just the inherited entries. On the Pavilion that took 91,767 entries
down to 1. Acceptable for a fresh restore; not acceptable on a machine whose
current logs you want to keep — archive them first with
`journalctl --export`.

**Inside containers, `/etc/machine-id` is often a read-only bind mount** from
the host. `rm -f` fails there, and running this inside a container is wrong
anyway — the container inherits the host's identity by design. Check with
`findmnt /etc/machine-id` before running.

**In VMs, leave the machine-id alone** unless the VM was cloned in a way that
duplicated it. Most hypervisors assign a fresh ID per guest, and some cloud
images deliberately match an external instance ID.

**`/var/lib/dbus/machine-id`** is a symlink on current systems and follows
`/etc/machine-id` automatically. Older systems kept a separate copy — if
`ls -l` shows a regular file rather than a symlink, regenerate it separately.

**Check `/etc/hosts`.** Most systems carry only `localhost` and need no change,
but images configured with a `127.0.1.1 <hostname>` line need that updated too.

## Rolling it across a fleet

When several machines come from the same source image, the identity problem
repeats per machine and the collisions compound — N machines sharing one ID on
one network. Record the IDs as you go so a future duplicate is detectable:

```bash
for host in laptop-1 laptop-2 laptop-3; do
  ssh "$host" 'sudo ./fix-cloned-machine-identity.sh "$(hostname -s)"'
  ssh "$host" 'printf "%s  %s\n" "$(cat /etc/machine-id)" "$(hostname)"'
done | tee machine-ids.txt
```

Then confirm all IDs are distinct before considering the fleet done:

```bash
awk '{print $1}' machine-ids.txt | sort | uniq -d   # must print nothing
```

The `tee` matters more than it looks. Without a recorded list there is no way
to tell a duplicate from a legitimately unique ID later, and finding out
requires access to every machine at once.

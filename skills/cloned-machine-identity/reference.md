# Reference — Cloned Machine Identity

Supplementary detail for `SKILL.md`. The fix itself is three commands; this
covers why each one is shaped the way it is, and the cases where the shape
does not apply.

## The script

Self-contained, idempotent, takes the target hostname as its only argument.

```bash
#!/usr/bin/env bash
# De-duplicate a machine restored from a disk image (Rescuezilla, Clonezilla, dd).
#
# A restored image carries the source machine's identity: hostname, machine-id,
# and its system journal. On a network with both machines live, the duplicate
# machine-id causes DHCP collisions and ambiguous logs.
#
# Usage:  sudo ./fix-cloned-machine-identity.sh <new-hostname>
# Re-run safely: every step is idempotent.

set -euo pipefail

NEW_HOSTNAME="${1:-}"
if [[ -z "$NEW_HOSTNAME" ]]; then
	echo "usage: sudo $0 <new-hostname>" >&2
	exit 2
fi

OLD_HOST="$(hostname)"
OLD_MACHINE_ID="$(cat /etc/machine-id)"

echo "=== BEFORE ==="
echo "  hostname:   $OLD_HOST"
echo "  machine-id: $OLD_MACHINE_ID"
echo "  journal:    $(journalctl --no-pager 2>/dev/null | wc -l) entries"
echo

# 1. Fresh machine-id. Must be removed (or truncated) before setup will regenerate.
#    Skipping this is the whole point: identical IDs across two live machines cause
#    DHCP lease collisions and make log aggregation ambiguous.
echo "==> Regenerating machine-id"
rm -f /etc/machine-id
systemd-machine-id-setup
echo "    new machine-id: $(cat /etc/machine-id)"

# 2. Correct hostname. Appears in prompts, mDNS/Avahi, DHCP leases, logs.
echo "==> Setting hostname to '$NEW_HOSTNAME'"
hostnamectl set-hostname "$NEW_HOSTNAME"

# 3. Drop the inherited journal. This removes ALL logs older than the cutoff,
#    including this machine's own -- it is not selective about the source machine.
echo "==> Rotating and vacuuming inherited journal"
journalctl --rotate --vacuum-time=1s >/dev/null 2>&1 || true
echo "    journal now: $(journalctl --no-pager 2>/dev/null | wc -l) entries"

echo
echo "=== AFTER ==="
echo "  hostname:   $(hostname)"
echo "  machine-id: $(cat /etc/machine-id)"
echo
if [[ "$(cat /etc/machine-id)" == "$OLD_MACHINE_ID" ]]; then
	echo "WARNING: machine-id unchanged -- the old ID may still be in use."
	exit 1
fi
echo "Done. Reboot to pick up the new hostname everywhere."
```

The trailing check matters. `systemd-machine-id-setup` exits 0 in some
situations where it has not actually replaced the file — a bind mount, a
read-only `/etc`, an image with the file recreated by another unit. Comparing
before and after is the only reliable way to know the ID really changed.

## Why `rm` before `systemd-machine-id-setup`

`systemd-machine-id-setup` generates an ID only when `/etc/machine-id` is
**missing or empty**. Pointed at an existing 32-character hex file it does
nothing and exits successfully. This is the single most common way people
believe they have fixed a duplicate ID and have not.

```bash
sudo cat /etc/machine-id            # 32 hex chars, no dashes
sudo rm -f /etc/machine-id
sudo systemd-machine-id-setup       # "Initializing machine ID from random generator."
sudo cat /etc/machine-id            # different value now
```

`truncate -s 0 /etc/machine-id` is equivalent and avoids unlinking a file that
something else may hold open.

## What a machine-id is used for

A 32-character lowercase hex identifier in `/etc/machine-id`, generated once at
first boot and meant never to change for the life of the installation.

- **DHCP** — the client identifier sent in requests. Two machines presenting the
  same ID can be served the same lease, and one will lose connectivity when the
  other renews.
- **systemd journal** — stored per-machine. Shared IDs make `journalctl
  --merge` produce interleaved nonsense.
- **D-Bus** — via the symlink at `/var/lib/dbus/machine-id`.
- **libvirt, bcachefs, and monitoring agents** — use it to key caches and
  metrics, so two machines merge into one silently.

It is not a security credential. Nothing authenticates on it, which is why a
duplicate causes confusion rather than a breach.

## SSH host keys

`sshd` generates host keys at install time, so they land in the image and
clone with it. Two machines sharing a host key means the second one to be
reached from any given client triggers:

```
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
```

Every known_hosts entry for the source machine now fails verification for the
clone. The client refuses to connect, which is correct behaviour — it genuinely
cannot tell which machine it is reaching.

Detect a duplicate by comparing fingerprints against the source machine:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
ssh-keygen -lf /etc/ssh/ssh_host_rsa_key.pub
```

Regenerate only when they actually match:

```bash
sudo rm -f /etc/ssh/ssh_host_*
sudo systemctl restart sshd
```

No host keys present means `sshd` never ran or the distro ships them
unconfigured — there is nothing to fix. Do not generate keys on a machine that
does not run `sshd` just to be thorough; that creates the problem rather than
avoiding it.

## D-Bus machine-id

Current systems symlink rather than copy:

```bash
ls -l /var/lib/dbus/machine-id
# /var/lib/dbus/machine-id -> /etc/machine-id
```

When it is a symlink, fixing `/etc/machine-id` is sufficient. When it is a
regular file — older images, some minimal installs — it holds its own stale
value and must be regenerated separately:

```bash
sudo rm -f /var/lib/dbus/machine-id
sudo dbus-uuidgen --ensure
```

## Containers and VMs

Check what `/etc/machine-id` actually is before deleting anything:

```bash
findmnt /etc/machine-id
```

- **Bind mount** (Docker, Podman) — appears as a mount, is read-only, and
  `rm` fails. Correct: containers inherit the host's ID by design.
- **tmpfs** — generated per container. Usually fine as-is.
- **Real file on a VM guest** — safe to regenerate.

In cloud VMs, leave it alone. Instance identity is often deliberately tied to
the machine-id, and changing it can detach the instance from its metadata
service.

## Journals inherited from a restore

An image made with `journalctl` persistence carries the source machine's
history. The entries are tagged with the source's hostname, which is how a
clone announces itself:

```bash
journalctl --no-pager -o short-iso | head -1     # oldest — names the source machine
journalctl --no-pager -o short-iso | tail -1     # newest
```

Clear it, accepting that this is not selective:

```bash
sudo journalctl --rotate --vacuum-time=1s
```

`--rotate` closes the active file first so the vacuum can actually reclaim it;
without it the rotation alone frees nothing. To keep the current machine's own
logs while discarding the inherited ones, export first:

```bash
journalctl --since "-2 days" --export > /var/tmp/current-journal.journal-export
sudo journalctl --rotate --vacuum-time=1s
```

## Session timeline — one restore

- Restored an Omarchy image onto an HP Pavilion 15 (i5-6200U, Insyde F.81,
  2016) using the Rescuezilla clone feature. The image came from a Lenovo
  T440p.
- Booted clean. DMI correctly reported HP Pavilion Notebook, board 80A1,
  SKU T0E01UAR#ABA. Nothing in the boot path objected.
- Noticed the prompt still read `steven@lenovot440p`. Hostname and hardware had
  never agreed.
- Journal's oldest entry was dated 8 days earlier and tagged `_HOSTNAME:
  lenovot440p` — 91,767 entries, the majority belonging to the other laptop.
- `/etc/machine-id` was `180b0002e114454a92bf6b72a9ff3c0c`, written at restore
  time, byte-identical to the source.
- No `/etc/ssh/ssh_host_*_key.pub` existed — `sshd` had never generated keys,
  so no host-key duplication.
- `/var/lib/dbus/machine-id` was a symlink, so it needed no separate handling.
- `/etc/hosts` carried only `localhost` entries — no hostname line to update.
- Applied all three fixes. machine-id became `3dfa7205bc2347f9bb607c99ba92af92`,
  hostname `hp-pavilion-15`, journal down to 1 entry. Reboot pending.

### Failure modes worth remembering

- **`systemd-machine-id-setup` on an existing file is a silent no-op.** It exits
  0 and changes nothing. Always diff before and after.
- **`journalctl --vacuum-time=1s` is not selective.** It discarded this machine's
  own 8 days of logs along with the inherited ones. Archive first if that
  matters.
- **A stale hostname is the cheapest possible clone detector.** It is visible in
  every shell prompt, and it names the source machine rather than the current
  one.

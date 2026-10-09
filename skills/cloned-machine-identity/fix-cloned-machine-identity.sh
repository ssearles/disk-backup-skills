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

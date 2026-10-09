#!/usr/bin/env bash
# Read-only survey of machine identity across a fleet.
#
# Reports what each host currently has WITHOUT changing anything, so you know
# which machines actually need fixing before you run the destructive steps.
#
# Usage:
#   ./survey-fleet-identity.sh                    # survey localhost
#   ./survey-fleet-identity.sh host1 host2 ...    # survey over SSH
#
# Read-only: makes no changes, needs no root.

SOURCE_ID="${SOURCE_ID:-180b0002e114454a92bf6b72a9ff3c0c}"

probe() {
	local host="$1"
	if [[ "$host" == "localhost" || -z "$host" ]]; then
		RUN=(bash -s)
	else
		RUN=(ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" bash -s)
	fi

	"${RUN[@]}" <<-'REMOTE' 2>/dev/null || { printf '%-22s UNREACHABLE\n' "$host"; return; }
		h=$(hostname)
		id=$(cat /etc/machine-id 2>/dev/null || echo "MISSING")
		vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "?")
		model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "?")
		keys=$(ls /etc/ssh/ssh_host_*_key.pub 2>/dev/null | wc -l)
		jcount=$(journalctl --no-pager 2>/dev/null | wc -l)
		jhost=$(journalctl --no-pager -o json 2>/dev/null | head -100 \
			| python3 -c "
import sys, json
h = set()
for line in sys.stdin:
    try: h.add(json.loads(line).get('_HOSTNAME', '?'))
    except Exception: pass
print(','.join(sorted(h)) or 'none')
" 2>/dev/null)
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$h" "$id" "$vendor" "$model" "$keys" "$jcount" "$jhost" "LOCAL"
	REMOTE
}

printf '%-22s %-34s %-8s %-26s %-5s %-8s %s\n' \
	HOSTNAME MACHINE-ID VENDOR MODEL SSHKEYS JOURNAL JOURNAL-HOST
printf '%s\n' "---------------------------------------------------------------------------------------------------"

hosts=("$@")
[[ ${#hosts[@]} -eq 0 ]] && hosts=(localhost)

declare -A seen_ids
for h in "${hosts[@]}"; do
	line=$(probe "$h")
	[[ "$line" == *UNREACHABLE* ]] && { printf '%s\n' "$line"; continue; }
	printf '%-22s %-34s %-8s %-26s %-5s %-8s %s\n' \
		"$(cut -f1  <<<"$line")" "$(cut -f2  <<<"$line")" "$(cut -f3  <<<"$line")" \
		"$(cut -f4  <<<"$line")" "$(cut -f5  <<<"$line")" "$(cut -f6  <<<"$line")" \
		"$(cut -f7  <<<"$line")"
	seen_ids["$(cut -f2 <<<"$line")"]+=" $(cut -f1 <<<"$line")"
done

echo
echo "=== VERDICT ==="
for id in "${!seen_ids[@]}"; do
	members="${seen_ids[$id]}"
	count=$(wc -w <<<"$members")
	if [[ "$id" == "$SOURCE_ID" ]]; then
		echo "  $members"
		echo "      -> carries the SOURCE id. Legitimate on exactly one machine (the source)."
		echo "         Any OTHER machine here is a clone and needs fix-cloned-machine-identity.sh."
	elif [[ "$count" -gt 1 ]]; then
		echo "  DUPLICATE ID on:$members"
		echo "      -> every one of these is a clone of another. Fix all but one."
	else
		echo "  $members -- unique, no action"
	fi
done

#!/usr/bin/env bash
# Check CPU / load / memory status across all UCL lab machines (-l hosts) and
# URL servers. The CPU analogue of gpu-status.sh — same host discovery and
# parallel-ssh fan-out, but reports load average, core count, memory, and the
# busiest user instead of nvidia-smi output.
# Usage: ./scripts/cpu-status.sh
#
# NOTE: UCL-specific (reads the lab-gpu-* / url-gpu-* SSH config aliases — the
# same physical boxes, which of course also have CPUs). Kept on `main` next to
# gpu-status.sh so the cpu-status alias in configs/zshrc and configs/cshrc
# resolves wherever main is checked out.

set -euo pipefail

SSH_CONFIG="${HOME}/.ssh/config"
TIMEOUT=10

# Same host families as gpu-status: single-box lab hosts + multi-core URL hosts.
lab_hosts=$(grep -o 'Host lab-gpu-[^ ]*-l' "$SSH_CONFIG" | awk '{print $2}' | sort)
url_hosts=$(grep -o 'Host url-gpu-[^ ]*' "$SSH_CONFIG" | awk '{print $2}' | sort)

all_hosts="$lab_hosts"
if [[ -n "$url_hosts" ]]; then
    all_hosts=$(printf '%s\n%s' "$lab_hosts" "$url_hosts")
fi

if [[ -z "$all_hosts" ]]; then
    echo "No hosts found in $SSH_CONFIG"
    exit 1
fi

total=$(echo "$all_hosts" | wc -l | tr -d ' ')
echo "Checking $total machines..."
echo ""

up_count=0
down_count=0
free_count=0

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# My username on the boxes (from the resolved ssh config, nothing hardcoded) —
# rows where I'm the top CPU user are highlighted blue.
first_host=$(echo "$all_hosts" | head -1)
ME=$(ssh -G "$first_host" 2>/dev/null | awk '$1=="user"{print $2}')

# Remote script, emitted as a single line:
#   NCPU|LOAD1|MEM_USED_MB|MEM_TOTAL_MB|TOPUSER|TOPUSER_CPUPCT
# Core count from nproc; load1 from /proc/loadavg; memory from /proc/meminfo
# (MemTotal - MemAvailable, in MB); top CPU user by summing ps %cpu per user.
#
# The login shell on these boxes is csh, which mangles multi-line commands and
# nested quoting sent over ssh. So we base64-encode the script and decode+run it
# with bash on the box (the same gotcha documented for this cluster) — no csh
# quoting hazards, no matter how complex the script gets.
read -r -d '' REMOTE <<'REMOTE_EOF' || true
ncpu=$(nproc 2>/dev/null || echo 0)
load1=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo 0)
mt=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
ma=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
mu=$((mt-ma))
top=$(ps -eo user=,pcpu= --no-headers 2>/dev/null | awk '{s[$1]+=$2} END{b="";bv=0; for(u in s) if(s[u]>bv){bv=s[u];b=u}; if(b!="") printf "%s %.0f", b, bv}')
tu=${top% *}; tp=${top##* }
[ -z "$tu" ] && tu="-" && tp="0"
echo "${ncpu}|${load1}|${mu}|${mt}|${tu}|${tp}"
REMOTE_EOF
REMOTE_B64=$(printf '%s' "$REMOTE" | base64 | tr -d '\n')

# Launch all checks in parallel.
for host in $all_hosts; do
    (
        out=$(ssh -o RemoteCommand=none -o RequestTTY=no -o ControlMaster=no -o ControlPath=none \
            -o ConnectTimeout="$TIMEOUT" -o BatchMode=yes "$host" \
            "echo $REMOTE_B64 | base64 -d | bash" </dev/null 2>/dev/null) && [ -n "$out" ] && \
            { echo "UP" > "$tmpdir/${host}.status"; echo "$out" > "$tmpdir/${host}.output"; } || \
            echo "DOWN" > "$tmpdir/${host}.status"
    ) &
done

wait

fmt_mem() {  # MB -> human (GB with one decimal)
    local mb="$1"
    awk -v m="$mb" 'BEGIN{ if(m>=1024) printf "%.1fG", m/1024; else printf "%dM", m }'
}

printf "%-16s %-6s %-14s %-8s %-6s %-20s %s\n" \
    "MACHINE" "STATUS" "LOAD (1m/cpu)" "LOAD%" "CPUs" "MEMORY" "TOP USER"
printf "%-16s %-6s %-14s %-8s %-6s %-20s %s\n" \
    "-------" "------" "-------------" "-----" "----" "------" "--------"

for host in $all_hosts; do
    # Strip both prefixes/suffix for a short display name.
    name="${host#lab-gpu-}"; name="${name%-l}"; name="${name#url-gpu-}"
    status=$(cat "$tmpdir/${host}.status" 2>/dev/null || echo "DOWN")

    if [[ "$status" != "UP" ]]; then
        printf "%-16s %-6s\n" "$name" "DOWN"
        ((down_count++)) || true
        continue
    fi
    ((up_count++)) || true

    IFS='|' read -r ncpu load1 mem_used mem_total tuser tpct < "$tmpdir/${host}.output"

    # Load as a percentage of available cores (load1 / ncpu * 100).
    load_pct=$(awk -v l="$load1" -v n="$ncpu" 'BEGIN{ if(n>0) printf "%d", l/n*100; else print 0 }')
    # Memory used as a percentage of total.
    mem_pct=$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN{ if(t>0) printf "%d", u/t*100; else print 0 }')
    mem_str="$(fmt_mem "$mem_used") / $(fmt_mem "$mem_total")"
    top_str="$tuser"
    [[ "$tuser" != "-" ]] && top_str="$tuser (${tpct}%)"

    # FREE = both CPU and RAM headroom: load-per-core < 30% AND memory < 70% used.
    free_tag=""
    if [[ "$load_pct" -lt 30 && "$mem_pct" -lt 70 ]] 2>/dev/null; then
        free_tag="  *** FREE ***"
        ((free_count++)) || true
    fi

    if [[ "$tuser" == "$ME" && -n "$ME" ]]; then
        printf "\033[1;34m%-16s %-6s %-14s %-8s %-6s %-20s %s  << you%s\033[0m\n" \
            "$name" "UP" "${load1} / ${ncpu}" "${load_pct}%" "$ncpu" "$mem_str" "$top_str" "$free_tag"
    elif [[ -n "$free_tag" ]]; then
        printf "\033[1;32m%-16s %-6s %-14s %-8s %-6s %-20s %s%s\033[0m\n" \
            "$name" "UP" "${load1} / ${ncpu}" "${load_pct}%" "$ncpu" "$mem_str" "$top_str" "$free_tag"
    else
        printf "%-16s %-6s %-14s %-8s %-6s %-20s %s\n" \
            "$name" "UP" "${load1} / ${ncpu}" "${load_pct}%" "$ncpu" "$mem_str" "$top_str"
    fi
done

echo ""
echo "Summary: ${up_count}/${total} up, ${down_count}/${total} down, ${free_count} free (<30% load/core & <70% mem)"

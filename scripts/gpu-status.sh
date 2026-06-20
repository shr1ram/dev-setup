#!/usr/bin/env bash
# Check GPU status across all UCL lab machines (-l hosts) and URL GPU servers
# Usage: ./scripts/gpu-status.sh

set -euo pipefail

SSH_CONFIG="${HOME}/.ssh/config"
TIMEOUT=10

# Extract single-GPU lab hosts and multi-GPU URL hosts from ssh config
lab_hosts=$(grep -o 'Host lab-gpu-[^ ]*-l' "$SSH_CONFIG" | awk '{print $2}' | sort)
url_hosts=$(grep -o 'Host url-gpu-[^ ]*' "$SSH_CONFIG" | awk '{print $2}' | sort)

all_hosts="$lab_hosts"
if [[ -n "$url_hosts" ]]; then
    all_hosts=$(printf '%s\n%s' "$lab_hosts" "$url_hosts")
fi

if [[ -z "$all_hosts" ]]; then
    echo "No GPU hosts found in $SSH_CONFIG"
    exit 1
fi

total=$(echo "$all_hosts" | wc -l | tr -d ' ')
echo "Checking $total GPU machines..."
echo ""

up_count=0
down_count=0
free_count=0

# Temp dir for parallel results
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Remote one-liner: emit "user used_mib" per GPU compute process. ps runs on the
# box (PIDs are remote); username comes straight from ps -o user= (already
# trimmed). Run under bash -lc — the login shell on these hosts is csh, which
# can't parse this. Local awk (below) sums per user and picks the top consumer.
TOPUSER_REMOTE='apps=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null); [ -z "$apps" ] && exit 0; echo "$apps" | while IFS=, read -r p m; do p=${p// /}; m=${m// /}; [ -n "$p" ] && u=$(ps -o user= -p "$p" 2>/dev/null) && echo "${u// /} $m"; done'

# Launch all checks in parallel
for host in $all_hosts; do
    (
        output=$(ssh -o RemoteCommand=none -o ConnectTimeout="$TIMEOUT" -o BatchMode=yes "$host" \
            "nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total --format=csv,noheader" 2>/dev/null) && \
            echo "UP" > "$tmpdir/${host}.status" && \
            echo "$output" > "$tmpdir/${host}.output" || \
            echo "DOWN" > "$tmpdir/${host}.status"
        # Top GPU user (best-effort; empty/"—" when idle or unreadable).
        ssh -o RemoteCommand=none -o ConnectTimeout="$TIMEOUT" -o BatchMode=yes "$host" \
            bash -lc "'$TOPUSER_REMOTE'" 2>/dev/null \
            | awk '{ s[$1]+=$2; tot+=$2 } END { if(tot<=0) exit; b="";bv=0; for(u in s) if(s[u]>bv){bv=s[u];b=u}; printf "%s (%d%%)\n", b, (bv*100/tot) }' \
            > "$tmpdir/${host}.topuser" 2>/dev/null || true
    ) &
done

wait

# Helper: read the precomputed top-user string for a host ("—" if none).
top_user() { local f="$tmpdir/${1}.topuser"; [ -s "$f" ] && cat "$f" || echo "—"; }

# --- Single-GPU lab machines ---
printf "%-20s %-6s %-10s %-22s %-26s %s\n" "MACHINE" "STATUS" "GPU UTIL" "MEMORY" "GPU MODEL" "TOP USER"
printf "%-20s %-6s %-10s %-22s %-26s %s\n" "-------" "------" "--------" "------" "---------" "--------"

for host in $lab_hosts; do
    name="${host#lab-gpu-}"
    name="${name%-l}"
    status=$(cat "$tmpdir/${host}.status" 2>/dev/null || echo "DOWN")

    if [[ "$status" == "UP" ]]; then
        IFS=',' read -r gpu_name gpu_util mem_used mem_total < "$tmpdir/${host}.output"
        # Trim whitespace
        gpu_name=$(echo "$gpu_name" | xargs)
        gpu_util=$(echo "$gpu_util" | xargs)
        mem_used=$(echo "$mem_used" | xargs)
        mem_total=$(echo "$mem_total" | xargs)
        # Check if free: <10% util and <10% memory
        util_num=${gpu_util%% *}
        mem_used_num=${mem_used%% *}
        mem_total_num=${mem_total%% *}
        mem_pct=0
        if [[ "$mem_total_num" -gt 0 ]] 2>/dev/null; then
            mem_pct=$((mem_used_num * 100 / mem_total_num))
        fi
        tuser=$(top_user "$host")
        if [[ "$util_num" -lt 10 && "$mem_pct" -lt 10 ]] 2>/dev/null; then
            printf "\033[1;32m%-20s %-6s %-10s %-22s %-26s %s  *** FREE ***\033[0m\n" "$name" "UP" "$gpu_util" "${mem_used} / ${mem_total}" "$gpu_name" "$tuser"
            ((free_count++)) || true
        else
            printf "%-20s %-6s %-10s %-22s %-26s %s\n" "$name" "UP" "$gpu_util" "${mem_used} / ${mem_total}" "$gpu_name" "$tuser"
        fi
        ((up_count++)) || true
    else
        printf "%-20s %-6s\n" "$name" "DOWN"
        ((down_count++)) || true
    fi
done

# --- Multi-GPU URL machines (4 GPUs each) ---
if [[ -n "$url_hosts" ]]; then
    echo ""
    printf "%-20s %-6s %-5s %-10s %-22s %s\n" "MACHINE" "STATUS" "GPU#" "GPU UTIL" "MEMORY" "GPU MODEL"
    printf "%-20s %-6s %-5s %-10s %-22s %s\n" "-------" "------" "----" "--------" "------" "---------"

    for host in $url_hosts; do
        name="${host#url-gpu-}"
        status=$(cat "$tmpdir/${host}.status" 2>/dev/null || echo "DOWN")

        if [[ "$status" == "UP" ]]; then
            ((up_count++)) || true
            gpu_idx=0
            host_free=0
            host_total_gpus=0
            while IFS=',' read -r gpu_name gpu_util mem_used mem_total; do
                gpu_name=$(echo "$gpu_name" | xargs)
                gpu_util=$(echo "$gpu_util" | xargs)
                mem_used=$(echo "$mem_used" | xargs)
                mem_total=$(echo "$mem_total" | xargs)
                util_num=${gpu_util%% *}
                mem_used_num=${mem_used%% *}
                mem_total_num=${mem_total%% *}
                mem_pct=0
                if [[ "$mem_total_num" -gt 0 ]] 2>/dev/null; then
                    mem_pct=$((mem_used_num * 100 / mem_total_num))
                fi
                ((host_total_gpus++)) || true
                is_free=0
                if [[ "$util_num" -lt 10 && "$mem_pct" -lt 10 ]] 2>/dev/null; then
                    is_free=1
                    ((host_free++)) || true
                    ((free_count++)) || true
                fi
                # Show machine name only on first GPU row
                display_name=""
                display_status=""
                if [[ "$gpu_idx" -eq 0 ]]; then
                    display_name="$name"
                    display_status="UP"
                fi
                if [[ "$is_free" -eq 1 ]]; then
                    printf "\033[1;32m%-20s %-6s %-5s %-10s %-22s %s  *** FREE ***\033[0m\n" "$display_name" "$display_status" "$gpu_idx" "$gpu_util" "${mem_used} / ${mem_total}" "$gpu_name"
                else
                    printf "%-20s %-6s %-5s %-10s %-22s %s\n" "$display_name" "$display_status" "$gpu_idx" "$gpu_util" "${mem_used} / ${mem_total}" "$gpu_name"
                fi
                ((gpu_idx++)) || true
            done < "$tmpdir/${host}.output"
            # Host-level top GPU user (multi-GPU: process->GPU attribution isn't
            # reliable from the query, so this is the busiest user across the box).
            tuser=$(top_user "$host")
            printf "%-20s        \033[1;36m%d/%d GPUs free\033[0m   top user: %s\n" "" "$host_free" "$host_total_gpus" "$tuser"
        else
            printf "%-20s %-6s\n" "$name" "DOWN"
            ((down_count++)) || true
        fi
    done
fi

echo ""
echo "Summary: ${up_count}/${total} up, ${down_count}/${total} down, ${free_count} free GPUs"

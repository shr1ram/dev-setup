#!/usr/bin/env bash
# Check GPU status across all UCL lab machines (-l hosts)
# Usage: ./scripts/gpu-status.sh

set -euo pipefail

SSH_CONFIG="${HOME}/.ssh/config"
TIMEOUT=10

# Extract all lab-gpu-*-l hosts from ssh config
hosts=$(grep -o 'Host lab-gpu-[^ ]*-l' "$SSH_CONFIG" | awk '{print $2}' | sort)

if [[ -z "$hosts" ]]; then
    echo "No lab-gpu-*-l hosts found in $SSH_CONFIG"
    exit 1
fi

total=$(echo "$hosts" | wc -l | tr -d ' ')
echo "Checking $total lab GPU machines..."
echo ""

up_count=0
down_count=0
free_count=0

# Temp dir for parallel results
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Launch all checks in parallel
for host in $hosts; do
    (
        output=$(ssh -o RemoteCommand=none -o ConnectTimeout="$TIMEOUT" -o BatchMode=yes "$host" \
            "nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total --format=csv,noheader" 2>/dev/null) && \
            echo "UP" > "$tmpdir/${host}.status" && \
            echo "$output" > "$tmpdir/${host}.output" || \
            echo "DOWN" > "$tmpdir/${host}.status"
    ) &
done

wait

# Print results
printf "%-20s %-6s %-10s %-22s %s\n" "MACHINE" "STATUS" "GPU UTIL" "MEMORY" "GPU MODEL"
printf "%-20s %-6s %-10s %-22s %s\n" "-------" "------" "--------" "------" "---------"

for host in $hosts; do
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
        if [[ "$util_num" -lt 10 && "$mem_pct" -lt 10 ]] 2>/dev/null; then
            # Green highlight for free machines
            printf "\033[1;32m%-20s %-6s %-10s %-22s %s  *** FREE ***\033[0m\n" "$name" "UP" "$gpu_util" "${mem_used} / ${mem_total}" "$gpu_name"
            ((free_count++)) || true
        else
            printf "%-20s %-6s %-10s %-22s %s\n" "$name" "UP" "$gpu_util" "${mem_used} / ${mem_total}" "$gpu_name"
        fi
        ((up_count++)) || true
    else
        printf "%-20s %-6s\n" "$name" "DOWN"
        ((down_count++)) || true
    fi
done

echo ""
echo "Summary: ${up_count}/${total} up, ${down_count}/${total} down, ${free_count} free"

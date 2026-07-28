#!/usr/bin/env bash
#
# diagnose-oom.sh — read-only triage for out-of-memory (OOM) incidents
# on a Docker host (VM). It ONLY reads state and changes nothing.
#
# Run inside the affected VM. Some sections need sudo/root or docker-group
# membership; missing privileges are handled gracefully.
#
#   ./diagnose-oom.sh
#   sudo ./diagnose-oom.sh        # fuller output (all processes, journald)

set -uo pipefail

hr() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
hr "Host memory (free -h)"
free -h || echo "free not available"

# ---------------------------------------------------------------------------
hr "Actively swapping? (vmstat: si/so > 0 = pressure)"
if have vmstat; then
  vmstat 1 3
else
  echo "vmstat not installed (package: procps / sysstat)"
fi

# ---------------------------------------------------------------------------
hr "Top swap users (kB) — a sign of thrashing"
found=0
for f in /proc/*/status; do
  awk '/^Name:/{n=$2} /^VmSwap:/{if ($2+0>0) print $2, n}' "$f" 2>/dev/null
done | sort -rn | head -10 | awk '{found=1; printf "  %10s kB  %s\n", $1, $2} END{if(!found) print "  none"}'

# ---------------------------------------------------------------------------
if have docker; then
  hr "Containers by memory usage"
  docker stats --no-stream \
    --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}' 2>/dev/null \
    || echo "  cannot read docker stats (permissions? is dockerd running?)"

  hr "Containers WITHOUT a memory limit (Memory == 0)"
  none=1
  while read -r id; do
    [ -z "$id" ] && continue
    lim=$(docker inspect -f '{{.HostConfig.Memory}}' "$id" 2>/dev/null)
    if [ "$lim" = "0" ]; then
      none=0
      docker inspect -f '  {{.Name}}   image={{.Config.Image}}' "$id" 2>/dev/null
    fi
  done < <(docker ps -q 2>/dev/null)
  [ "$none" = "1" ] && echo "  (all running containers have a limit, or docker is unreadable)"
else
  hr "Docker"
  echo "  docker CLI not found"
fi

# ---------------------------------------------------------------------------
hr "OOM kills — current boot"
if have journalctl; then
  journalctl -k --no-pager 2>/dev/null | grep -iE 'out of memory|oom-kill' | tail -20 \
    || echo "  none"
else
  dmesg -T 2>/dev/null | grep -iE 'out of memory|oom-kill' | tail -20 || echo "  (need journalctl or dmesg access)"
fi

# ---------------------------------------------------------------------------
hr "OOM kills — previous boot"
if have journalctl; then
  out=$(journalctl -b -1 -k --no-pager 2>/dev/null | grep -iE 'out of memory|oom-kill' | tail -20)
  if [ -n "$out" ]; then echo "$out"; else echo "  none (no previous-boot log, or no OOM there)"; fi
else
  echo "  journalctl not available"
fi

# ---------------------------------------------------------------------------
hr "Container behind the most recent OOM (from task_memcg)"
if have journalctl && have docker; then
  cid=$(journalctl -b -1 -k --no-pager 2>/dev/null \
        | grep -oE 'docker-[0-9a-f]{64}\.scope' \
        | tail -1 | sed -E 's/docker-([0-9a-f]{64})\.scope/\1/')
  if [ -n "${cid:-}" ]; then
    echo "  cgroup container id: $cid"
    docker ps -a --no-trunc --filter "id=$cid" \
      --format '  name={{.Names}}  image={{.Image}}  status={{.Status}}' 2>/dev/null \
      | grep . || echo "  (container no longer exists — it may have been re-created)"
  else
    echo "  no docker cgroup found in previous-boot OOM lines"
  fi
else
  echo "  need both journalctl and docker to correlate"
fi

hr "Done"
echo "Next steps: cap the offending container's memory, e.g."
echo "  docker update --memory 3g --memory-swap 3g <container>"
echo "See README.md section 4 for persistence and root-cause fixes."

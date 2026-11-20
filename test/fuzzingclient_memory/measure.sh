#!/usr/bin/env bash
# Run the echo server and the full fuzzingclient in Docker, sampling both
# containers' memory (RAM + swap) every 2s from their cgroups.
#
# Usage: measure.sh <outdir> <client-memory-limit|none> <client-force-gc: yes|no> <server-force-gc: yes|no>
# Env:   IMAGE (required), PYTHON_BIN (default: python, inside the image),
#        SPEC (default: fuzzingclient.json, in this directory)
set -euo pipefail

OUT=$1
LIMIT=$2
FORCE_GC=$3
SERVER_GC=$4
: "${IMAGE:?IMAGE must be set}"
PYTHON_BIN=${PYTHON_BIN:-python}
SPEC=${SPEC:-fuzzingclient.json}
HERE=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$OUT/reports"
OUT=$(cd "$OUT" && pwd)

gc_on=(-e PYTHONPATH=/gcforce -v "$HERE/gcforce:/gcforce:ro")
gc_args=()
[ "$FORCE_GC" = yes ] && gc_args=("${gc_on[@]}")
server_gc_args=()
[ "$SERVER_GC" = yes ] && server_gc_args=("${gc_on[@]}")
limit_args=()
if [ "$LIMIT" != none ]; then
  limit_args=(--memory="$LIMIT" --memory-swap="$LIMIT")
fi

docker rm -f echo-server fuzzingclient >/dev/null 2>&1 || true

docker run -d --pull never --name echo-server --network host \
  "${server_gc_args[@]}" -v "$HERE:/test:ro" \
  "$IMAGE" "$PYTHON_BIN" /test/echo_server.py ws://127.0.0.1:9001 >/dev/null
for _ in $(seq 30); do
  (echo > /dev/tcp/127.0.0.1/9001) 2>/dev/null && break
  sleep 1
done

docker run -d --pull never --name fuzzingclient --network host \
  "${limit_args[@]}" "${gc_args[@]}" -e PYTHONUNBUFFERED=1 \
  -v "$HERE:/config:ro" -v "$OUT/reports:/reports" \
  "$IMAGE" wstest --mode fuzzingclient --spec "/config/$SPEC" >/dev/null

# Resolve each container's cgroup directory (cgroup v2 or v1 memory controller).
cgdir() {
  local pid line
  pid=$(docker inspect -f '{{.State.Pid}}' "$1")
  if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    line=$(grep '^0::' "/proc/$pid/cgroup" | cut -d: -f3)
    echo "/sys/fs/cgroup$line"
  else
    line=$(grep ':memory:' "/proc/$pid/cgroup" | cut -d: -f3)
    echo "/sys/fs/cgroup/memory$line"
  fi
}
# Current RAM + swap of a cgroup, in bytes.
usage() {
  local d=$1
  if [ -f "$d/memory.current" ]; then
    echo $(( $(cat "$d/memory.current") + $(cat "$d/memory.swap.current" 2>/dev/null || echo 0) ))
  else
    cat "$d/memory.memsw.usage_in_bytes" 2>/dev/null || cat "$d/memory.usage_in_bytes"
  fi
}

# Kernel-recorded peak of a cgroup (RAM + swap where available), in bytes.
kpeak() {
  local d=$1
  if [ -f "$d/memory.peak" ]; then
    echo $(( $(cat "$d/memory.peak") + $(cat "$d/memory.swap.peak" 2>/dev/null || echo 0) ))
  else
    cat "$d/memory.memsw.max_usage_in_bytes" 2>/dev/null || cat "$d/memory.max_usage_in_bytes"
  fi
}

client_cg=$(cgdir fuzzingclient)
server_cg=$(cgdir echo-server)
if [ -f "$client_cg/memory.max" ]; then
  echo "client cgroup: memory.max=$(cat "$client_cg/memory.max") memory.swap.max=$(cat "$client_cg/memory.swap.max")"
else
  echo "client cgroup: memory.limit=$(cat "$client_cg/memory.limit_in_bytes") memsw.limit=$(cat "$client_cg/memory.memsw.limit_in_bytes" 2>/dev/null || echo n/a)"
fi

echo "t,case,client_bytes,server_bytes" > "$OUT/samples.csv"
start=$(date +%s)
client_peak=0
server_peak=0
client_kpeak=0
server_kpeak=0
while [ "$(docker inspect -f '{{.State.Running}}' fuzzingclient)" = true ]; do
  c=$(usage "$client_cg" 2>/dev/null || echo 0)
  s=$(usage "$server_cg" 2>/dev/null || echo 0)
  [ "$c" -gt "$client_peak" ] && client_peak=$c
  [ "$s" -gt "$server_peak" ] && server_peak=$s
  kc=$(kpeak "$client_cg" 2>/dev/null || echo 0); [ "$kc" -gt "$client_kpeak" ] && client_kpeak=$kc
  ks=$(kpeak "$server_cg" 2>/dev/null || echo 0); [ "$ks" -gt "$server_kpeak" ] && server_kpeak=$ks
  case_id=$(docker logs --tail 1 fuzzingclient 2>&1 | sed -n 's/.*Running test case ID \([0-9.]*\).*/\1/p')
  echo "$(( $(date +%s) - start )),${case_id:--},$c,$s" >> "$OUT/samples.csv"
  sleep 2
done

docker logs fuzzingclient > "$OUT/client.log" 2>&1
docker logs echo-server > "$OUT/server.log" 2>&1
exit_code=$(docker inspect -f '{{.State.ExitCode}}' fuzzingclient)
oom=$(docker inspect -f '{{.State.OOMKilled}}' fuzzingclient)
last_case=$(grep 'Running test case ID' "$OUT/client.log" | tail -1 | sed 's/.*ID \([0-9.]*\).*/\1/')

{
  echo "client limit=$LIMIT client force_gc=$FORCE_GC server force_gc=$SERVER_GC"
  echo "client: exit=$exit_code oom_killed=$oom last_case=$last_case elapsed=$(( $(date +%s) - start ))s"
  echo "client peak: $(( client_kpeak / 1048576 )) MiB (kernel), $(( client_peak / 1048576 )) MiB (sampled)"
  echo "server peak: $(( server_kpeak / 1048576 )) MiB (kernel), $(( server_peak / 1048576 )) MiB (sampled)"
  echo "--- end-of-group memory (MiB) ---"
  awk -F, 'NR > 1 && $2 ~ /^1[23]\./ { split($2, p, "."); g = p[1] "." p[2]; c[g] = $3; s[g] = $4; if (!(g in seen)) { seen[g] = 1; order[++n] = g } }
           END { for (i = 1; i <= n; i++) printf "%-5s client %6d  server %6d\n", order[i], c[order[i]] / 1048576, s[order[i]] / 1048576 }' "$OUT/samples.csv"
} | tee "$OUT/summary.txt"

docker rm -f echo-server fuzzingclient >/dev/null 2>&1 || true
exit "$exit_code"

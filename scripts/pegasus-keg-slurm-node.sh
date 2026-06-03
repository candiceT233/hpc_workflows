#!/usr/bin/env bash
set -euo pipefail

if [ -z "${PEGASUS_KEG_BIN:-}" ]; then
  PEGASUS_KEG_BIN="$(command -v pegasus-keg)"
fi

if [ -z "${PEGASUS_HOSTFILE:-}" ] || [ ! -s "$PEGASUS_HOSTFILE" ]; then
  exec "$PEGASUS_KEG_BIN" "$@"
fi

job_name="merge"
previous=""
for arg in "$@"; do
  if [ "$previous" = "-a" ]; then
    job_name="$arg"
    break
  fi
  previous="$arg"
done

index=0
if [[ "$job_name" =~ process-([0-9]+)$ ]]; then
  index="${BASH_REMATCH[1]}"
fi

mapfile -t hosts < "$PEGASUS_HOSTFILE"
host_count="${#hosts[@]}"
if [ "$host_count" -eq 0 ]; then
  exec "$PEGASUS_KEG_BIN" "$@"
fi

host="${hosts[$(( index % host_count ))]}"
if [ -n "${PEGASUS_NODE_LOG:-}" ]; then
  printf '%s %s\n' "$job_name" "$host" >> "$PEGASUS_NODE_LOG"
fi

if [ "${PEGASUS_PROFILE_MODE:-}" = "datalife" ]; then
  exec srun --nodes=1 --ntasks=1 --exclusive -w "$host" \
    --export=ALL,DATALIFE_OUTPUT_PATH="${PEGASUS_DATALIFE_TRACE_DIR:-}",DATALIFE_FILE_PATTERNS="${PEGASUS_DATALIFE_FILE_PATTERNS:-*.txt,*.log,*.out,*.err,*.yml,*.db}",LD_PRELOAD="${PEGASUS_DATALIFE_LIB:-}" \
    "$PEGASUS_KEG_BIN" "$@"
elif [ "${PEGASUS_PROFILE_MODE:-}" = "darshan" ]; then
  exec srun --nodes=1 --ntasks=1 --exclusive -w "$host" \
    --export=ALL,DARSHAN_ENABLE_NONMPI=1,DARSHAN_LOG_DIR_PATH="${PEGASUS_DARSHAN_TRACE_DIR:-}",LD_PRELOAD="${PEGASUS_DARSHAN_LIB:-}" \
    "$PEGASUS_KEG_BIN" "$@"
else
  exec srun --nodes=1 --ntasks=1 --exclusive -w "$host" "$PEGASUS_KEG_BIN" "$@"
fi

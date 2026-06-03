#!/usr/bin/env bash
set -euo pipefail

repo="${PEGASUS_1000G_REPO:-}"
if [ -z "$repo" ]; then
  echo "PEGASUS_1000G_REPO is required" >&2
  exit 2
fi

name="$(basename "$0")"
case "$name" in
  individuals|individuals_merge|sifting|mutation_overlap)
    target="$repo/bin/$name"
    ;;
  frequency)
    target="$repo/bin/frequency.py"
    ;;
  *)
    echo "Unknown 1000genome transformation name: $name" >&2
    exit 3
    ;;
esac

if [ ! -x "$target" ]; then
  echo "Missing 1000genome transformation executable: $target" >&2
  exit 4
fi

if [ -z "${PEGASUS_1000G_HOSTFILE:-}" ] || [ ! -s "$PEGASUS_1000G_HOSTFILE" ]; then
  exec "$target" "$@"
fi

mapfile -t hosts < "$PEGASUS_1000G_HOSTFILE"
host_count="${#hosts[@]}"
if [ "$host_count" -eq 0 ]; then
  exec "$target" "$@"
fi

counter_file="${PEGASUS_1000G_COUNTER_FILE:-$(dirname "$PEGASUS_1000G_HOSTFILE")/1000genome-node-counter.txt}"
lock_file="${counter_file}.lock"
mkdir -p "$(dirname "$counter_file")"
{
  flock 9
  if [ -s "$counter_file" ]; then
    counter="$(cat "$counter_file")"
  else
    counter=0
  fi
  host="${hosts[$(( counter % host_count ))]}"
  printf '%s\n' "$((counter + 1))" > "$counter_file"
} 9>"$lock_file"

if [ -n "${PEGASUS_1000G_NODE_LOG:-}" ]; then
  printf '%s %s %s\n' "$(date -Is)" "$name" "$host" >> "$PEGASUS_1000G_NODE_LOG"
fi

if [ "${PEGASUS_1000G_PROFILE_MODE:-}" = "datalife" ]; then
  exec srun --nodes=1 --ntasks=1 --exclusive -w "$host" \
    --export=ALL,DATALIFE_OUTPUT_PATH="${PEGASUS_1000G_DATALIFE_TRACE_DIR:-}",DATALIFE_FILE_PATTERNS="${PEGASUS_1000G_DATALIFE_FILE_PATTERNS:-*.vcf,*.tar.gz,*.txt,*.log,*.out,*.err}",LD_PRELOAD="${PEGASUS_1000G_DATALIFE_LIB:-}" \
    "$target" "$@"
elif [ "${PEGASUS_1000G_PROFILE_MODE:-}" = "darshan" ]; then
  exec srun --nodes=1 --ntasks=1 --exclusive -w "$host" \
    --export=ALL,DARSHAN_ENABLE_NONMPI=1,DARSHAN_LOG_DIR_PATH="${PEGASUS_1000G_DARSHAN_TRACE_DIR:-}",LD_PRELOAD="${PEGASUS_1000G_DARSHAN_LIB:-}" \
    "$target" "$@"
else
  exec srun --nodes=1 --ntasks=1 --exclusive -w "$host" "$target" "$@"
fi

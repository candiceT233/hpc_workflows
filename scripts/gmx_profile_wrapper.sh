#!/usr/bin/env bash
set -euo pipefail

if [ -z "${REAL_GMX_BINARY:-}" ]; then
  echo "REAL_GMX_BINARY is not set" >&2
  exit 2
fi

if [ "${BIOBB_PROFILE_MODE:-}" = "datalife" ]; then
  # DataLife currently crashes inside GROMACS pdb2gmx/fputs. Trace the
  # Python/BioBB workflow layer and keep the native GROMACS child unpreloaded.
  exec env -u LD_PRELOAD "$REAL_GMX_BINARY" "$@"
elif [ "${BIOBB_PROFILE_MODE:-}" = "darshan" ]; then
  exec env DARSHAN_ENABLE_NONMPI=1 \
    DARSHAN_LOG_DIR_PATH="${BIOBB_TRACE_DIR:-}" \
    LD_PRELOAD="${DARSHAN_LIB:-}" \
    "$REAL_GMX_BINARY" "$@"
else
  exec "$REAL_GMX_BINARY" "$@"
fi

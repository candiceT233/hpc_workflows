#!/bin/bash
# Diagnose why DataLife writes 0 trace JSONs on mProjectPP. Show stderr, try a
# few env knobs, and look for output in both DATALIFE_OUTPUT_PATH and CWD.
set -u
MB=/qfs/people/tang584/install/Montage/bin
DL=/qfs/projects/datamesh/tang584/widget_evaluation/widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so
SRC=/qfs/projects/datamesh/tang584/widget_evaluation/hpc_workflows/data/Montage/_test
W=/scratch/$USER/dl_debug_$$
mkdir -p "$W/out" "$W/dl"
echo "host=$(hostname)"

echo "############ A) OUTPUT_PATH set, stderr SHOWN, run from inside dl dir ############"
cd "$W/dl"
export DATALIFE_OUTPUT_PATH="$W/dl" DATALIFE_TASK_NAME=montage_dbg
env LD_PRELOAD="$DL" "$MB/mProjectPP" "$SRC/tile_000000.fits" "$W/out/a.fits" "$SRC/template.hdr"
echo "exit=$?"
echo "-- files in DATALIFE_OUTPUT_PATH=$W/dl --"; ls -la "$W/dl"
echo "-- *.json anywhere under $W --"; find "$W" -name '*.json'

echo "############ B) with cp (real read+write of a big file) as a control ############"
cd "$W"
env LD_PRELOAD="$DL" DATALIFE_OUTPUT_PATH="$W/dl" cp "$SRC/tile_000001.fits" "$W/out/copy.fits"
echo "cp exit=$?"; echo "-- json after cp --"; find "$W" -name '*.json' | head

echo "############ C) try DATALIFE_FILE_PATTERNS / TRACE_PATTERN = .fits ############"
cd "$W/dl"
env LD_PRELOAD="$DL" DATALIFE_OUTPUT_PATH="$W/dl" DATALIFE_FILE_PATTERNS="fits" DATALIFE_TRACE_PATTERN="fits" DATALIFE_PATTERN="fits" \
   "$MB/mProjectPP" "$SRC/tile_000002.fits" "$W/out/c.fits" "$SRC/template.hdr" 2>&1 | head -20
echo "-- json after C --"; find "$W" -name '*.json' | head
echo "DBG_DONE"

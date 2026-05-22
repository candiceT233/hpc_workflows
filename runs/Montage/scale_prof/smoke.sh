#!/bin/bash
# Smoke-test the Montage mProjectPP reprojection under DataLife + Darshan on a
# compute node (login node has intermittent EREMOTEIO on exec). Run via:
#   srun -A oddite -p slurm -N1 -n1 -t 0:15:00 bash smoke.sh
set -u
MB=/qfs/people/tang584/install/Montage/bin
DL=/qfs/projects/datamesh/tang584/widget_evaluation/widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so
DARSHAN=/people/tang584/install/darshan_runtime/lib/libdarshan.so
SRC=/qfs/projects/datamesh/tang584/widget_evaluation/hpc_workflows/data/Montage/_test
W=/scratch/$USER/montage_smoke_$$
Y=$(date +%Y); M=$(date +%-m); D=$(date +%-d)
rm -rf "$W"; mkdir -p "$W/proj" "$W/dl" "$W/darshan/$Y/$M/$D"
echo "host=$(hostname) W=$W darshan_date=$Y/$M/$D"

echo "########## 0) baseline mProjectPP (no profiler) ##########"
timeout 60 "$MB/mProjectPP" "$SRC/tile_000000.fits" "$W/proj/base.fits" "$SRC/template.hdr"
echo "baseline exit=$?"

echo "########## 1) DataLife (libmonitor) ##########"
( cd "$W/dl" && timeout 60 env LD_PRELOAD="$DL" "$MB/mProjectPP" "$SRC/tile_000001.fits" "$W/proj/dl.fits" "$SRC/template.hdr" )
echo "datalife exit=$? (124=hang)"
echo "DataLife json in CWD:"; ls -la "$W/dl" | grep -iE 'json|trace'; echo "count=$(ls "$W/dl" 2>/dev/null | wc -l)"

echo "########## 2) Darshan (libdarshan nonmpi) ##########"
timeout 60 env LD_PRELOAD="$DARSHAN" DARSHAN_ENABLE_NONMPI=1 DARSHAN_LOGPATH="$W/darshan" \
    "$MB/mProjectPP" "$SRC/tile_000002.fits" "$W/proj/d.fits" "$SRC/template.hdr"
echo "darshan exit=$? (124=hang)"
echo "Darshan logs:"; find "$W/darshan" -name '*.darshan*' ; echo "count=$(find "$W/darshan" -name '*.darshan*' | wc -l)"

# NOTE: Darshan and DataLife are NEVER stacked in one LD_PRELOAD. They are
# always collected in SEPARATE runs (the real launcher does separate srun
# passes). Stacking two POSIX-interception libs would corrupt both traces.
echo "=== final outputs ==="; ls -la "$W/proj"
echo "SMOKE_DONE"

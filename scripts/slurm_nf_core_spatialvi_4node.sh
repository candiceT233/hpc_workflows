#!/usr/bin/env bash
#SBATCH --job-name=spatialvi-4
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_spatialvi/slurm-%j-4node.out
#SBATCH --error=runs/nf-core_spatialvi/slurm-%j-4node.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_spatialvi"
DATA_DIR="$ROOT/data/nf-core_spatialvi/full"
INPUT="$DATA_DIR/visium_ovarian_full_samplesheet_local.csv"
RUN_ROOT="${RUN_ROOT:-$ROOT/runs/nf-core_spatialvi}"
RUN_DIR="$RUN_ROOT/4node-${SLURM_JOB_ID:-manual}"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
REFERENCE="$DATA_DIR/refdata-gex-GRCh38-2020-A.tar.gz"
FASTQS_TAR="$DATA_DIR/Visium_FFPE_Human_Ovarian_Cancer_fastqs.tar"
IMAGE="$DATA_DIR/Visium_FFPE_Human_Ovarian_Cancer_image.jpg"
SLIDEFILE="$DATA_DIR/V10L13-020.gpr"

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$ROOT/tools/nextflow-home" "$DATA_DIR"
download_artifact() {
  local url="$1"
  local dest="$2"
  if [ ! -s "$dest" ]; then
    curl --fail --location --retry 8 --retry-delay 10 --retry-all-errors \
      --output "$dest.tmp" "$url"
    mv "$dest.tmp" "$dest"
  fi
}

download_artifact "https://cf.10xgenomics.com/samples/spatial-exp/1.3.0/Visium_FFPE_Human_Ovarian_Cancer/Visium_FFPE_Human_Ovarian_Cancer_fastqs.tar" "$FASTQS_TAR"
download_artifact "https://cf.10xgenomics.com/samples/spatial-exp/1.3.0/Visium_FFPE_Human_Ovarian_Cancer/Visium_FFPE_Human_Ovarian_Cancer_image.jpg" "$IMAGE"
download_artifact "https://s3.us-west-2.amazonaws.com/10x.spatial-slides/gpr/V10L13/V10L13-020.gpr" "$SLIDEFILE"
download_artifact "https://cf.10xgenomics.com/supp/spatial-exp/refdata-gex-GRCh38-2020-A.tar.gz" "$REFERENCE"

cat > "$INPUT" <<EOF
sample,fastq_dir,image,slide,area,manual_alignment,slidefile
Visium_FFPE_Human_Ovarian_Cancer,$FASTQS_TAR,$IMAGE,V10L13-020,D1,,$SLIDEFILE
EOF

OVERRIDE="$RUN_DIR/spatialvi_ares_override.config"
cat > "$OVERRIDE" <<'EOF'
process {
  resourceLimits = [ cpus: 40, memory: 45.GB, time: 48.h ]
  withLabel:process_high {
    cpus = 12
    memory = 45.GB
  }
  withLabel:process_spaceranger {
    cpus = 12
    memory = 45.GB
  }
}
EOF

validate_outputs() {
  local outdir="$1"
  local label="$2"
  if ! find "$outdir/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
    echo "ERROR: $label missing Nextflow execution trace" >&2
    exit 1
  fi
  if ! find "$outdir/multiqc" -type f -name 'multiqc_report.html' -size +100000 | grep -q .; then
    echo "ERROR: $label missing non-trivial MultiQC report" >&2
    exit 1
  fi
  if ! find "$outdir" -type f \( -name '*.h5ad' -o -name '*.zarr' -o -name 'report-*.html' -o -name 'report-integrated.html' \) -size +0 | grep -q .; then
    echo "ERROR: $label missing non-empty downstream spatial analysis outputs" >&2
    exit 1
  fi
  local output_count
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 50 ]; then
    echo "ERROR: $label too few non-empty spatialvi outputs: $output_count" >&2
    exit 1
  fi
  echo "$output_count"
}

run_replica() {
  local replica="$1"
  local rep_dir="$RUN_DIR/replica-${replica}"
  local final_outdir="$rep_dir/results"
  local node_tmp="/tmp/nf-core_spatialvi-${SLURM_JOB_ID:-$$}-${replica}"
  local node_run_dir="$node_tmp/run"
  local node_repo="$node_run_dir/repo"
  local outdir="$node_run_dir/results"
  local workdir="$node_run_dir/work"
  local tmp_root="$workdir/tmp"
  local podman_base="$rep_dir/podman-storage"

  mkdir -p "$rep_dir/podman-bin" "$final_outdir" "$outdir" "$workdir" "$tmp_root" "$node_repo"
  rm -rf "$podman_base"
  mkdir -p "$podman_base"/{xdg,root,run,tmp}
  cp -a "$REPO/." "$node_repo/"
  chmod 700 "$podman_base/xdg"
  local podman_real
  podman_real="$(command -v podman || true)"
  if [ -z "$podman_real" ]; then
    echo "ERROR: podman is not available on this compute node" >&2
    exit 1
  fi
  cat > "$rep_dir/podman-bin/podman" <<EOF
#!/bin/bash
exec "$podman_real" --storage-driver vfs --root "$podman_base/root" --runroot "$podman_base/run" --tmpdir "$podman_base/tmp" "\$@"
EOF
  chmod +x "$rep_dir/podman-bin/podman"

  export TMPDIR="$tmp_root" NXF_TEMP="$tmp_root" XDG_RUNTIME_DIR="$podman_base/xdg"
  export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$tmp_root"
  export JAVA_HOME="$NF_ENV" JAVA_CMD="$NF_ENV/bin/java" NXF_HOME="$ROOT/tools/nextflow-home"
  export NXF_VER="25.10.4" NXF_OPTS="-Xms1g -Xmx8g" NXF_SYNTAX_PARSER=v1 NXF_OFFLINE=true
  export PATH="$rep_dir/podman-bin:$NF_ENV/bin:$ROOT/tools/miniforge/bin:$ROOT/tools/miniforge/condabin:$PATH"

  cd "$node_run_dir"
  nextflow run "$node_repo" \
    -name "spatialvi_4node_${SLURM_JOB_ID:-manual}_${replica}" \
    -profile podman \
    -c "$ROOT/config/nextflow_ares_local_podman.config" \
    -c "$OVERRIDE" \
    -work-dir "$workdir" \
    --input "$INPUT" \
    --spaceranger_reference "$REFERENCE" \
    --outdir "$outdir"

  cp -a "$outdir/." "$final_outdir/"
  output_count="$(validate_outputs "$final_outdir" "replica $replica")"
  find "$final_outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"
  echo "nf-core/spatialvi replica $replica native Nextflow baseline completed with $output_count non-empty output files"
}

if [ "${1:-}" = "worker" ]; then
  run_replica "$2"
  exit 0
fi

for replica in 0 1 2 3; do
  srun --exclusive --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-40}" \
    "$0" worker "$replica" > "$RUN_DIR/replica-${replica}.out" 2> "$RUN_DIR/replica-${replica}.err" &
done
wait

for replica in 0 1 2 3; do
  test -s "$RUN_DIR/replica-${replica}/nonempty-outputs.txt"
done

echo "nf-core/spatialvi native 4-node Nextflow baseline completed across 4 nodes"

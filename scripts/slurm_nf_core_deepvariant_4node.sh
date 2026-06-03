#!/usr/bin/env bash
#SBATCH --job-name=deepvariant-4node
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_deepvariant/slurm-%j-4node.out
#SBATCH --error=runs/nf-core_deepvariant/slurm-%j-4node.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_deepvariant"
DATADIR="$ROOT/data/nf-core_deepvariant/giab_exome"
RUN_ROOT="$ROOT/runs/nf-core_deepvariant"
RUN_DIR="$RUN_ROOT/4node-${SLURM_JOB_ID:-manual}"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"
BAM="$DATADIR/NIST-hg001-7001-ready.bam"
BED="$DATADIR/HG001_GRCh37_1_22_v4.2.1_benchmark.bed"
FASTA="$DATADIR/Homo_sapiens.GRCh37.dna.primary_assembly.fa"

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$ROOT/tools/nextflow-home"
cd "$ROOT"

for required in "$NF_ENV/bin/nextflow" "$BAM" "$BAM.bai" "$BED" "$FASTA"; do
  if [ ! -s "$required" ] && [ ! -x "$required" ]; then
    echo "ERROR: missing required nf-core/deepvariant input or executable: $required" >&2
    exit 1
  fi
done

run_replica() {
  local replica="$1"
  local rep_dir="$RUN_DIR/replica-${replica}"
  local outdir="$rep_dir/results"
  local workdir="$rep_dir/work"
  local tmp_root="$workdir/tmp"
  local pkgs_root="$rep_dir/conda-pkgs"
  local cache_root="$rep_dir/nextflow-conda-cache"
  local condarc="$rep_dir/condarc"
  local override="$rep_dir/deepvariant_ares_override.config"
  local podman_base="/tmp/pdm-deepvariant-${SLURM_JOB_ID:-$$}-${replica}"

  mkdir -p "$outdir" "$workdir" "$tmp_root" "$pkgs_root" "$cache_root" "$rep_dir/podman-bin" "$podman_base"/{xdg,root,run,tmp}
  chmod 700 "$podman_base/xdg"
  export TMPDIR="$tmp_root"
  export NXF_TEMP="$tmp_root"
  export XDG_RUNTIME_DIR="$podman_base/xdg"
  export CONDA_PKGS_DIRS="$pkgs_root"
  export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$tmp_root"
  export MAMBA_YES=true
  export MAMBA_ALWAYS_YES=true
  export CONDA_ALWAYS_YES=true
  cat > "$condarc" <<'EOF'
always_yes: true
auto_activate_base: false
channel_priority: flexible
channels:
  - conda-forge
  - bioconda
  - defaults
EOF
  export CONDARC="$condarc"

  local podman_real
  podman_real="$(command -v podman || true)"
  if [ -z "$podman_real" ]; then
    echo "ERROR: podman is not available on this compute node" >&2
    exit 1
  fi
  cat > "$rep_dir/podman-bin/podman" <<EOF
#!/usr/bin/env bash
exec "$podman_real" --root "$podman_base/root" --runroot "$podman_base/run" --tmpdir "$podman_base/tmp" "\$@"
EOF
  chmod +x "$rep_dir/podman-bin/podman"

  cat > "$override" <<EOF
conda {
  enabled = false
}
docker {
  enabled = false
}
singularity {
  enabled = false
}
podman {
  enabled = true
  runOptions = '--userns=keep-id'
}
process {
  maxForks = 4
  container = 'docker.io/nfcore/deepvariant:1.0'
}
params.container = 'docker.io/nfcore/deepvariant:1.0'
EOF

  export JAVA_HOME="$NF_ENV"
  export JAVA_CMD="$NF_ENV/bin/java"
  export NXF_HOME="$ROOT/tools/nextflow-home"
  export NXF_OFFLINE=true
  export NXF_VER=22.10.8
  export NXF_OPTS="-Xms1g -Xmx8g"
  export NXF_SYNTAX_PARSER=v1
  export PATH="$rep_dir/podman-bin:$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

  cd "$rep_dir"
  nextflow run "$REPO" \
    -profile standard \
    -c "$ROOT/config/nextflow_ares_local_podman.config" \
    -c "$override" \
    -work-dir "$workdir" \
    --bam "$BAM" \
    --bed "$BED" \
    --fasta "$FASTA" \
    --exome \
    --outdir "$outdir"

  if ! find "$outdir/pipeline_info" -maxdepth 2 -type f \( -name 'nf-core*trace.txt' -o -name 'execution_trace*' \) -size +0 | grep -q .; then
    echo "ERROR: replica $replica missing Nextflow execution trace" >&2
    exit 1
  fi
  if ! find "$outdir/Documentation" -type f -name 'pipeline_report.html' -size +1000 | grep -q .; then
    echo "ERROR: replica $replica missing non-trivial DeepVariant pipeline HTML report" >&2
    exit 1
  fi
  if ! find "$outdir" -maxdepth 1 -type f -name '*.vcf' -size +0 | grep -q .; then
    echo "ERROR: replica $replica missing non-empty DeepVariant VCF output" >&2
    exit 1
  fi
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 5 ]; then
    echo "ERROR: replica $replica too few non-empty outputs: $output_count" >&2
    exit 1
  fi
  find "$outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"
  echo "nf-core/deepvariant replica $replica native Nextflow baseline completed with $output_count non-empty output files"
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

echo "nf-core/deepvariant native 4-node Nextflow baseline completed across 4 nodes"

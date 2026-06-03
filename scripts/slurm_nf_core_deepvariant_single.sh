#!/bin/bash
#SBATCH --job-name=deepvariant-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_deepvariant/slurm-%j-single.out
#SBATCH --error=runs/nf-core_deepvariant/slurm-%j-single.err

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
OUTDIR="$ROOT/runs/nf-core_deepvariant/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_deepvariant/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"
PODMAN_BASE="$RUN_DIR/podman-storage"

mkdir -p "$ROOT/runs/nf-core_deepvariant" "$DATADIR" "$RUN_DIR" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home"

TMP_ROOT="$WORKDIR/tmp"
PKGS_ROOT="$RUN_DIR/conda-pkgs"
mkdir -p "$TMP_ROOT" "$PKGS_ROOT" "$RUN_DIR/nextflow-conda-cache" "$RUN_DIR/podman-bin" "$PODMAN_BASE"/{xdg,root,run,tmp}
chmod 700 "$PODMAN_BASE/xdg"
export TMPDIR="$TMP_ROOT"
export NXF_TEMP="$TMP_ROOT"
export XDG_RUNTIME_DIR="$PODMAN_BASE/xdg"
export CONDA_PKGS_DIRS="$PKGS_ROOT"
export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$TMP_ROOT"
export MAMBA_YES=true
export MAMBA_ALWAYS_YES=true
export CONDA_ALWAYS_YES=true
cat > "$RUN_DIR/condarc" <<'EOF'
always_yes: true
auto_activate_base: false
channel_priority: flexible
channels:
  - conda-forge
  - bioconda
  - defaults
EOF
export CONDARC="$RUN_DIR/condarc"

PODMAN_REAL="$(command -v podman || true)"
if [ -z "$PODMAN_REAL" ]; then
  echo "ERROR: podman is not available on this compute node" >&2
  exit 1
fi
cat > "$RUN_DIR/podman-bin/podman" <<EOF
#!/usr/bin/env bash
exec "$PODMAN_REAL" --storage-driver vfs --root "$PODMAN_BASE/root" --runroot "$PODMAN_BASE/run" --tmpdir "$PODMAN_BASE/tmp" "\$@"
EOF
chmod +x "$RUN_DIR/podman-bin/podman"

cat > "$RUN_DIR/deepvariant_ares_override.config" <<EOF
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

remote_size() {
  local url="$1"
  curl -sIL --fail "$url" \
    | awk 'tolower($1) == "content-length:" { size=$2 } END { gsub("\r", "", size); print size }'
}

download_if_missing() {
  local url="$1"
  local dest="$2"
  local tmp="${dest}.part"
  local expected actual attempt

  expected="$(remote_size "$url" || true)"
  actual="0"
  if [ -s "$dest" ]; then
    actual="$(stat -c '%s' "$dest")"
  fi
  if [ -n "$expected" ] && [ "$actual" = "$expected" ]; then
    return 0
  fi
  if [ -z "$expected" ] && [ -s "$dest" ]; then
    return 0
  fi

  if [ -s "$dest" ] && [ ! -s "$tmp" ]; then
    mv "$dest" "$tmp"
  fi
  if [ -n "$expected" ] && [ -s "$tmp" ] && [ "$(stat -c '%s' "$tmp")" -gt "$expected" ]; then
    rm -f "$tmp"
  fi

  for attempt in $(seq 1 20); do
    if curl -L --fail --retry 8 --retry-delay 20 --retry-all-errors --continue-at - -o "$tmp" "$url"; then
      actual="$(stat -c '%s' "$tmp")"
      if [ -z "$expected" ] || [ "$actual" = "$expected" ]; then
        mv "$tmp" "$dest"
        return 0
      fi
      echo "download size mismatch for $url: got $actual expected $expected" >&2
    fi
    sleep 30
  done

  echo "ERROR: failed to download and validate $url -> $dest" >&2
  return 1
}

BAM="$DATADIR/NIST-hg001-7001-ready.bam"
BAI="$DATADIR/NIST-hg001-7001-ready.bam.bai"
BED="$DATADIR/HG001_GRCh37_1_22_v4.2.1_benchmark.bed"
FASTA_GZ="$DATADIR/Homo_sapiens.GRCh37.dna.primary_assembly.fa.gz"
FASTA="$DATADIR/Homo_sapiens.GRCh37.dna.primary_assembly.fa"

download_if_missing "https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/data/NA12878/Nebraska_NA12878_HG001_TruSeq_Exome/NIST-hg001-7001-ready.bam" "$BAM"
download_if_missing "https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/data/NA12878/Nebraska_NA12878_HG001_TruSeq_Exome/NIST-hg001-7001-ready.bam.bai" "$BAI"
download_if_missing "https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/release/NA12878_HG001/latest/GRCh37/HG001_GRCh37_1_22_v4.2.1_benchmark.bed" "$BED"
download_if_missing "https://ftp.ensembl.org/pub/grch37/current/fasta/homo_sapiens/dna/Homo_sapiens.GRCh37.dna.primary_assembly.fa.gz" "$FASTA_GZ"

gzip -t "$FASTA_GZ"
if [ ! -s "$FASTA" ] || [ "$FASTA" -ot "$FASTA_GZ" ]; then
  gunzip -c "$FASTA_GZ" > "$FASTA.tmp"
  test -s "$FASTA.tmp"
  mv "$FASTA.tmp" "$FASTA"
fi

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_OFFLINE=true
export NXF_VER=22.10.8
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export PATH="$RUN_DIR/podman-bin:$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

cd "$(dirname "$OUTDIR")"
nextflow run "$REPO" \
  -profile standard \
  -c "$ROOT/config/nextflow_ares_local_podman.config" \
  -c "$RUN_DIR/deepvariant_ares_override.config" \
  -work-dir "$WORKDIR" \
  --bam "$BAM" \
  --bed "$BED" \
  --fasta "$FASTA" \
  --exome \
  --outdir "$OUTDIR"

if ! find "$OUTDIR/pipeline_info" -maxdepth 2 -type f -name 'nf-core*trace.txt' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR/Documentation" -type f -name 'pipeline_report.html' -size +1000 | grep -q .; then
  echo "ERROR: missing non-trivial DeepVariant pipeline HTML report" >&2
  exit 1
fi

if ! find "$OUTDIR" -maxdepth 1 -type f -name '*.vcf' -size +0 | grep -q .; then
  echo "ERROR: missing non-empty DeepVariant VCF output" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 5 ]; then
  echo "ERROR: too few non-empty outputs for DeepVariant baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/deepvariant single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"

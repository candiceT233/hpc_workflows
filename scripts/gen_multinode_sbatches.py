#!/usr/bin/env python3
"""Generate multinode SBATCH scripts by transforming small_4node templates.

For each (workflow, node_count, profiler) tuple, copies the canonical
small_4node/run_slurm.<profiler>.sh into a new multinode_<N>node_<profiler>/
directory, applies the substitutions needed for an honest N-node Class C
Nextflow run, and copies any per-workflow fix*.config files along with it.

Hard correctness rules applied (per MULTINODE_AUDIT_2026-05-18.md profiling_campaign.prompt):
- Rule 1 (Class C): --nodes=N parent + slurm_pinned.config
- Rule 2: log hostnames in env_at_start
- Rule 3: pinned libmonitor.so path (existing scripts already use it)
- Rule 4: per-workflow DATALIFE_FILE_PATTERNS (preserved from source)
- Rule 7: never bundle profilers (separate directories per profiler)
- Rule 8: multinode_<N>node_<profiler>/ naming
- Rule 10: NXF_MAX_FORKS = SLURM_NNODES * 4
"""
import os
import re
import shutil
import sys
from pathlib import Path

WORKFLOW_ROOT = Path("/mnt/common/mtang11/hpc_workflows")

# Phase 1 (≤8n) per prompt: (workflow, nodes, wall_minutes)
# wall padded +50% from the §16 budget (TIME header in script).
PHASE1 = [
    ("nf-core_hic",                 4,  30),
    ("nf-core_funcscan",            4,  90),
    ("nf-core_cutandrun",           5,  45),
    ("nf-core_detaxizer",           5,  30),
    ("nf-core_methylseq",           6,  30),
    ("nf-core_pathogensurveillance",6,  60),
    ("nf-core_quantms",             6,  45),
    ("nf-core_fetchngs",            7,  30),
    ("nf-core_nascent",             8,  90),
]

# Phase 2 (10-15n) — workflows whose sustained parallelism justifies these counts.
PHASE2 = [
    ("nf-core_mag",                 10, 45),
    ("nf-core_ampliseq",            11, 90),
    ("nf-core_taxprofiler",         11, 90),
    ("nf-core_atacseq",             12, 60),
    ("nf-core_rnaseq",              14, 60),
    ("nf-core_viralrecon",          15, 60),
]

# Phase 3 (18n) — single workflow at sustained-parallelism sweet spot.
PHASE3 = [
    ("nf-core_smrnaseq",            18, 45),
]


def fmt_time(minutes_with_padding):
    h, m = divmod(minutes_with_padding, 60)
    return f"{h:02d}:{m:02d}:00"


def pick_src(wf_dir: Path, profiler: str) -> Path:
    """Pick the freshest existing template script for (workflow, profiler)."""
    candidates = [
        wf_dir / f"small_4node/run_slurm.{profiler}.fix1.sh",
        wf_dir / f"small_4node/run_slurm.{profiler}.sh",
    ]
    for c in candidates:
        if c.exists():
            return c
    raise FileNotFoundError(
        f"No template found for {wf_dir.name}/{profiler}. Tried: {candidates}"
    )


def transform(src_text: str, wf: str, n: int, profiler: str, wall: str) -> str:
    """Apply substitutions to convert small_4node template to multinode_<N>node_<profiler>."""
    old_dir = "small_4node"
    new_dir = f"multinode_{n}node_{profiler}"
    old_tag = f"{profiler}_4node"
    new_tag = f"{profiler}_{n}node"

    text = src_text
    # Update paths from small_4node -> multinode_Nnode_<profiler>. Catches both
    # mid-path (/small_4node/) and trailing (=...small_4node end-of-line) forms.
    text = re.sub(r"\bsmall_4node\b", new_dir, text)

    # Tighten DATALIFE_FILE_PATTERNS to avoid greedy matches that caused the
    # recursive-trace-filename explosion (config* matching libmonitor's own
    # trace files in rsd_5n_da's 100-suffix filename run). The new libmonitor
    # (post-6ff35639) also skips files inside $DATALIFE_OUTPUT_PATH by path
    # prefix, but tightening here removes a class of greedy patterns that
    # exist in legacy templates.
    pattern_subs = [
        # config* → only YAML / JSON / TSV
        (r"'config\*", "'config.yaml,config.yml,config.json"),
        (r",config\*", ",config.yaml,config.yml,config.json"),
        # samples* → only known sample sheet extensions
        (r"samples\*", "samples.tsv,samples.csv,samples.yaml"),
        # units* → only TSV/CSV
        (r"units\*", "units.tsv,units.csv"),
    ]
    for pat, repl in pattern_subs:
        text = re.sub(pat, repl, text)
    # SBATCH job name: short form
    text = re.sub(
        r"#SBATCH --job-name=\S+",
        f"#SBATCH --job-name={wf[:14].replace('nf-core_', 'nfc_')}_{n}n_{profiler[:2]}",
        text,
    )
    # --nodes=1 -> --nodes=N (parent reserves N nodes; slurm_pinned.config pins children)
    text = re.sub(r"#SBATCH --nodes=1\b", f"#SBATCH --nodes={n}", text)
    # --ntasks=1 -> --ntasks-per-node=1. Without this swap SLURM interprets
    # '--nodes=N --ntasks=1' as 1 task across N nodes, warns, and silently
    # downgrades to nodes=1 — the exact bug Rule 1 audits against.
    text = re.sub(r"#SBATCH --ntasks=1\b", "#SBATCH --ntasks-per-node=1", text)
    # Walltime
    text = re.sub(r"#SBATCH --time=\S+", f"#SBATCH --time={wall}", text)
    # Tag rename so trace dirs / log files reflect the new node count
    text = text.replace(f"TAG={old_tag}", f"TAG={new_tag}")
    # NXF_MAX_FORKS: Rule 10 wants 2-4× nodes; we use 4×.
    text = re.sub(
        r"export NXF_MAX_FORKS=\S+",
        "export NXF_MAX_FORKS=$((SLURM_NNODES * 4))",
        text,
    )
    # Slurm executor config: switch to the pinned variant so children land on
    # the parent's allocated nodes (Class C compliance). DataLife runs use the
    # datalife-specific pinned config, which ALSO injects LD_PRELOAD + DataLife
    # env into each child task's beforeScript so the science tools (not just the
    # JVM driver) are traced.
    pinned = "slurm_pinned_datalife.config" if profiler == "datalife" else "slurm_pinned.config"
    text = text.replace("nf-core_shared/slurm.config", f"nf-core_shared/{pinned}")

    if profiler == "datalife":
        # 1) export DATALIFE_LIB so slurm_pinned_datalife.config's System.getenv
        #    can bake it into each child task's beforeScript.
        text = re.sub(r"^DATALIFE_LIB=", "export DATALIFE_LIB=", text, flags=re.M)
        # 2) DATALIFE_JSON_OUTPUT=1 → emit *.r_blk_trace.json (schema verification
        #    reads) instead of legacy *_r_stat text. Insert after the
        #    DATALIFE_FILE_PATTERNS export.
        if "DATALIFE_JSON_OUTPUT" not in text:
            text = re.sub(
                r"(export DATALIFE_FILE_PATTERNS=[^\n]+\n)",
                r"\1export DATALIFE_JSON_OUTPUT=1\n",
                text, count=1,
            )
    # NODE_BUDGET=4 -> NODE_BUDGET=$SLURM_NNODES (the timing-log line)
    text = re.sub(
        r'NODE_BUDGET=4 \(NXF_MAX_FORKS=',
        r'NODE_BUDGET=$SLURM_NNODES (NXF_MAX_FORKS=',
        text,
    )

    # Inject env_at_start.txt + hostname log (Rule 2). Insert right after the
    # mkdir line so dirs exist. We hook on the existing mkdir for $RUNDIR/logs.
    env_block = f'''
# Rule 2: log node spread proves multi-node placement.
{{
  echo "PROFILER={profiler}"
  echo "Nodes=$SLURM_NNODES Tasks/node=$SLURM_NTASKS_PER_NODE"
  echo "Hostnames: $(scontrol show hostnames $SLURM_NODELIST | tr '\\n' ' ')"
  echo "SLURM_JOB_NODELIST=$SLURM_JOB_NODELIST"
  echo "NXF_MAX_FORKS=$NXF_MAX_FORKS"
'''
    if profiler == "datalife":
        env_block += '''  echo "DATALIFE_LIB_MD5=$(md5sum $DATALIFE_LIB | awk '{print $1}')"
  echo "DATALIFE_OUTPUT_PATH=$DATALIFE_OUTPUT_PATH"
  echo "DATALIFE_FILE_PATTERNS=$DATALIFE_FILE_PATTERNS"
'''
    elif profiler == "darshan":
        env_block += '''  echo "DARSHAN_LIB=$DARSHAN_LIB"
  echo "DARSHAN_LOG_DIR=$DARSHAN_LOG_DIR"
  echo "DARSHAN_MODMEM=$DARSHAN_MODMEM"
  echo "DARSHAN_EXCLUDE_DIRS=$DARSHAN_EXCLUDE_DIRS"
'''
    env_block += '} > "$RUNDIR/logs/env_at_start_${TAG}.txt"\n'

    # For Darshan: bump per-module memory ceiling so high-I/O processes
    # (deeparg downloads, big java/python invocations) don't truncate with
    # "POSIX module contains incomplete data". Exclude noisy proc/sys/conda
    # paths to keep that budget for real workflow I/O.
    if profiler == "darshan":
        darshan_extra = '''export DARSHAN_MODMEM=2048
export DARSHAN_EXCLUDE_DIRS=/proc:/sys:/dev:/etc:/usr:/var:/tmp:$NXF_CONDA_CACHEDIR:$NXF_HOME
'''
        # Insert after the existing DARSHAN_LOG_DIR= export
        if 'export DARSHAN_LOG_DIR=' in text:
            text = re.sub(
                r'(export DARSHAN_LOG_DIR=[^\n]+\n)',
                r'\1' + darshan_extra,
                text,
                count=1,
            )

    # Anchor: insert just before `cd "$RUNDIR"` so $RUNDIR & friends are set.
    if 'cd "$RUNDIR"' in text:
        text = text.replace('cd "$RUNDIR"', env_block + '\ncd "$RUNDIR"', 1)
    else:
        # Fallback: append before the first START= line
        text = text.replace('START=$(date +%s)', env_block + '\nSTART=$(date +%s)', 1)

    return text


def author(wf: str, n: int, wall_min: int) -> list[str]:
    wf_dir = WORKFLOW_ROOT / "runs" / wf
    walltime = fmt_time(wall_min * 3 // 2)  # +50% headroom
    written = []
    for profiler in ("datalife", "darshan"):
        src = pick_src(wf_dir, profiler)
        dst_dir = wf_dir / f"multinode_{n}node_{profiler}"
        dst_dir.mkdir(parents=True, exist_ok=True)
        (dst_dir / "logs").mkdir(exist_ok=True)
        # Copy per-workflow fix*.config files
        for cfg in (wf_dir / "small_4node").glob("*.config"):
            shutil.copy2(cfg, dst_dir / cfg.name)
        dst = dst_dir / "run_slurm.sh"
        new_text = transform(src.read_text(), wf, n, profiler, walltime)
        dst.write_text(new_text)
        os.chmod(dst, 0o755)
        written.append(str(dst.relative_to(WORKFLOW_ROOT)))
    return written


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--phase", default="1", help="1, 2, 3, or 1,2,3 for combined")
    args = ap.parse_args()

    phase_map = {"1": PHASE1, "2": PHASE2, "3": PHASE3}
    selected = []
    for p in args.phase.split(","):
        p = p.strip()
        if p not in phase_map:
            print(f"unknown phase: {p}; valid: 1,2,3", file=sys.stderr)
            sys.exit(1)
        selected.extend(phase_map[p])

    print(f"Generating {len(selected)} workflows × 2 profilers = {len(selected)*2} scripts")
    for wf, n, wall in selected:
        try:
            paths = author(wf, n, wall)
            for p in paths:
                print(f"  wrote {p}")
        except Exception as e:
            print(f"  ERROR {wf}: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()

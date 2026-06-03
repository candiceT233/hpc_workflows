#!/usr/bin/env bash
#SBATCH --job-name=deepdrivemd-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/DeepDriveMD-pipeline/slurm-%j-single.out
#SBATCH --error=runs/DeepDriveMD-pipeline/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
REPO="$ROOT/repos/DeepDriveMD-pipeline"
VENV="$ROOT/tools/deepdrivemd-venv"
RUN_LABEL="${DEEPMD_RUN_LABEL:-single}"
DEEPMD_TITLE="${DEEPMD_TITLE:-BBA DeepDriveMD Ares single-node baseline}"
DEEPMD_RESOURCE="${DEEPMD_RESOURCE:-local.localhost}"
DEEPMD_QUEUE="${DEEPMD_QUEUE:-local}"
DEEPMD_SCHEMA="${DEEPMD_SCHEMA:-local}"
DEEPMD_PROJECT="${DEEPMD_PROJECT:-none}"
DEEPMD_NUM_TASKS="${DEEPMD_NUM_TASKS:-4}"
DEEPMD_EXPECT_TASKS="${DEEPMD_EXPECT_TASKS:-$DEEPMD_NUM_TASKS}"
DEEPMD_LAST_N_H5="${DEEPMD_LAST_N_H5:-$DEEPMD_NUM_TASKS}"
DEEPMD_SKLEARN_JOBS="${DEEPMD_SKLEARN_JOBS:-4}"
DEEPMD_CPUS_PER_NODE="${DEEPMD_CPUS_PER_NODE:-${SLURM_CPUS_ON_NODE:-40}}"
RUN_DIR="$ROOT/runs/DeepDriveMD-pipeline/${RUN_LABEL}-${SLURM_JOB_ID:-manual}"
CFG="$RUN_DIR/deepdrivemd.yaml"
EXP_DIR="$RUN_DIR/experiment"

mkdir -p "$RUN_DIR"
cd "$ROOT"

source "$VENV/bin/activate"
export PYTHONPATH="$REPO:${PYTHONPATH:-}"
export WANDB_MODE=offline
export OMP_NUM_THREADS=4
unset CUDA_VISIBLE_DEVICES || true

DEEPMD_STAGE_PROFILE_PRE_EXEC=""
DEEPMD_MD_STAGE_PROFILE_PRE_EXEC=""
if [ -n "${DEEPMD_PROFILE_MODE:-}" ]; then
  case "$DEEPMD_PROFILE_MODE" in
    datalife)
      : "${DEEPMD_PROFILE_TRACE_DIR:?DEEPMD_PROFILE_TRACE_DIR is required for datalife profiling}"
      : "${DEEPMD_PROFILE_LIB:?DEEPMD_PROFILE_LIB is required for datalife profiling}"
      DEEPMD_PROFILE_FILE_PATTERNS="${DEEPMD_PROFILE_FILE_PATTERNS:-*.pdb,*.h5,*.dcd,*.log,*.pt,*.yaml,*.txt}"
      DEEPMD_STAGE_PROFILE_PRE_EXEC=$(cat <<EOF
  - export DATALIFE_OUTPUT_PATH=$DEEPMD_PROFILE_TRACE_DIR
  - export DATALIFE_FILE_PATTERNS=$DEEPMD_PROFILE_FILE_PATTERNS
  - export LD_PRELOAD=$DEEPMD_PROFILE_LIB
EOF
)
      # DataLife's LD_PRELOAD corrupts MDAnalysis' PDB auto-open path in
      # the OpenMM stage. Profile downstream stages that read/write MD outputs.
      DEEPMD_MD_STAGE_PROFILE_PRE_EXEC=""
      ;;
    darshan)
      : "${DEEPMD_PROFILE_TRACE_DIR:?DEEPMD_PROFILE_TRACE_DIR is required for darshan profiling}"
      : "${DEEPMD_PROFILE_LIB:?DEEPMD_PROFILE_LIB is required for darshan profiling}"
      DEEPMD_STAGE_PROFILE_PRE_EXEC=$(cat <<EOF
  - export DARSHAN_ENABLE_NONMPI=1
  - export DARSHAN_LOG_DIR_PATH=$DEEPMD_PROFILE_TRACE_DIR
  - export LD_PRELOAD=$DEEPMD_PROFILE_LIB
EOF
)
      DEEPMD_MD_STAGE_PROFILE_PRE_EXEC="$DEEPMD_STAGE_PROFILE_PRE_EXEC"
      ;;
    *)
      echo "ERROR: unsupported DEEPMD_PROFILE_MODE=$DEEPMD_PROFILE_MODE" >&2
      exit 2
      ;;
  esac
fi

rm -rf "$EXP_DIR"

cat > "$CFG" <<YAML
title: $DEEPMD_TITLE
resource: $DEEPMD_RESOURCE
queue: $DEEPMD_QUEUE
schema_: $DEEPMD_SCHEMA
project: $DEEPMD_PROJECT
walltime_min: 2880
max_iteration: 1
cpus_per_node: $DEEPMD_CPUS_PER_NODE
gpus_per_node: 0
hardware_threads_per_cpu: 1
experiment_directory: $EXP_DIR
node_local_path: null
molecular_dynamics_stage:
  pre_exec:
  - export PYTHONPATH=$REPO:\${PYTHONPATH:-}
  - export OMP_NUM_THREADS=4
$DEEPMD_MD_STAGE_PROFILE_PRE_EXEC
  executable: $VENV/bin/python
  arguments:
  - $REPO/deepdrivemd/sim/openmm/run_openmm.py
  cpu_reqs:
    processes: 1
    process_type: null
    threads_per_process: 4
    thread_type: OpenMP
  gpu_reqs:
    processes: 0
    process_type: null
    threads_per_process: 0
    thread_type: null
  num_tasks: $DEEPMD_NUM_TASKS
  task_config:
    experiment_directory: set_by_deepdrivemd
    stage_idx: 0
    task_idx: 0
    output_path: set_by_deepdrivemd
    node_local_path: set_by_deepdrivemd
    pdb_file: set_by_deepdrivemd
    initial_pdb_dir: $REPO/data/bba
    solvent_type: implicit
    top_suffix: null
    simulation_length_ns: 0.02
    report_interval_ps: 1.0
    dt_ps: 0.002
    temperature_kelvin: 310.0
    heat_bath_friction_coef: 1.0
    wrap: false
    reference_pdb_file: $REPO/data/bba/1FME-folded.pdb
    openmm_selection:
    - CA
    mda_selection: protein and name CA
    threshold: 8.0
    contact_map: false
    point_cloud: true
    fraction_of_contacts: true
    in_memory: true
aggregation_stage:
  pre_exec: []
  executable: ''
  arguments: []
  cpu_reqs:
    processes: 1
    process_type: null
    threads_per_process: 1
    thread_type: null
  gpu_reqs:
    processes: 0
    process_type: null
    threads_per_process: 0
    thread_type: null
  skip_aggregation: true
  task_config:
    experiment_directory: set_by_deepdrivemd
    stage_idx: 0
    task_idx: 0
    output_path: set_by_deepdrivemd
    node_local_path: set_by_deepdrivemd
machine_learning_stage:
  pre_exec:
  - export PYTHONPATH=$REPO:\${PYTHONPATH:-}
  - export WANDB_MODE=offline
  - export OMP_NUM_THREADS=4
$DEEPMD_STAGE_PROFILE_PRE_EXEC
  executable: $VENV/bin/python
  arguments:
  - $REPO/deepdrivemd/models/aae/train.py
  cpu_reqs:
    processes: 1
    process_type: null
    threads_per_process: 4
    thread_type: OpenMP
  gpu_reqs:
    processes: 0
    process_type: null
    threads_per_process: 0
    thread_type: null
  retrain_freq: 1
  task_config:
    experiment_directory: set_by_deepdrivemd
    stage_idx: 0
    task_idx: 0
    output_path: set_by_deepdrivemd
    node_local_path: set_by_deepdrivemd
    model_tag: set_by_deepdrivemd
    init_weights_path: $REPO/data/bba/epoch-130-20201203-150026.pt
    last_n_h5_files: $DEEPMD_LAST_N_H5
    k_random_old_h5_files: 0
    dataset_name: point_cloud
    rmsd_name: rmsd
    fnc_name: fnc
    num_points: 28
    num_features: 0
    initial_epochs: 1
    epochs: 1
    batch_size: 8
    optimizer_name: Adam
    optimizer_lr: 0.0001
    latent_dim: 10
    encoder_filters:
    - 64
    - 128
    - 256
    - 256
    - 512
    encoder_kernel_sizes:
    - 5
    - 3
    - 3
    - 1
    - 1
    generator_filters:
    - 64
    - 128
    - 512
    - 1024
    discriminator_filters:
    - 512
    - 512
    - 128
    - 64
    encoder_relu_slope: 0.0
    generator_relu_slope: 0.0
    discriminator_relu_slope: 0.0
    use_encoder_bias: true
    use_generator_bias: true
    use_discriminator_bias: true
    noise_mu: 0.0
    noise_std: 1.0
    lambda_rec: 0.5
    lambda_gp: 10.0
    embed_interval: 1
    tsne_interval: 5
    sample_interval: 20
    num_data_workers: 0
    dataset_location: storage
    wandb_project_name: null
model_selection_stage:
  pre_exec:
  - export PYTHONPATH=$REPO:\${PYTHONPATH:-}
$DEEPMD_STAGE_PROFILE_PRE_EXEC
  executable: $VENV/bin/python
  arguments:
  - $REPO/deepdrivemd/selection/latest/select_model.py
  cpu_reqs:
    processes: 1
    process_type: null
    threads_per_process: 1
    thread_type: null
  gpu_reqs:
    processes: 0
    process_type: null
    threads_per_process: 0
    thread_type: null
  task_config:
    experiment_directory: set_by_deepdrivemd
    stage_idx: 0
    task_idx: 0
    output_path: set_by_deepdrivemd
    node_local_path: set_by_deepdrivemd
    retrain_freq: 1
    checkpoint_dir: checkpoint
    checkpoint_suffix: .pt
agent_stage:
  pre_exec:
  - export PYTHONPATH=$REPO:\${PYTHONPATH:-}
  - export OMP_NUM_THREADS=4
$DEEPMD_STAGE_PROFILE_PRE_EXEC
  executable: $VENV/bin/python
  arguments:
  - $REPO/deepdrivemd/agents/lof/lof.py
  cpu_reqs:
    processes: 1
    process_type: null
    threads_per_process: 4
    thread_type: OpenMP
  gpu_reqs:
    processes: 0
    process_type: null
    threads_per_process: 0
    thread_type: null
  task_config:
    experiment_directory: set_by_deepdrivemd
    stage_idx: 0
    task_idx: 0
    output_path: set_by_deepdrivemd
    node_local_path: set_by_deepdrivemd
    num_intrinsic_outliers: 2
    num_extrinsic_outliers: 2
    intrinsic_score: lof
    extrinsic_score: null
    n_traj_frames: 20
    n_most_recent_h5_files: $DEEPMD_LAST_N_H5
    k_random_old_h5_files: 0
    sklearn_num_jobs: $DEEPMD_SKLEARN_JOBS
    model_type: AAE3d
    inference_batch_size: 8
YAML

python -m deepdrivemd.deepdrivemd -c "$CFG"

find "$EXP_DIR/molecular_dynamics_runs" -name '*.h5' -size +0c | sort > "$RUN_DIR/md_h5_files.txt"
find "$EXP_DIR/molecular_dynamics_runs" -name '*.dcd' -size +0c | sort > "$RUN_DIR/md_dcd_files.txt"
find "$EXP_DIR/molecular_dynamics_runs" -name '*.log' -size +0c | sort > "$RUN_DIR/md_log_files.txt"
find "$EXP_DIR/machine_learning_runs" -name '*.pt' -size +0c | sort > "$RUN_DIR/ml_checkpoint_files.txt"
find "$EXP_DIR/model_selection_runs" -name '*.json' -size +0c | sort > "$RUN_DIR/model_selection_json.txt"
find "$EXP_DIR/agent_runs" -name '*.json' -size +0c | sort > "$RUN_DIR/agent_json.txt"

test "$(wc -l < "$RUN_DIR/md_h5_files.txt")" -ge "$DEEPMD_EXPECT_TASKS"
test "$(wc -l < "$RUN_DIR/md_dcd_files.txt")" -ge "$DEEPMD_EXPECT_TASKS"
test "$(wc -l < "$RUN_DIR/md_log_files.txt")" -ge "$DEEPMD_EXPECT_TASKS"
test "$(wc -l < "$RUN_DIR/ml_checkpoint_files.txt")" -ge 1
test "$(wc -l < "$RUN_DIR/model_selection_json.txt")" -ge 1
test "$(wc -l < "$RUN_DIR/agent_json.txt")" -ge 1

du -sh "$EXP_DIR"
echo "DeepDriveMD $RUN_LABEL native RADICAL-EnTK baseline completed"

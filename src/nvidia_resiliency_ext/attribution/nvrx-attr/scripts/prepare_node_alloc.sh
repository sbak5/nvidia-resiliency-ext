#!/bin/bash
# prepare_node_alloc.sh
# Submit fault-injection experiments from a prioritized pool, 2 jobs at a time,
# waiting for each pair to complete before submitting the next pair.
# This limits peak filesystem stress to 2 concurrent jobs while still covering
# the full experiment matrix end-to-end in one unattended run.
#
# Pool ordering: GPU-related faults first (higher attribution coverage priority),
# then crash faults, Python-level hangs, and signal-based faults.
# Each tier covers node counts 2→4→8 and sweeps rank-0, rank-1, mid, and last.
#
# Usage:
#   bash scripts/prepare_node_alloc.sh
#   TIME=00:45:00 NODES_MAX=4 bash scripts/prepare_node_alloc.sh
#
# Override POOL (space-separated FAULT_TYPE:RANK:ITER:NODES) to run a custom set.

set -euo pipefail

ACCOUNT="${ACCOUNT:-root}"
PARTITION="${PARTITION:-gb-nvl-134-135}"
GPUS_PER_NODE="${GPUS_PER_NODE:-4}"
TIME="${TIME:-00:30:00}"
BATCH_SIZE="${BATCH_SIZE:-2}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
BASE_EXPERIMENTS_DIR="${BASE_EXPERIMENTS_DIR:-/home/sbak/experiments/llama4-scout-gb200}"

# ---------------------------------------------------------------------------
# Fault pool — ordered by priority (GPU-related first, then crash, then other)
# Format: FAULT_TYPE:RANK:ITER:NODES
#
# Rank coverage per node count (4 GPUs/node):
#   2 nodes →  8 ranks:  rank-0, rank-1, mid=4,  last=7
#   4 nodes → 16 ranks:  rank-0, rank-1, mid=8,  last=15
#   8 nodes → 32 ranks:  rank-0, rank-1, mid=16, last=31
# ---------------------------------------------------------------------------
DEFAULT_POOL="
GPU_SLEEP:1:5:2   GPU_SLEEP:0:5:2
GPU_SLEEP:4:5:2   GPU_SLEEP:7:5:2
GPU_SLEEP:1:5:4   GPU_SLEEP:0:5:4
GPU_SLEEP:8:5:4   GPU_SLEEP:15:5:4
GPU_SLEEP:1:5:8   GPU_SLEEP:0:5:8
GPU_SLEEP:16:5:8  GPU_SLEEP:31:5:8
GPU_ERROR:1:5:2   GPU_ERROR:0:5:2
GPU_ERROR:1:5:4   GPU_ERROR:0:5:4
GPU_ERROR:1:5:8   GPU_ERROR:0:5:8
SIGKILL:1:5:2     SIGKILL:0:5:2
SIGKILL:1:5:4     SIGKILL:1:5:8
SEGFAULT:1:5:2    SEGFAULT:0:5:2
SEGFAULT:1:5:4    OS_ABORT:1:5:2
LOCK_GIL:1:5:2    LOCK_GIL:0:5:2
WORKLOAD_EXC:1:5:2 ASYNC_EXC:1:5:2
SIGTERM:1:5:2     SIGINT:1:5:2
SIGSTOP:1:5:2     SIGNAL_EXC:1:5:2
"

# Flatten pool into an array (strips comments and blank lines)
POOL=(${POOL:-$DEFAULT_POOL})

SBATCH_SCRIPT="$(dirname "$0")/launch.sbatch"
SESSION_TAG="$(date +%Y%m%d_%H%M%S)"
SESSION_DIR="${BASE_EXPERIMENTS_DIR}/fault_injection/${SESSION_TAG}"
TRACKING_FILE="${SESSION_DIR}/experiments.tsv"

mkdir -p "${SESSION_DIR}"
printf "JOB_ID\tFAULT_TYPE\tRANK\tITER\tNODES\tEXPERIMENT_DIR\n" > "${TRACKING_FILE}"

TOTAL=${#POOL[@]}
echo ">>> Fault-injection pool: ${TOTAL} experiments, ${BATCH_SIZE} at a time"
echo ">>> Partition: ${PARTITION}  GPUs/node: ${GPUS_PER_NODE}  Time: ${TIME}"
echo ">>> Session:   ${SESSION_DIR}"
echo ">>> Tracking:  ${TRACKING_FILE}"
echo ""

submit_one() {
    local EXPERIMENT="$1"
    IFS=':' read -r FAULT_TYPE RANK ITER NODES <<< "${EXPERIMENT}"

    local EXPERIMENT_DIR="${SESSION_DIR}/n${NODES}_${FAULT_TYPE}_r${RANK}_i${ITER}"
    mkdir -p "${EXPERIMENT_DIR}/logs/slurm"
    mkdir -p "${EXPERIMENT_DIR}/checkpoints"
    mkdir -p "${EXPERIMENT_DIR}/tensorboard"

    local JOB_ID
    JOB_ID=$(sbatch \
        --account="${ACCOUNT}" \
        --partition="${PARTITION}" \
        --nodes="${NODES}" \
        --ntasks-per-node="${GPUS_PER_NODE}" \
        --gpus-per-node="${GPUS_PER_NODE}" \
        --time="${TIME}" \
        --exclusive \
        --mem=0 \
        --output="${EXPERIMENT_DIR}/logs/slurm/%j.launch.out" \
        --error="${EXPERIMENT_DIR}/logs/slurm/%j.launch.err" \
        --export=ALL,FAULT_TYPE="${FAULT_TYPE}",FAULT_RANK="${RANK}",FAULT_AT_ITER="${ITER}",GPUS_PER_NODE="${GPUS_PER_NODE}",EXPERIMENT_DIR="${EXPERIMENT_DIR}",BASE_EXPERIMENTS_DIR="${BASE_EXPERIMENTS_DIR}" \
        --parsable \
        "${SBATCH_SCRIPT}")

    # Print to stderr so callers using $(...) capture only the job ID on stdout
    printf "  submitted: %s rank=%-2s iter=%s nodes=%s -> job=%s\n" \
        "${FAULT_TYPE}" "${RANK}" "${ITER}" "${NODES}" "${JOB_ID}" >&2
    printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
        "${JOB_ID}" "${FAULT_TYPE}" "${RANK}" "${ITER}" "${NODES}" "${EXPERIMENT_DIR}" \
        >> "${TRACKING_FILE}"
    echo "${JOB_ID}"   # only the bare job ID goes to stdout
}

wait_for_jobs() {
    local JOB_LIST="$1"
    local LABEL="$2"
    printf "  waiting for %s (%s) ..." "${LABEL}" "${JOB_LIST}"
    while true; do
        local REMAINING
        # squeue returns non-zero for unknown job IDs on some SLURM versions;
        # || echo 0 prevents set -e from aborting the script when jobs leave the queue.
        REMAINING=$(squeue -j "${JOB_LIST}" --noheader 2>/dev/null | wc -l || echo 0)
        if [[ "${REMAINING}" -eq 0 ]]; then
            echo " done."
            break
        fi
        printf " %ds" "${POLL_INTERVAL}"
        sleep "${POLL_INTERVAL}"
    done
}

ALL_SUBMITTED_JOBS=()
BATCH_NUM=0
i=0

while [[ $i -lt ${TOTAL} ]]; do
    BATCH_NUM=$((BATCH_NUM + 1))
    BATCH_END=$((i + BATCH_SIZE))
    [[ ${BATCH_END} -gt ${TOTAL} ]] && BATCH_END=${TOTAL}
    BATCH_COUNT=$((BATCH_END - i))

    echo ">>> Batch ${BATCH_NUM}: experiments $((i+1))–${BATCH_END} of ${TOTAL}"

    BATCH_JOB_IDS=()
    for ((b=i; b<BATCH_END; b++)); do
        JID=$(submit_one "${POOL[$b]}")
        BATCH_JOB_IDS+=("${JID}")
        ALL_SUBMITTED_JOBS+=("${JID}")
    done

    BATCH_LIST=$(IFS=','; echo "${BATCH_JOB_IDS[*]}")
    BATCH_LABEL=$(printf "%s " "${POOL[@]:$i:$BATCH_COUNT}")
    wait_for_jobs "${BATCH_LIST}" "${BATCH_LABEL% }"

    i=${BATCH_END}
done

echo ""
ALL_JOB_LIST=$(IFS=','; echo "${ALL_SUBMITTED_JOBS[*]}")
echo ">>> All ${TOTAL} experiments complete."
echo ">>> Session:  ${SESSION_DIR}"
echo ">>> Tracking: ${TRACKING_FILE}"
echo ""
echo ">>> Run analysis on all results:"
echo "    bash scripts/watch_and_analyze.sh '${TRACKING_FILE}'"

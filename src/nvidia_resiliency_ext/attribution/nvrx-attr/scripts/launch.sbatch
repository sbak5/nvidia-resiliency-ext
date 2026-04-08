#!/bin/bash

#SBATCH --account=root
#SBATCH --partition=gb-nvl-134-135
#SBATCH --time=00:30:00

#SBATCH --job-name=llama4-scout-gb200
#SBATCH --output=/home/sbak/experiments//llama4-scout-gb200/20260408_140621/2/logs/slurm/%j.launch.out
#SBATCH --error=/home/sbak/experiments//llama4-scout-gb200/20260408_140621/2/logs/slurm/%j.launch.err

#SBATCH --nodes=2
#SBATCH --ntasks-per-node=4
#SBATCH --gpus-per-node=4
#SBATCH --exclusive
#SBATCH --mem=0

log_msg() {
    local msg="$1"
    UNIX_DATETIME=$(date +%s)
    HUMAN_DATETIME=$(date -d "@$UNIX_DATETIME" '+%Y-%m-%d %H:%M:%S.%3N')
    echo ">>> ${msg} ${UNIX_DATETIME} (${HUMAN_DATETIME})"
}

log_msg "START SBATCH"
echo "Running on nodes: ${SLURM_NODELIST}"
export RITS_PLATFORM_TYPE=gb200
export RITS_GPUS_PER_NODE=4
export RITS_NVL_DOMAIN_SIZE=72
export NCCL_IB_DISABLE=0
export NCCL_NET_GDR_LEVEL=3
export RITS_CLUSTER_NAME=nvl72
export PYXIS_LOG_LEVEL=debug
export NCCL_IB_SL=1
export NCCL_IB_TIMEOUT=19
export UB_TIMEOUT=720
export CUDA_DEVICE_MAX_CONNECTIONS=1
export NVTE_FWD_LAYERNORM_SM_MARGIN=16
export NVTE_BWD_LAYERNORM_SM_MARGIN=16
export NCCL_P2P_NET_CHUNKSIZE=2097152
export NCCL_DEBUG=WARN
export PYTHONUNBUFFERED=1
export ONE_LOGGER_JOB_CATEGORY=test
export LOGLEVEL=DEBUG
export TORCHINDUCTOR_WORKER_START=fork
export TRITON_CACHE_DIR=/home/sbak/experiments//llama4-scout-gb200/triton_cache
export TORCHINDUCTOR_CACHE_DIR=/home/sbak/experiments//llama4-scout-gb200/inductor_cache
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
export TORCH_CPP_LOG_LEVEL=INFO
export TORCH_NCCL_TRACE_BUFFER_SIZE=2000
export TORCH_NCCL_RETHROW_CUDA_ERRORS=0
export TORCH_NCCL_ENABLE_MONITORING=1
export TORCH_NCCL_DUMP_ON_TIMEOUT=1
export TORCH_NCCL_LOG_CPP_STACK_ON_UNCLEAN_SHUTDOWN=0
export TORCH_NCCL_HEARTBEAT_TIMEOUT_SEC=20
export TORCH_DIST_INIT_BARRIER=0
export TORCH_INCLUDE_STACK_TRACE=0
export TORCH_INCLUDE_ONLY_ACTIVE=1
export TORCH_NCCL_EXTRA_DUMP_ON_EXEC=1
export MEGATRON_REPO_SNAPSHOT_BRANCH=rits-snapshot-a9b0c8d79e



mkdir -p /home/sbak/experiments//llama4-scout-gb200/datacache
mkdir -p /home/sbak/experiments//llama4-scout-gb200/20260408_140621/2/checkpoints
mkdir -p /home/sbak/experiments//llama4-scout-gb200/20260408_140621/2/tensorboard

: "${SLURM_RESTART_COUNT:=0}"

LOG_DIR=/home/sbak/experiments//llama4-scout-gb200/20260408_140621/2/logs
mkdir -p ${LOG_DIR}
echo "Writing logs to ${LOG_DIR}"
LOG_FILE_BASE="${LOG_DIR}/slurm/${SLURM_JOB_ID}.${SLURM_RESTART_COUNT}"

# Mounts
LUSTRE=/home:/home
SHARED_TMP=/home/sbak/tmp/${SLURM_JOB_ID}:/tmp
LOGS=/home/sbak/experiments//llama4-scout-gb200/20260408_140621/2/logs:/logs
MEGATRON_REPO=/home/sbak/megatron-lm-main:/megatron-lm_repo
DATACACHE=/home/sbak/experiments//llama4-scout-gb200/datacache:/datacache
CHECKPOINT_LOAD=/home/sbak/experiments//llama4-scout-gb200/20260408_140621/2/checkpoints:/checkpoint-load
CHECKPOINT_SAVE=/home/sbak/experiments//llama4-scout-gb200/20260408_140621/2/checkpoints:/checkpoint-save
TENSORBOARD=/home/sbak/experiments//llama4-scout-gb200/20260408_140621/2/tensorboard:/tensorboard
WORKSPACE=/home/sbak/tmp:/workspace
CONTAINER_MOUNTS=$LUSTRE,$SHARED_TMP,$LOGS,$MEGATRON_REPO,$DATACACHE,$CHECKPOINT_LOAD,$CHECKPOINT_SAVE,$TENSORBOARD,$WORKSPACE
mkdir -p /home/sbak/tmp/${SLURM_JOB_ID}
# single node setup
#--------------------------------

# all node setup
#--------------------------------
log_msg "START all_node_setup"
srun \
    --label \
    --container-mounts ${CONTAINER_MOUNTS} \
    --container-image /home/sbak/mcore_ci_040825.sqsh \
    --container-name ${SLURM_JOB_ID} \
    --container-workdir / \
    --exclusive \
    --error=${LOG_FILE_BASE}.0.all_node_setup.log \
    --output=${LOG_FILE_BASE}.0.all_node_setup.log \
    --ntasks-per-node=1 \
    --ntasks=2 \
    --kill-on-bad-exit=0 \
    --mpi=none \
    bash -c '
        export MEGATRON_PATH=`mktemp -d`
        echo "export MEGATRON_PATH=$MEGATRON_PATH" >> /tmp/.myenv_${SLURM_JOB_ID}.sh
        pushd $MEGATRON_PATH
        echo "Cloning Megatron branch $MEGATRON_REPO_SNAPSHOT_BRANCH"
        git clone --single-branch --branch $MEGATRON_REPO_SNAPSHOT_BRANCH /megatron-lm_repo .
        popd
    '
log_msg "END all_node_setup"
# main workload
#--------------------------------
log_msg "START main_workload"
srun \
    --label \
    --container-mounts ${CONTAINER_MOUNTS} \
    --container-image /home/sbak/mcore_ci_040825.sqsh \
    --container-name ${SLURM_JOB_ID} \
    --container-workdir / \
    --error=${LOG_FILE_BASE}.1.main_workload.log \
    --output=${LOG_FILE_BASE}.1.main_workload.log \
    --ntasks-per-node=4 \
    --ntasks=8 \
    --kill-on-bad-exit=0 \
    --mpi=none \
    bash -c '
        source /tmp/.myenv_${SLURM_JOB_ID}.sh
        pushd $MEGATRON_PATH
        LAUNCHER_CMD="python3"
        LAUNCHER_ARGS=" \
        "
        WORKLOAD_CMD=${MEGATRON_PATH}/pretrain_gpt.py
        WORKLOAD_ARGS=" \
            --exit-duration-in-mins 5750 \
            --distributed-timeout-minutes 10 \
            --disable-gloo-process-groups \
            --mock-data \
            --data-cache-path /datacache \
            --no-create-attention-mask-in-dataloader \
            --no-mmap-bin-files \
            --tokenizer-type NullTokenizer \
            --tiktoken-pattern v2 \
            --tokenizer-model /lustre/fsw/portfolios/llmservice/projects/llmservice_nlp_fm/nemotron6/tokenizers/multiMixV8.gpt4o_nc_sd.500000.128k.vocab.json \
            --micro-batch-size 1 \
            --global-batch-size 64 \
            --train-samples 10240000 \
            --adam-beta1 0.9 \
            --adam-beta2 0.95 \
            --adam-eps 1e-05 \
            --lr-decay-style cosine \
            --lr-warmup-samples 1024000 \
            --lr-decay-samples 20480000 \
            --lr 0.0003 \
            --min-lr 2.9999999999999997e-05 \
            --weight-decay 0.1 \
            --clip-grad 1.0 \
            --loss-scale 1.0 \
            --use-mcore-models \
            --untie-embeddings-and-output-weights \
            --disable-bias-linear \
            --attention-backend flash \
            --transformer-impl transformer_engine \
            --position-embedding-type rope \
            --rotary-base 500000 \
            --rotary-interleaved \
            --use-rope-scaling \
            --rope-scaling-factor 8.0 \
            --no-rope-fusion \
            --no-rope-freq 4 \
            --use-flash-attn \
            --cross-entropy-fusion-impl te \
            --cross-entropy-loss-fusion \
            --seq-length 8192 \
            --max-position-embeddings 8192 \
            --num-layers 12 \
            --swiglu \
            --hidden-size 5120 \
            --num-attention-heads 40 \
            --group-query-attention \
            --num-query-groups 8 \
            --ffn-hidden-size 16384 \
            --kv-channels 128 \
            --normalization RMSNorm \
            --attention-dropout 0.0 \
            --hidden-dropout 0.0 \
            --grad-reduce-in-bf16 \
            --qk-l2-norm \
            --num-experts 16 \
            --moe-layer-freq 1 \
            --moe-ffn-hidden-size 8192 \
            --moe-shared-expert-intermediate-size 8192 \
            --moe-router-topk 1 \
            --moe-router-score-function sigmoid \
            --moe-token-dispatcher-type alltoall \
            --moe-grouped-gemm \
            --moe-shared-expert-overlap \
            --moe-router-bias-update-rate 0.001 \
            --moe-router-load-balancing-type aux_loss \
            --moe-aux-loss-coeff 0.01 \
            --moe-router-enable-expert-bias \
            --moe-apply-probs-on-input \
            --moe-router-force-load-balancing \
            --bf16 \
            --fp8-format hybrid \
            --fp8-recipe delayed \
            --fp8-param-gather \
            --fp8-amax-history-len 1024 \
            --fp8-amax-compute-algo max \
            --fp8-margin 0 \
            --te-rng-tracker \
            --sequence-parallel \
            --use-distributed-optimizer \
            --overlap-grad-reduce \
            --overlap-param-gather \
            --ddp-num-buckets 5 \
            --tensor-model-parallel-size 1 \
            --pipeline-model-parallel-size 1 \
            --expert-model-parallel-size 8 \
            --expert-tensor-parallel-size 1 \
            --ddp-average-in-collective \
            --log-interval 1 \
            --log-progress \
            --timing-log-option minmax \
            --log-params-norm \
            --log-num-zeros-in-grad \
            --log-throughput \
            --check-weight-hash-across-dp-replicas-interval 20000 \
            --tensorboard-dir /tensorboard \
            --logging-level 10 \
            --eval-iters 14 \
            --eval-interval 2000 \
            --manual-gc \
            --manual-gc-interval 100 \
            --num-workers 1 \
            --rerun-mode validate_results \
            --log-straggler \
            --disable-straggler-on-startup \
            --straggler-minmax-count 16 \
            --local-rank ${SLURM_LOCALID} \
            --context-parallel-size 1 \
            --vocab-size 238600 \
            --megatron-fault-hang-at-iter 5 \
            --megatron-fault-hang-rank 1 \
            --distributed-timeout-seconds-after-init 1 \
            --flight-recorder-dump-path /checkpoint-save \
        "
        $LAUNCHER_CMD $LAUNCHER_ARGS $WORKLOAD_CMD $WORKLOAD_ARGS
    '
log_msg "END main_workload"

log_msg "END SBATCH"

set +x
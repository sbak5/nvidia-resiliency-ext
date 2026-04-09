#!/bin/bash
source ${VENV_DIR}/activate
python3 ${RITS_DIR}/rits.py experiment=megatron_l4_scout_gb200_reduced user=${USER} sbatch.nodes=${NODES} cluster=nvl72 fault=mlm_fault resilience=tracing
salloc --account=root --partition=gb-nvl-134-135 --time=04:00:00 --nodes=${NODES}
deactivate


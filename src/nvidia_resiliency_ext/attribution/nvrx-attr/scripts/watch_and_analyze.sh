#!/bin/bash
# watch_and_analyze.sh
# Poll SLURM for job completions from a fault-injection session tracking file,
# run log-analysis on each completed job, and aggregate a scoring report.
#
# Usage:
#   bash scripts/watch_and_analyze.sh <TRACKING_FILE>

set -euo pipefail

TRACKING_FILE="${1:?Usage: $0 <tracking_file.tsv>}"
POLL_INTERVAL=30

SCRIPT_DIR="$(dirname "$0")"
SKILL_DIR="$(dirname "${SCRIPT_DIR}")"

# Resolve log-analysis runner: prefer the installed nvrx_logsage CLI,
# fall back to the local script.
LOGSAGE_PY="${SKILL_DIR}/log-analysis/scripts/nvrx_logsage.py"

REPORT_FILE="${TRACKING_FILE%.tsv}_report.md"
DONE_JOBS_FILE="${TRACKING_FILE%.tsv}_done.txt"

touch "${DONE_JOBS_FILE}"

cat > "${REPORT_FILE}" <<'EOF'
# Fault Injection Experiment Report

| # | FAULT_TYPE | NODES | RANK | ITER | JOB_ID | STATE | log_restart | log_rank_ok | log_type_ok | fr_rank_ok | notes |
|---|------------|-------|------|------|--------|-------|-------------|-------------|-------------|------------|-------|
EOF

echo ">>> Watching tracking file: ${TRACKING_FILE}"
echo ">>> Report: ${REPORT_FILE}"
echo ">>> Polling every ${POLL_INTERVAL}s ..."

TOTAL=$(tail -n +2 "${TRACKING_FILE}" | wc -l)
EXP_NUM=0

while true; do
    PENDING=0

    while IFS=$'\t' read -r JOB_ID FAULT_TYPE RANK ITER NODES EXPERIMENT_DIR; do
        # Skip already-analyzed jobs
        if grep -q "^${JOB_ID}$" "${DONE_JOBS_FILE}" 2>/dev/null; then
            continue
        fi

        # Check job state
        STATE=$(scontrol show job "${JOB_ID}" 2>/dev/null \
            | grep -oP 'JobState=\K\S+' || echo "UNKNOWN")

        case "${STATE}" in
            RUNNING|PENDING|COMPLETING)
                PENDING=$((PENDING + 1))
                continue
                ;;
            COMPLETED|FAILED|TIMEOUT|CANCELLED|NODE_FAIL)
                ;;
            *)
                # Job left the queue — treat as done
                ;;
        esac

        EXP_NUM=$((EXP_NUM + 1))
        echo ""
        echo ">>> [${EXP_NUM}/${TOTAL}] Analyzing: ${FAULT_TYPE} n=${NODES} rank=${RANK} iter=${ITER} job=${JOB_ID} state=${STATE}"

        # ---- Log analysis ----
        LOG_GLOB="${EXPERIMENT_DIR}/logs/slurm/${JOB_ID}.*.1.main_workload.log"
        LOG_FILE=$(ls ${LOG_GLOB} 2>/dev/null | head -1 || true)

        LOG_RESTART="N/A"
        LOG_RANK_OK="N/A"
        LOG_TYPE_OK="N/A"
        LOG_NOTES=""

        if [[ -n "${LOG_FILE}" && -f "${LOG_FILE}" ]]; then
            echo "    log: ${LOG_FILE}"
            LOG_OUT=$(python3 "${LOGSAGE_PY}" \
                --log-path "${LOG_FILE}" \
                --output-format json 2>/dev/null || echo '{}')

            # Extract restart decision
            LOG_RESTART=$(echo "${LOG_OUT}" | python3 -c \
                "import sys,json; d=json.load(sys.stdin); print(d.get('restart_decision','?'))" \
                2>/dev/null || echo "?")

            # Extract attribution text for scoring
            ATTR_TEXT=$(echo "${LOG_OUT}" | python3 -c \
                "import sys,json; d=json.load(sys.stdin); print(d.get('attribution_text',''))" \
                2>/dev/null || echo "")

            # Score rank: check if injected rank appears in attribution text
            if echo "${ATTR_TEXT}" | grep -qP "(rank|process|worker)\s*${RANK}([^0-9]|$)"; then
                LOG_RANK_OK="true"
            else
                LOG_RANK_OK="false"
                LOG_NOTES+="rank${RANK} not in attr; "
            fi

            # Score fault type
            case "${FAULT_TYPE}" in
                GPU_SLEEP)
                    if echo "${ATTR_TEXT}" | grep -qiP "hang|timeout|sleep|stuck|watchdog"; then
                        LOG_TYPE_OK="true"
                    else
                        LOG_TYPE_OK="false"
                        LOG_NOTES+="type mismatch (expected hang); "
                    fi
                    ;;
                SIGKILL|SEGFAULT|GPU_ERROR)
                    if echo "${ATTR_TEXT}" | grep -qiP "crash|kill|segfault|abort|signal|error"; then
                        LOG_TYPE_OK="true"
                    else
                        LOG_TYPE_OK="false"
                        LOG_NOTES+="type mismatch (expected crash); "
                    fi
                    ;;
            esac
        else
            LOG_NOTES+="no log file found; "
            echo "    WARN: no log file at ${LOG_GLOB}"
        fi

        # ---- FR analysis ----
        FR_DIR="${EXPERIMENT_DIR}/checkpoints"
        FR_RANK_OK="N/A"

        if ls "${FR_DIR}"/*.pkl 2>/dev/null | grep -q .; then
            echo "    FR dumps: $(ls "${FR_DIR}"/*.pkl 2>/dev/null | wc -l) files"
            FR_OUT=$(python3 -c "
import sys
sys.path.insert(0, '${SKILL_DIR}/../../')
from nvidia_resiliency_ext.attribution.trace_analyzer.fr_attribution import CollectiveAnalyzer
try:
    ca = CollectiveAnalyzer('${FR_DIR}')
    result = ca.analyze()
    suspects = result.get('suspect_ranks', [])
    print('suspects=' + str(suspects))
except Exception as e:
    print('error=' + str(e))
" 2>/dev/null || echo "error=import_failed")

            if echo "${FR_OUT}" | grep -q "suspects="; then
                SUSPECTS=$(echo "${FR_OUT}" | grep -oP "suspects=\[\K[^\]]*")
                if echo "${SUSPECTS}" | grep -q "${RANK}"; then
                    FR_RANK_OK="true"
                else
                    FR_RANK_OK="false"
                    LOG_NOTES+="FR suspects=[${SUSPECTS}] missing rank${RANK}; "
                fi
            else
                FR_RANK_OK="error"
                LOG_NOTES+="FR error: ${FR_OUT}; "
            fi
        else
            FR_RANK_OK="no_dumps"
            LOG_NOTES+="no FR dumps; "
        fi

        echo "    restart=${LOG_RESTART}  log_rank=${LOG_RANK_OK}  log_type=${LOG_TYPE_OK}  fr_rank=${FR_RANK_OK}"
        [[ -n "${LOG_NOTES}" ]] && echo "    notes: ${LOG_NOTES}"

        # Append to report
        printf "| %d | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n" \
            "${EXP_NUM}" "${FAULT_TYPE}" "${NODES}" "${RANK}" "${ITER}" \
            "${JOB_ID}" "${STATE}" \
            "${LOG_RESTART}" "${LOG_RANK_OK}" "${LOG_TYPE_OK}" "${FR_RANK_OK}" \
            "${LOG_NOTES}" >> "${REPORT_FILE}"

        echo "${JOB_ID}" >> "${DONE_JOBS_FILE}"

    done < <(tail -n +2 "${TRACKING_FILE}")

    DONE_COUNT=$(wc -l < "${DONE_JOBS_FILE}")
    echo "$(date '+%H:%M:%S') >>> ${DONE_COUNT}/${TOTAL} done, ${PENDING} still running"

    if [[ ${DONE_COUNT} -ge ${TOTAL} ]]; then
        break
    fi

    sleep "${POLL_INTERVAL}"
done

echo ""
echo ">>> All ${TOTAL} experiments analyzed."
echo ">>> Report: ${REPORT_FILE}"
echo ""
cat "${REPORT_FILE}"

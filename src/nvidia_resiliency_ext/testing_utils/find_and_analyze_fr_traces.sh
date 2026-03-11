#!/bin/bash

# Script to find directories containing FR traces and run fr_attribution on them
# Usage: ./find_and_analyze_fr_traces.sh [root_search_path] [options]

set -euo pipefail

# Default values
ROOT_PATH="${1:-.}"
PATTERN="${FR_PATTERN:-_dump_*}"  # Can be overridden with env var
VERBOSE="${FR_VERBOSE:-false}"
HEALTH_CHECK="${FR_HEALTH_CHECK:-true}"
LLM_ANALYZE="${FR_LLM_ANALYZE:-false}"
MIN_FILES="${FR_MIN_FILES:-1}"  # Minimum number of trace files required
LOG_FILE="fr_analysis_$(date +%Y%m%d_%H%M%S).log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print usage
usage() {
    cat << EOF
Usage: $0 [ROOT_PATH] [OPTIONS]

Find directories containing FR traces and run fr_attribution analysis.

Arguments:
    ROOT_PATH           Root directory to search (default: current directory)

Environment Variables:
    FR_PATTERN          File pattern to search for (default: _dump_*)
    FR_VERBOSE          Enable verbose output (default: false)
    FR_HEALTH_CHECK     Enable health check (default: true)
    FR_LLM_ANALYZE      Enable LLM analysis (default: false)
    FR_MIN_FILES        Minimum trace files required (default: 1)

Examples:
    # Search current directory for FR traces
    $0

    # Search specific directory
    $0 ~/experiments/llama4-scout-gb200/

    # Search with custom pattern and enable LLM analysis
    FR_PATTERN="*.json" FR_LLM_ANALYZE=true $0 ~/experiments/

    # Search with verbose output
    FR_VERBOSE=true $0 ~/experiments/
EOF
    exit 1
}

# Check if help requested
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    usage
fi

# Print header
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}FR Trace Discovery and Analysis Tool${NC}"
echo -e "${BLUE}============================================================${NC}"
echo -e "Search path: ${GREEN}${ROOT_PATH}${NC}"
echo -e "Pattern: ${GREEN}${PATTERN}${NC}"
echo -e "Log file: ${GREEN}${LOG_FILE}${NC}"
echo -e "${BLUE}============================================================${NC}\n"

# Check if fr_attribution is available
if ! command -v python &> /dev/null; then
    echo -e "${RED}Error: python not found${NC}" >&2
    exit 1
fi

# Find python module
FR_MODULE="nvidia_resiliency_ext.attribution.trace_analyzer.fr_attribution"

# Check if ROOT_PATH exists
if [[ ! -d "${ROOT_PATH}" ]]; then
    echo -e "${RED}Error: Directory '${ROOT_PATH}' does not exist${NC}" >&2
    exit 1
fi

# Initialize counters
TOTAL_DIRS=0
PROCESSED_DIRS=0
FAILED_DIRS=0
SKIPPED_DIRS=0

# Create temporary file to store directories with traces
TEMP_DIRS=$(mktemp)
trap "rm -f ${TEMP_DIRS}" EXIT

echo "Searching for directories with FR traces..."
echo "This may take a while for large directory trees..." >&2

# Find all directories containing files matching the pattern
# Group by parent directory to avoid processing each file individually
while IFS= read -r -d '' file; do
    dir=$(dirname "$file")
    echo "$dir"
done < <(find "${ROOT_PATH}" -type f -name "${PATTERN}" -print0 2>/dev/null) | sort -u > "${TEMP_DIRS}"

TOTAL_DIRS=$(wc -l < "${TEMP_DIRS}")

if [[ ${TOTAL_DIRS} -eq 0 ]]; then
    echo -e "${YELLOW}No directories with FR traces found matching pattern '${PATTERN}'${NC}"
    echo -e "${YELLOW}Try different pattern, e.g.: FR_PATTERN='*.json' $0 ${ROOT_PATH}${NC}"
    exit 0
fi

echo -e "${GREEN}Found ${TOTAL_DIRS} directories with FR traces${NC}\n"

# Process each directory
while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    
    # Count files in directory
    file_count=$(find "$dir" -maxdepth 1 -type f -name "${PATTERN}" | wc -l)
    
    if [[ ${file_count} -lt ${MIN_FILES} ]]; then
        echo -e "${YELLOW}Skipping${NC} $dir (only ${file_count} files, minimum ${MIN_FILES} required)"
        ((SKIPPED_DIRS++)) || true
        continue
    fi
    
    echo -e "${BLUE}Processing [$(($PROCESSED_DIRS + $FAILED_DIRS + $SKIPPED_DIRS + 1))/${TOTAL_DIRS}]:${NC} $dir"
    echo -e "  Files found: ${file_count}"
    
    # Build command
    cmd=(python -m "${FR_MODULE}" --fr-path "$dir" -p "${PATTERN}")
    
    [[ "${VERBOSE}" == "true" ]] && cmd+=(-v)
    [[ "${HEALTH_CHECK}" == "true" ]] && cmd+=(-c)
    [[ "${LLM_ANALYZE}" == "true" ]] && cmd+=(-l)
    
    # Run analysis
    {
        echo "========================================" >> "${LOG_FILE}"
        echo "Directory: $dir" >> "${LOG_FILE}"
        echo "Timestamp: $(date)" >> "${LOG_FILE}"
        echo "Command: ${cmd[*]}" >> "${LOG_FILE}"
        echo "========================================" >> "${LOG_FILE}"
        
        if "${cmd[@]}" >> "${LOG_FILE}" 2>&1; then
            echo -e "  ${GREEN}✓ Success${NC}"
            ((PROCESSED_DIRS++)) || true
        else
            echo -e "  ${RED}✗ Failed${NC} (check ${LOG_FILE} for details)"
            ((FAILED_DIRS++)) || true
        fi
        
        echo "" >> "${LOG_FILE}"
    }
    
    echo ""
done < "${TEMP_DIRS}"

# Print summary
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}Summary${NC}"
echo -e "${BLUE}============================================================${NC}"
echo -e "Total directories found: ${TOTAL_DIRS}"
echo -e "${GREEN}Successfully processed: ${PROCESSED_DIRS}${NC}"
echo -e "${YELLOW}Skipped (too few files): ${SKIPPED_DIRS}${NC}"
echo -e "${RED}Failed: ${FAILED_DIRS}${NC}"
echo -e "Full log: ${GREEN}${LOG_FILE}${NC}"
echo -e "${BLUE}============================================================${NC}"
echo -e ""
echo -e "${BLUE}Next Steps:${NC}"
echo -e "  To view a summary of results with directory context:"
echo -e "  ${GREEN}./summarize_fr_analysis.sh ${LOG_FILE}${NC}"
echo -e ""
echo -e "  To see only missing ranks:"
echo -e "  ${GREEN}./summarize_fr_analysis.sh ${LOG_FILE} --missing-only${NC}"
echo -e ""
echo -e "  To count problematic ranks:"
echo -e "  ${GREEN}./summarize_fr_analysis.sh ${LOG_FILE} --count-ranks${NC}"
echo -e "${BLUE}============================================================${NC}"

# Exit with error if any failures
[[ ${FAILED_DIRS} -eq 0 ]] && exit 0 || exit 1


#!/bin/bash

# Script to summarize FR analysis results from log files
# Shows analysis tables with context about which directory they came from
# Usage: ./summarize_fr_analysis.sh <log_file> [options]

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Print usage
usage() {
    cat << EOF
Usage: $0 <log_file> [OPTIONS]

Summarize FR attribution analysis results from log files.

Arguments:
    log_file            Path to FR analysis log file

Options:
    --missing-only      Show only entries with missing ranks
    --completed-only    Show only entries with completed ranks
    --count-ranks       Count occurrences of each missing rank
    --by-directory      Group results by directory
    --export-csv FILE   Export summary to CSV file
    -h, --help          Show this help message

Examples:
    # Show all results with directory context
    $0 fr_analysis_20251103_132355.log

    # Show only issues (missing ranks)
    $0 fr_analysis_20251103_132355.log --missing-only

    # Count which ranks are problematic
    $0 fr_analysis_20251103_132355.log --count-ranks

    # Group by directory
    $0 fr_analysis_20251103_132355.log --by-directory

    # Export to CSV
    $0 fr_analysis_20251103_132355.log --export-csv results.csv
EOF
    exit 1
}

# Check arguments
if [[ $# -eq 0 ]] || [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    usage
fi

LOG_FILE="$1"
shift

# Parse options
MISSING_ONLY=false
COMPLETED_ONLY=false
COUNT_RANKS=false
BY_DIRECTORY=false
EXPORT_CSV=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --missing-only)
            MISSING_ONLY=true
            shift
            ;;
        --completed-only)
            COMPLETED_ONLY=true
            shift
            ;;
        --count-ranks)
            COUNT_RANKS=true
            shift
            ;;
        --by-directory)
            BY_DIRECTORY=true
            shift
            ;;
        --export-csv)
            EXPORT_CSV="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Check if log file exists
if [[ ! -f "${LOG_FILE}" ]]; then
    echo -e "${RED}Error: Log file '${LOG_FILE}' not found${NC}" >&2
    exit 1
fi

# Print header
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}FR Attribution Analysis Summary${NC}"
echo -e "${BLUE}============================================================${NC}"
echo -e "Log file: ${GREEN}${LOG_FILE}${NC}"
echo -e "${BLUE}============================================================${NC}\n"

# Create temporary files
TEMP_DIR=$(mktemp -d)
trap "rm -rf ${TEMP_DIR}" EXIT

PARSED_FILE="${TEMP_DIR}/parsed.txt"
CURRENT_DIR="${TEMP_DIR}/current_dir.txt"

# Get the directory where extract_failure_info.sh is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACT_SCRIPT="${SCRIPT_DIR}/extract_failure_info.sh"

# Function to get fault injection info for a directory
get_fault_info() {
    local dir="$1"
    if [[ -x "$EXTRACT_SCRIPT" ]]; then
        "$EXTRACT_SCRIPT" "$dir" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Parse the log file and associate each table row with its directory
echo "" > "$CURRENT_DIR"
LAST_HEADER_TYPE="${TEMP_DIR}/header_type.txt"
echo "UNKNOWN" > "$LAST_HEADER_TYPE"

# Cache for fault injection info per directory
FAULT_CACHE="${TEMP_DIR}/fault_cache.txt"
> "$FAULT_CACHE"

{
    while IFS= read -r line; do
        # Check if this is a directory marker
        if [[ $line =~ ^Directory:\ (.+)$ ]]; then
            echo "${BASH_REMATCH[1]}" > "$CURRENT_DIR"
        # Check if this is a table row with pipes
        elif [[ $line =~ INFO:root:(.+\|.+) ]]; then
            table_row="${BASH_REMATCH[1]}"
            # Check if this is a header row
            if [[ $table_row =~ ^PGID ]]; then
                # Determine the type from the header
                if [[ $table_row =~ Missing\ Ranks ]]; then
                    echo "MISSING" > "$LAST_HEADER_TYPE"
                elif [[ $table_row =~ Completed\ Ranks ]]; then
                    echo "COMPLETED" > "$LAST_HEADER_TYPE"
                else
                    echo "UNKNOWN" > "$LAST_HEADER_TYPE"
                fi
            else
                # This is a data row - use the type from the last header
                current_dir=$(cat "$CURRENT_DIR")
                status=$(cat "$LAST_HEADER_TYPE")
                # Output: STATUS|DIRECTORY|TABLE_ROW
                echo "${status}|${current_dir}|${table_row}"
            fi
        fi
    done < "$LOG_FILE"
} > "$PARSED_FILE"

# Count statistics
TOTAL_ENTRIES=$(wc -l < "$PARSED_FILE")
MISSING_ENTRIES=$(grep -c "^MISSING|" "$PARSED_FILE" || true)
COMPLETED_ENTRIES=$(grep -c "^COMPLETED|" "$PARSED_FILE" || true)
UNIQUE_DIRS=$(cut -d'|' -f2 "$PARSED_FILE" | sort -u | wc -l)

echo -e "${CYAN}Statistics:${NC}"
echo -e "  Total analysis entries: ${TOTAL_ENTRIES}"
echo -e "  Entries with missing ranks: ${RED}${MISSING_ENTRIES}${NC}"
echo -e "  Entries with completed ranks: ${GREEN}${COMPLETED_ENTRIES}${NC}"
echo -e "  Unique directories: ${UNIQUE_DIRS}"
echo -e ""

# Export to CSV if requested
if [[ -n "$EXPORT_CSV" ]]; then
    echo "Status,Directory,PGID,ProcessGroup,OpType,Size,Dtype,Ranks" > "$EXPORT_CSV"
    while IFS='|' read -r status dir row; do
        # Parse the table row (whitespace-separated, pipe-delimited)
        # Format: PGID | ProcessGroup | OpType | Size | Dtype | Ranks
        echo "${status},${dir},${row}" | sed 's/ *| */,/g' >> "$EXPORT_CSV"
    done < "$PARSED_FILE"
    echo -e "${GREEN}Exported to: ${EXPORT_CSV}${NC}\n"
fi

# Count ranks if requested
if [[ "$COUNT_RANKS" == "true" ]]; then
    echo -e "${CYAN}Most Problematic Ranks (Missing):${NC}"
    echo -e "${CYAN}-----------------------------------${NC}"
    
    # Extract all missing ranks and count them
    # Get the last column (after the last |), split by comma, count occurrences
    RANK_COUNTS="${TEMP_DIR}/rank_counts.txt"
    grep "^MISSING|" "$PARSED_FILE" | while IFS='|' read -r status dir row; do
        # Extract the last field (ranks column) 
        ranks=$(echo "$row" | awk -F'|' '{print $NF}' | tr -d ' ')
        # Split by comma and output each rank on its own line
        echo "$ranks" | tr ',' '\n'
    done | grep -E '^[0-9]+$' | sort -n | uniq -c | sort -rn > "$RANK_COUNTS"
    
    if [[ -s "$RANK_COUNTS" ]]; then
        head -20 "$RANK_COUNTS" | while read count rank; do
            echo -e "  Rank ${YELLOW}${rank}${NC}: ${RED}${count}${NC} occurrences"
        done
    else
        echo -e "  ${YELLOW}No ranks found${NC}"
    fi
    echo -e ""
fi

# Display results
if [[ "$BY_DIRECTORY" == "true" ]]; then
    # Group by directory
    echo -e "${CYAN}Results Grouped by Directory:${NC}"
    echo -e "${CYAN}=============================${NC}\n"
    
    cut -d'|' -f2 "$PARSED_FILE" | sort -u | while IFS= read -r dir; do
        dir_entries=$(grep -F "|${dir}|" "$PARSED_FILE" || true)
        if [[ -z "$dir_entries" ]]; then
            continue
        fi
        
        dir_count=$(echo "$dir_entries" | wc -l)
        dir_missing=$(echo "$dir_entries" | grep -c "^MISSING|" || true)
        dir_completed=$(echo "$dir_entries" | grep -c "^COMPLETED|" || true)
        
        # Apply filters
        if [[ "$MISSING_ONLY" == "true" ]] && [[ $dir_missing -eq 0 ]]; then
            continue
        fi
        if [[ "$COMPLETED_ONLY" == "true" ]] && [[ $dir_completed -eq 0 ]]; then
            continue
        fi
        
        fault_info=$(get_fault_info "$dir")
        echo -e "${BLUE}Directory:${NC} ${dir}"
        echo -e "  Total: ${dir_count}, Missing: ${RED}${dir_missing}${NC}, Completed: ${GREEN}${dir_completed}${NC}"
        if [[ -n "$fault_info" ]] && [[ "$fault_info" != "no_fault_injection" ]] && [[ "$fault_info" != "NO_LOGS" ]]; then
            echo -e "  ${MAGENTA}Fault Injection:${NC} ${fault_info}"
        fi
        echo -e ""
        
        echo "$dir_entries" | while IFS='|' read -r status _ row; do
            if [[ "$status" == "MISSING" ]]; then
                echo -e "    ${RED}[MISSING]${NC} ${row}"
            elif [[ "$status" == "COMPLETED" ]]; then
                echo -e "    ${GREEN}[DONE]   ${NC} ${row}"
            else
                echo -e "    ${YELLOW}[?]      ${NC} ${row}"
            fi
        done
        echo -e ""
    done
else
    # Display all results with directory context
    echo -e "${CYAN}Results with Directory Context:${NC}"
    echo -e "${CYAN}===============================${NC}\n"
    
    current_display_dir=""
    while IFS='|' read -r status dir row; do
        # Apply filters
        if [[ "$MISSING_ONLY" == "true" ]] && [[ "$status" != "MISSING" ]]; then
            continue
        fi
        if [[ "$COMPLETED_ONLY" == "true" ]] && [[ "$status" != "COMPLETED" ]]; then
            continue
        fi
        
        # Print directory header if it changed
        if [[ "$dir" != "$current_display_dir" ]]; then
            current_display_dir="$dir"
            fault_info=$(get_fault_info "$dir")
            echo -e "\n${BLUE}━━━ Directory:${NC} ${dir}"
            if [[ -n "$fault_info" ]] && [[ "$fault_info" != "no_fault_injection" ]] && [[ "$fault_info" != "NO_LOGS" ]]; then
                echo -e "${BLUE}    Fault Injection:${NC} ${MAGENTA}${fault_info}${NC}"
            fi
        fi
        
        # Print the result with color coding
        if [[ "$status" == "MISSING" ]]; then
            echo -e "    ${RED}[MISSING]${NC} ${row}"
        elif [[ "$status" == "COMPLETED" ]]; then
            echo -e "    ${GREEN}[DONE]   ${NC} ${row}"
        else
            echo -e "    ${YELLOW}[?]      ${NC} ${row}"
        fi
    done < "$PARSED_FILE"
fi

# Generate summary table
echo -e "\n${BLUE}============================================================${NC}"
echo -e "${BLUE}Fault Injection Validation Summary${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

# Create summary table
echo -e "${CYAN}Fault Type          | Injected Rank | Missing Ranks    | Match | Directory${NC}"
echo "-------------------|---------------|------------------|-------|----------"

# Parse through parsed file and extract fault info
cut -d'|' -f2 "$PARSED_FILE" | sort -u | while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    
    # Get fault injection info
    fault_info=$(get_fault_info "$dir")
    
    if [[ -n "$fault_info" ]] && [[ "$fault_info" != "no_fault_injection" ]] && [[ "$fault_info" != "NO_LOGS" ]] && [[ "$fault_info" != "NO_LOG_FILE" ]]; then
        # Parse fault_info: "11:GPU_ERROR"
        injected_rank=$(echo "$fault_info" | cut -d':' -f1)
        fault_type=$(echo "$fault_info" | cut -d':' -f2)
        
        # Get ALL missing ranks for this directory (aggregate from all entries)
        all_missing_ranks=$(grep "^MISSING|${dir}|" "$PARSED_FILE" | \
            cut -d'|' -f3- | awk -F'|' '{print $NF}' | tr -d ' ' | \
            tr ',' '\n' | sort -u -n | tr '\n' ',' | sed 's/,$//')
        
        # Check if injected rank is in missing ranks
        if echo "$all_missing_ranks" | grep -qw "$injected_rank"; then
            match="✓"
            match_color="${GREEN}"
        else
            match="✗"
            match_color="${RED}"
        fi
        
        # Use full directory path
        printf "%-18s | %-13s | %-16s | ${match_color}%-5s${NC} | %s\n" \
            "$fault_type" "$injected_rank" "$all_missing_ranks" "$match" "$dir"
    fi
done | head -50

echo ""

# Calculate success rate
TOTAL_WITH_FAULTS=$(cut -d'|' -f2 "$PARSED_FILE" | sort -u | while read dir; do
    fault_info=$(get_fault_info "$dir")
    if [[ -n "$fault_info" ]] && [[ "$fault_info" != "no_fault_injection" ]] && [[ "$fault_info" != "NO_LOGS" ]] && [[ "$fault_info" != "NO_LOG_FILE" ]]; then
        echo "1"
    fi
done | wc -l)

CORRECT_MATCHES=$(cut -d'|' -f2 "$PARSED_FILE" | sort -u | while read dir; do
    fault_info=$(get_fault_info "$dir")
    if [[ -n "$fault_info" ]] && [[ "$fault_info" != "no_fault_injection" ]] && [[ "$fault_info" != "NO_LOGS" ]] && [[ "$fault_info" != "NO_LOG_FILE" ]]; then
        injected_rank=$(echo "$fault_info" | cut -d':' -f1)
        # Get ALL missing ranks (aggregate from all entries)
        all_missing_ranks=$(grep "^MISSING|${dir}|" "$PARSED_FILE" | \
            cut -d'|' -f3- | awk -F'|' '{print $NF}' | tr -d ' ' | \
            tr ',' '\n' | sort -u -n | tr '\n' ',' | sed 's/,$//')
        if echo "$all_missing_ranks" | grep -qw "$injected_rank"; then
            echo "1"
        fi
    fi
done | wc -l)

if [[ $TOTAL_WITH_FAULTS -gt 0 ]]; then
    SUCCESS_RATE=$(( CORRECT_MATCHES * 100 / TOTAL_WITH_FAULTS ))
    echo -e "${CYAN}FR Attribution Success Rate:${NC} ${GREEN}$SUCCESS_RATE%${NC} ($CORRECT_MATCHES/$TOTAL_WITH_FAULTS correct identifications)"
else
    echo -e "${YELLOW}No fault injection data available for validation${NC}"
fi

echo ""

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}Summary Complete${NC}"
echo -e "${BLUE}============================================================${NC}"


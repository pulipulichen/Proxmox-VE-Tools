#!/usr/bin/env bash
# Burn-in test script for Ubuntu 24.04 (Merged Version)
# Combines CPU, Memory, and Disk stress into a single stress-ng process
# Generates a timestamped report upon completion.

set -euo pipefail

# -------- Configuration --------

# Default duration in hours if not provided
DURATION_HOURS="${1:-72}"

# Calculate duration in seconds
DURATION_SEC=$((DURATION_HOURS * 3600))

# For test
# DURATION_SEC=30

# Memory limit: Set the amount of virtual memory to use for stress testing.
MEMORY_LIMIT="20G"
# MEMORY_LIMIT="80%"

# Timezone Configuration
TIMEZONE="Asia/Taipei" # Default timezone for reports and timestamps

# -------- Internal Configuration --------- 

# Directory for disk stress temporary files
WORK_DIR="/tmp/burnin_workspace"

# Log directory
LOG_DIR="."
mkdir -p "${LOG_DIR}"

# Raw log from stress-ng (temporary)
RAW_LOG="${LOG_DIR}/stress_ng_raw.log"

# -------- Helper Functions --------

log() {
    echo "[$(env TZ="${TIMEZONE}" date '+%Y-%m-%d %H:%M:%S')] $*"
}

require_stress_ng() {
    if command -v stress-ng >/dev/null 2>&1; then
        return 0
    fi
    log "stress-ng not found. Installing..."
    apt-get update -y && apt-get install -y stress-ng
}

cleanup() {
    log "Cleaning up temporary files..."
    rm -rf "${WORK_DIR}"
}

generate_final_report() {
    local exit_code=$1
    local end_time_iso
    end_time_iso=$(env TZ="${TIMEZONE}" date '+%Y-%m-%d %H:%M:%S')
    local timestamp_filename
    timestamp_filename=$(env TZ="${TIMEZONE}" date '+%Y%m%d-%H%M%S')
    
    local report_file="${LOG_DIR}/burnin_report_${timestamp_filename}.txt"

    log "Generating final report at: ${report_file}"

    {
        echo "======================================================="
        echo "              BURN-IN TEST REPORT                      "
        echo "======================================================="
        echo "System Hostname : $(hostname)"
        echo "Operating System: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
        echo "Kernel Version  : $(uname -r)"
        echo "-------------------------------------------------------"
        echo "Start Time      : ${START_TIME_ISO}"
        echo "End Time        : ${end_time_iso}"
        echo "Target Duration : ${DURATION_HOURS} Hours"
        echo "-------------------------------------------------------"
        echo "Stress Configuration:"
        echo "  - CPU Workers : All Cores"
        echo "  - VM Workers  : 2 (utilizing ~80% RAM total)"
        echo "  - HDD Workers : 1 (Read/Write/Verify/Delete)"
        echo "  - Work Dir    : ${WORK_DIR}"
        echo "-------------------------------------------------------"
        echo "Test Result Status:"
        if [ "$exit_code" -eq 0 ]; then
            echo "  [ SUCCESS ] Completed full duration without stress-ng error."
        else
            echo "  [ WARNING ] Process exited with code ${exit_code} (Interrupted or Failed)."
        fi
        echo "-------------------------------------------------------"
        echo "stress-ng Output / Metrics:"
        echo ""
        if [ -f "${RAW_LOG}" ]; then
            cat "${RAW_LOG}"
        else
            echo "  (No raw log data available)"
        fi
        echo ""
        echo "======================================================="
    } > "${report_file}"

    log "Report generated successfully."
    echo "Report saved to: ${report_file}"
}

# -------- Main Execution --------

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: This script must be run as root."
    exit 1
fi

require_stress_ng

# Create workspace for disk test
mkdir -p "${WORK_DIR}"

START_TIME_ISO=$(env TZ="${TIMEZONE}" date '+%Y-%m-%d %H:%M:%S')

log "Starting Burn-in Test (Merged Mode)"
log "Duration: ${DURATION_HOURS} hours (${DURATION_SEC} seconds)"
log "Logs will be stored in: ${LOG_DIR}"

# Trap signals to ensure report is generated even if user cancels (Ctrl+C)
trap 'log "Test interrupted by user!"; generate_final_report 130; cleanup; exit 1' INT TERM

# ----------------------------------------------------------------
# THE MERGED STRESS-NG COMMAND
# ----------------------------------------------------------------
# Explanation of flags:
# --cpu 0           : Use all available CPU cores.
# --vm 2            : Start 2 memory stressors.
# --vm-bytes 20G    : Limit VM memory usage.
# --hdd 1           : Start 1 disk stressor.
# --verify          : Enable data verification (replaces old wr-check opts).
# --temp-path       : Where to write the disk stress files.
# --timeout         : Stop after X seconds.
# --metrics-brief   : Output summary metrics at the end.
# --log-file        : Save output to file.
# ----------------------------------------------------------------

stress-ng \
    --cpu 0 \
    --vm 2 \
    --vm-bytes "${MEMORY_LIMIT}" \
    --hdd 1 \
    --verify \
    --temp-path "${WORK_DIR}" \
    --timeout "${DURATION_SEC}s" \
    --metrics-brief \
    --log-file "${RAW_LOG}" \
    --verbose

EXIT_CODE=$?

# -------- Post-Processing --------

generate_final_report "$EXIT_CODE"
cleanup

if [ "$EXIT_CODE" -eq 0 ]; then
    log "Burn-in test finished successfully."
else
    log "Burn-in test finished with errors (Code: $EXIT_CODE)."
    exit "$EXIT_CODE"
fi
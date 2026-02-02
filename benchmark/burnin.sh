#!/usr/bin/env bash

# Ubuntu 24.04 Hardware Burn-in Test Script (Auto-detect Raw Disks)
# Combines CPU, Memory, and Auto-detected Physical Disk (Raw Device) stress testing.

set -euo pipefail

# -------- Configuration --------

# Default duration in hours if not provided via argument
DURATION_HOURS="${1:-72}"
DURATION_SEC=$((DURATION_HOURS * 3600))

# Memory limit: Virtual memory to use for stress testing
MEMORY_LIMIT="20G"

# Timezone Configuration for logs and reports
TIMEZONE="Asia/Taipei"

# Log Configuration
LOG_DIR="."
mkdir -p "${LOG_DIR}"
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

# Auto-detect raw disks available for testing (excludes system disk and mounted drives)
detect_raw_disks() {
    log "Detecting available disks..."
    
    # 1. Identify the disk containing the root (/) partition (e.g., sda or nvme0n1)
    local sys_disk_path
    sys_disk_path=$(lsblk -no PKNAME "$(findmnt -nvo SOURCE /)" | head -n1 || true)
    
    # 2. Get all block devices of type 'disk'
    local all_disks
    all_disks=$(lsblk -dpno NAME,TYPE | grep "disk" | awk '{print $1}')
    
    local target_disks=""
    local found_count=0

    for disk in $all_disks; do
        # Skip the system disk to prevent OS destruction
        if [[ -n "$sys_disk_path" && "$disk" == *"$sys_disk_path"* ]]; then
            log "Excluding system disk: $disk"
            continue
        fi

        # Skip disks that have active mount points on the disk itself or its partitions
        if lsblk -no MOUNTPOINT "$disk" | grep -q "/"; then
            log "Excluding disk currently in use or mounted: $disk"
            continue
        fi

        # Add to target list
        target_disks+="${disk},"
        ((found_count++))
    done

    # Remove trailing comma and output
    echo "${target_disks%,}"
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
        echo "Operating System: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"' || echo "Unknown")"
        echo "Kernel Version  : $(uname -r)"
        echo "-------------------------------------------------------"
        echo "Start Time      : ${START_TIME_ISO}"
        echo "End Time        : ${end_time_iso}"
        echo "Target Duration : ${DURATION_HOURS} Hours"
        echo "-------------------------------------------------------"
        echo "Stress Configuration:"
        echo "  - CPU Workers : All Cores"
        echo "  - VM Workers  : 2 (Limit: ${MEMORY_LIMIT})"
        echo "  - Raw Disks   : ${TARGET_DISKS:-None}"
        echo "-------------------------------------------------------"
        echo "Test Result Status:"
        if [ "$exit_code" -eq 0 ]; then
            echo "  [ SUCCESS ] Completed full duration without errors."
        else
            echo "  [ WARNING ] Process interrupted or failed (Exit Code: ${exit_code})."
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

    log "Report generated successfully: ${report_file}"
}

# -------- Main Execution --------

# Check for root privileges
if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: This script must be run as root (sudo)."
    exit 1
fi

require_stress_ng

# Detect target disks
TARGET_DISKS=$(detect_raw_disks)

if [[ -z "$TARGET_DISKS" ]]; then
    log "Error: No available raw disks found (must be unmounted and non-system)."
    exit 1
fi

START_TIME_ISO=$(env TZ="${TIMEZONE}" date '+%Y-%m-%d %H:%M:%S')

log "Starting Burn-in Test (Auto-detect Mode)"
log "Target Disks detected: $TARGET_DISKS"
log "Duration: ${DURATION_HOURS} hours (${DURATION_SEC} seconds)"

# Trap termination signals to ensure a report is generated
trap 'log "Test interrupted by user!"; generate_final_report 130; exit 1' INT TERM

# ----------------------------------------------------------------
# EXECUTE STRESS-NG
# ----------------------------------------------------------------
# --cpu 0          : Use all available CPU cores.
# --vm 2           : Start 2 memory stress workers.
# --rawdev 0       : Auto-assign workers for each raw device provided.
# --rawdev-file    : Path(s) to the raw block devices (comma separated).
# --rawdev-method  : Use 'all' to cycle through various I/O stress methods.
# ----------------------------------------------------------------

stress-ng \
    --cpu 0 \
    --vm 2 \
    --vm-bytes "${MEMORY_LIMIT}" \
    --rawdev 0 \
    --rawdev-file "${TARGET_DISKS}" \
    --rawdev-method all \
    --timeout "${DURATION_SEC}s" \
    --metrics-brief \
    --log-file "${RAW_LOG}" \
    --verbose

EXIT_CODE=$?

# -------- Post-Processing --------

generate_final_report "$EXIT_CODE"

if [ "$EXIT_CODE" -eq 0 ]; then
    log "Burn-in test finished successfully."
else
    log "Burn-in test finished with errors/interruption (Code: $EXIT_CODE)."
    exit "$EXIT_CODE"
fi

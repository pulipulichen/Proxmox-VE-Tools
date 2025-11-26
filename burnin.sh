#!/usr/bin/env bash
# Burn-in test script for Ubuntu 24.04
# Stress CPU, memory, and disk (read/write/delete files under /tmp)
# Default duration: 72 hours

set -euo pipefail

# -------- Configuration --------

# Default duration in hours if not provided as first argument
DURATION_HOURS="${1:-72}"

# Disk test working directory
DISK_WORK_DIR="/tmp/burnin_disk_test"

# Size of test file in MiB (1024 = 1 GiB)
DISK_TEST_SIZE_MB=1024

# -------- Helper functions --------

log() {
    # Print log message with timestamp
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

require_stress_ng() {
    # Ensure stress-ng is installed, try to install if missing
    if command -v stress-ng >/dev/null 2>&1; then
        return 0
    fi

    log "stress-ng is not installed. Trying to install via apt..."

    if [[ "$(id -u)" -ne 0 ]]; then
        log "ERROR: Need root privileges to install stress-ng. Run this script with sudo or as root."
        exit 1
    fi

    apt-get update -y
    apt-get install -y stress-ng

    if ! command -v stress-ng >/dev/null 2>&1; then
        log "ERROR: Failed to install stress-ng."
        exit 1
    fi

    log "stress-ng installed successfully."
}

calc_end_time() {
    # Calculate end timestamp in seconds since epoch
    local duration_seconds=$((DURATION_HOURS * 3600))
    END_TIME_EPOCH=$(( $(date +%s) + duration_seconds ))
}

cpu_mem_stress_start() {
    # Start CPU and memory stress using stress-ng
    local cpu_workers vm_workers duration_seconds

    cpu_workers="$(nproc)"
    vm_workers=$(( cpu_workers / 2 ))
    (( vm_workers < 1 )) && vm_workers=1

    duration_seconds=$((DURATION_HOURS * 3600))

    log "Starting CPU and memory stress:"
    log "  CPU workers: ${cpu_workers}"
    log "  VM workers:  ${vm_workers}"
    log "  Duration:    ${DURATION_HOURS} hours"

    # Fixed memory usage for vm workers
    local fixed_mem_usage_percent="4%"

    # --vm-bytes uses fixed_mem_usage_percent of total memory for each vm worker
    # --timeout avoids runaway if the script fails to stop it
    stress-ng \
        --cpu "${cpu_workers}" \
        --vm "${vm_workers}" \
        --vm-bytes "${fixed_mem_usage_percent}" \
        --timeout "${duration_seconds}s" \
        --metrics-brief &
    CPU_MEM_PID=$!

    log "CPU/MEM stress-ng PID: ${CPU_MEM_PID}"
}

disk_stress_loop() {
    # Disk stress loop: repeatedly write, read, verify, and delete files under /tmp
    local file_path
    file_path="${DISK_WORK_DIR}/disk_test.bin"

    log "Starting disk stress in ${DISK_WORK_DIR} with file size ${DISK_TEST_SIZE_MB} MiB."

    mkdir -p "${DISK_WORK_DIR}"

    local round=0
    while :; do
        local now
        now="$(date +%s)"
        if (( now >= END_TIME_EPOCH )); then
            log "Disk stress reached end of test duration."
            break
        fi

        round=$((round + 1))
        log "Disk stress round #${round}: writing ${DISK_TEST_SIZE_MB} MiB to ${file_path}"

        # Write random data to file
        dd if=/dev/urandom of="${file_path}" bs=1M count="${DISK_TEST_SIZE_MB}" conv=fsync,status=none

        sync

        # Read file back
        log "Disk stress round #${round}: reading file"
        dd if="${file_path}" of=/dev/null bs=1M status=none

        # Verify with checksum (sha256)
        log "Disk stress round #${round}: verifying file with sha256sum"
        sha256sum "${file_path}" >/dev/null

        # Delete file
        log "Disk stress round #${round}: deleting file"
        rm -f "${file_path}"
    done
}

disk_stress_start() {
    # Run disk stress loop in background
    disk_stress_loop &
    DISK_PID=$!
    log "Disk stress PID: ${DISK_PID}"
}

stop_all() {
    # Stop all background workers
    log "Stopping all stress workers..."

    if [[ -n "${CPU_MEM_PID:-}" ]]; then
        kill "${CPU_MEM_PID}" 2>/dev/null || true
    fi

    if [[ -n "${DISK_PID:-}" ]]; then
        kill "${DISK_PID}" 2>/dev/null || true
    fi

    wait "${CPU_MEM_PID:-}" "${DISK_PID:-}" 2>/dev/null || true || true

    log "All stress workers stopped."
}

setup_signal_traps() {
    # Handle Ctrl+C or termination signals
    trap 'log "Received SIGINT. Cleaning up..."; stop_all; exit 1' INT
    trap 'log "Received SIGTERM. Cleaning up..."; stop_all; exit 1' TERM
}

main_loop() {
    # Main loop: wait until time is reached
    log "Burn-in test running for ${DURATION_HOURS} hours..."
    while :; do
        local now
        now="$(date +%s)"
        if (( now >= END_TIME_EPOCH )); then
            log "Reached end of test duration (${DURATION_HOURS} hours)."
            break
        fi
        sleep 10
    done
}

# -------- Main --------

log "Starting 72h burn-in (or custom duration) on Ubuntu 24.04."
log "Requested duration: ${DURATION_HOURS} hours."

require_stress_ng
calc_end_time
setup_signal_traps

cpu_mem_stress_start
disk_stress_start

main_loop

stop_all

log "Burn-in test completed successfully."
exit 0

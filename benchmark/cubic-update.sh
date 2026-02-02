#!/usr/bin/env bash

# ==============================================================================
# SCRIPT: benchmark_stress_test.sh
# DESCRIPTION: Hardware performance benchmarking and stress testing for Ubuntu 24.04
# AUTHOR: Bash Master
# ==============================================================================

# ====== USER CONFIGURATION ======
# Define Network Interface and Target IP pairs (Format: "NIC,TargetIP")
NIC_IP_PAIRS=(
  "eth0,8.8.8.8"
  # "eth1,1.1.1.1"
)

# Test Targets: Can be mount points (directories) or raw devices (block devices)
# If empty (), the script automatically detects physical disks (/dev/sdX, /dev/nvmeX)
TEST_TARGETS=()

# Safety switch for raw block devices (/dev/sdX)
# true  = Allow destructive write tests on raw devices (WARNING: WIPES DATA)
# false = Read-only tests for raw devices; directories remain read-write
ALLOW_RAW_WRITE=true

# Enable Burn-in Stress Test (true/false)
ENABLE_BURN_IN=true

# Burn-in Settings
BURN_DURATION_SEC=300       # Duration: 300 seconds (5 minutes)
DL_RATE_LIMIT="100m"        # Network download rate limit: 100MB/s
BURN_IN_MEM_MAX="80%"       # Maximum memory pressure: 80%

# Threshold and Sizing
LATENCY_THRESHOLD_MS=20     # Latency warning threshold (ms)
DISK_TEST_SIZE_MB=1024      # Disk throughput test size (1GB)
LATENCY_TEST_COUNT=50       # Number of samples for latency testing
CPU_TEST_SIZE_MB=512        # CPU SHA256 test data size

# Environment Settings
TIMEZONE="UTC"              # Default to UTC, or e.g., "Asia/Taipei"

# ====== STATE FLAGS & DATA STORAGE ======
ALL_OK=true
declare -a NET_RESULTS
declare -a DISK_RESULTS
CPU_RESULT=""
BG_PIDS=""

# Get script directory and report timestamp
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
REPORT_TIMESTAMP=$(TZ="$TIMEZONE" date +"%Y%m%d_%H%M%S")

# ====== HELPER FUNCTIONS ======

# Get high-precision timestamp
get_time() { TZ="$TIMEZONE" date +%s.%N; }

# Calculate duration between two timestamps
calc_duration() {
    local start=$1; local end=$2
    awk -v s="$start" -v e="$end" 'BEGIN {printf "%.3f", e-s}'
}

# Convert rate string (e.g., 100m) to Bytes per second
convert_rate_to_bytes_per_second() {
    local rate_str="$1"
    local num_part=$(echo "$rate_str" | sed 's/[^0-9.]//g')
    local unit_part=$(echo "$rate_str" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')
    local multiplier=1
    if [[ -z "$num_part" ]]; then echo 0; return; fi
    case "$unit_part" in
        "K") multiplier=$((1024)) ;;
        "M") multiplier=$((1024 * 1024)) ;;
        "G") multiplier=$((1024 * 1024 * 1024)) ;;
        *) multiplier=1 ;;
    esac
    awk -v n="$num_part" -v m="$multiplier" 'BEGIN {printf "%.0f", n * m}'
}

# Check and install required tools
check_install_tool() {
    local tool=$1
    if ! command -v "$tool" &> /dev/null; then
        echo "   -> Tool '$tool' not found. Installing..."
        if command -v apt &> /dev/null; then
            export DEBIAN_FRONTEND=noninteractive
            apt update -qq && apt install -y -qq "$tool" >/dev/null 2>&1
        elif command -v yum &> /dev/null; then
            yum install -y -q "$tool" >/dev/null 2>&1
        fi
    fi
}

# Cleanup and Exit Handling
cleanup() {
    if [ -n "$BG_PIDS" ]; then
        echo -e "\nStopping background processes..."
        kill $BG_PIDS 2>/dev/null
    fi
    rm -f /tmp/test_rw_*.tmp
    for target in "${TEST_TARGETS[@]}"; do
        if [ -d "$target" ]; then
            rm -f "$target"/test_rw_*.tmp "$target"/test_lat_*.tmp
        fi
    done
}

handle_exit() {
    local exit_code=$?
    cleanup
    if [ "$ALL_OK" = false ]; then
        echo -e "\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo " ERROR: An issue occurred during the tests."
        echo " Please check the output above."
        echo " Press [Enter] to close this window..."
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        read -r
    fi
    exit $exit_code
}

trap handle_exit EXIT INT TERM

# ====== START SCRIPT ======

echo "========================================="
echo "   Hardware Benchmark & Stress Test      "
echo "        (Target: Ubuntu 24.04)           "
echo "========================================="
echo

# Auto-detect Disk Devices if none specified
if [ ${#TEST_TARGETS[@]} -eq 0 ]; then
    echo "[Detecting] No targets specified. Scanning for physical disks..."
    mapfile -t DETECTED_DISKS < <(lsblk -dpno NAME,TYPE,RO | awk '$2=="disk" && $3=="0" {print $1}')
    if [ ${#DETECTED_DISKS[@]} -gt 0 ]; then
        TEST_TARGETS=("${DETECTED_DISKS[@]}")
        echo "      Detected: ${TEST_TARGETS[*]}"
    else
        echo "      Error: No usable disk devices found."
        ALL_OK=false
        exit 1
    fi
    echo
fi

# Raw Device Safety Check
if [ "$ALLOW_RAW_WRITE" = true ]; then
    HAS_RAW=false
    for t in "${TEST_TARGETS[@]}"; do [[ -b "$t" ]] && HAS_RAW=true; done
    
    if [ "$HAS_RAW" = true ]; then
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo " WARNING: ALLOW_RAW_WRITE is set to TRUE"
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo " This will perform DESTRUCTIVE write tests on physical disks."
        echo " ALL DATA ON THE TARGETED DISKS WILL BE WIPED."
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo
        echo -n "Type uppercase 'YES' to confirm and proceed, any other key to abort: "
        read -r confirm
        if [ "$confirm" != "YES" ]; then
            echo "Operation aborted by user."
            ALL_OK=false
            exit 1
        fi
        echo "Confirmed. Starting destructive tests..."
        echo
    fi
fi

# ====== 1. NETWORK TEST ======
echo "[1/3] Running Network Latency Benchmarks..."
for pair in "${NIC_IP_PAIRS[@]}"; do
  nic="${pair%,*}"
  ip="${pair#*,}"
  
  if ! ip link show "$nic" >/dev/null 2>&1; then
      echo "   -> Interface $nic not found. Skipping."
      NET_RESULTS+=("$nic -> $ip: Skipped (Interface not found)")
      continue
  fi

  echo -n "   -> Ping $ip via $nic ... "
  ping_output=$(ping -I "$nic" -c 5 "$ip" 2>&1)
  
  if [ $? -eq 0 ]; then
    avg_latency=$(echo "$ping_output" | tail -1 | awk -F '/' '{print $5}')
    avg_latency_float=$(awk -v val="$avg_latency" 'BEGIN {printf "%.2f", val}')
    if (( $(awk -v lat="$avg_latency_float" -v thresh="$LATENCY_THRESHOLD_MS" 'BEGIN {print (lat > thresh)}') )); then
      echo "FAILED (Latency ${avg_latency}ms exceeds threshold)"
      ALL_OK=false
      NET_RESULTS+=("$nic -> $ip: FAILED | Latency: ${avg_latency} ms")
    else
      echo "PASSED (${avg_latency} ms)"
      NET_RESULTS+=("$nic -> $ip: PASSED | Latency: ${avg_latency} ms")
    fi
  else
    echo "FAILED (Connection error or packet loss)"
    ALL_OK=false
    NET_RESULTS+=("$nic -> $ip: FAILED (Timeout/Error)")
  fi
done
echo

# ====== 2. DISK TEST ======
echo "[2/3] Running Disk I/O Performance Tests..."

for target in "${TEST_TARGETS[@]}"; do
  echo "   -> Target: $target ..."
  
  IS_DIR=false
  IS_BLOCK=false
  CAN_WRITE=false
  
  if [ -d "$target" ]; then
      IS_DIR=true; CAN_WRITE=true
      TARGET_WRITE_DST="$target/test_rw_$$.tmp"
      TARGET_READ_SRC="$target/test_rw_$$.tmp"
      LATENCY_FILE="$target/test_lat_$$.tmp"
      echo "      [Type] Directory (File-level test)"
  elif [ -b "$target" ]; then
      IS_BLOCK=true
      CAN_WRITE=$ALLOW_RAW_WRITE
      echo "      [Type] Block Device (Raw-level test - Write allowed: $CAN_WRITE)"
      TARGET_WRITE_DST="$target"
      TARGET_READ_SRC="$target"
      LATENCY_FILE="$target"
  else
      echo "      Error: Invalid target type."
      ALL_OK=false
      DISK_RESULTS+=("$target: Invalid target")
      continue
  fi

  # --- A. Throughput Test ---
  speed_w="N/A"
  if [ "$CAN_WRITE" = true ]; then
      echo -n "      [Speed] Write Test (${DISK_TEST_SIZE_MB}MB)... "
      start_w=$(get_time)
      if ! dd if=/dev/zero of="$TARGET_WRITE_DST" bs=1M count=$DISK_TEST_SIZE_MB oflag=direct status=none 2>/dev/null; then
          echo "FAILED"
          ALL_OK=false
          DISK_RESULTS+=("$target: Write Failed")
          continue
      fi
      end_w=$(get_time)
      dur_w=$(calc_duration "$start_w" "$end_w")
      speed_w=$(awk -v size="$DISK_TEST_SIZE_MB" -v time="$dur_w" 'BEGIN {printf "%.2f", size/time}')
      echo "Done (${speed_w} MB/s)"
  fi
  
  speed_r="N/A"
  echo -n "      [Speed] Read Test (${DISK_TEST_SIZE_MB}MB)... "
  start_r=$(get_time)
  if ! dd if="$TARGET_READ_SRC" of=/dev/null bs=1M count=$DISK_TEST_SIZE_MB iflag=direct status=none 2>/dev/null; then
      echo "FAILED"
      ALL_OK=false
      DISK_RESULTS+=("$target: Read Failed")
  else
      end_r=$(get_time)
      dur_r=$(calc_duration "$start_r" "$end_r")
      speed_r=$(awk -v size="$DISK_TEST_SIZE_MB" -v time="$dur_r" 'BEGIN {printf "%.2f", size/time}')
      echo "Done (${speed_r} MB/s)"
  fi
  
  [[ "$IS_DIR" = true ]] && rm -f "$TARGET_WRITE_DST"

  # --- B. Latency Test ---
  LAT_TYPE="Write"; [[ "$CAN_WRITE" = false ]] && LAT_TYPE="Read"
  echo -n "      [Latency] Avg $LAT_TYPE Latency ($LATENCY_TEST_COUNT samples)... "
  
  TOTAL_LAT_SEC=0
  for ((i=1; i<=LATENCY_TEST_COUNT; i++)); do
      start_l=$(get_time)
      if [ "$CAN_WRITE" = true ]; then
          dd if=/dev/zero of="$LATENCY_FILE" bs=4k count=1 oflag=direct,dsync status=none 2>/dev/null
      else
          dd if="$LATENCY_FILE" of=/dev/null bs=4k count=1 iflag=direct,dsync status=none 2>/dev/null
      fi
      end_l=$(get_time)
      run_dur=$(calc_duration "$start_l" "$end_l")
      TOTAL_LAT_SEC=$(awk -v tot="$TOTAL_LAT_SEC" -v val="$run_dur" 'BEGIN {print tot + val}')
  done
  
  [[ "$IS_DIR" = true ]] && rm -f "$LATENCY_FILE"
  LATENCY_MS=$(awk -v tot="$TOTAL_LAT_SEC" -v count="$LATENCY_TEST_COUNT" 'BEGIN {printf "%.2f", (tot / count) * 1000}')

  if (( $(awk -v lat="$LATENCY_MS" -v thresh="$LATENCY_THRESHOLD_MS" 'BEGIN {print (lat > thresh)}') )); then
      echo "EXCEEDED (${LATENCY_MS}ms)"
      ALL_OK=false
      DISK_RESULTS+=("$target: W:${speed_w} R:${speed_r} | Latency: ${LATENCY_MS}ms (High)")
  else
      echo "PASSED (${LATENCY_MS}ms)"
      DISK_RESULTS+=("$target: W:${speed_w} R:${speed_r} | Latency: ${LATENCY_MS}ms")
  fi
done
echo

# ====== 3. CPU BENCHMARK ======
echo "[3/3] Running CPU SHA256 Computational Test..."
echo -n "   -> Processing $CPU_TEST_SIZE_MB MB data ... "
start_cpu=$(get_time)
if dd if=/dev/zero bs=1M count=$CPU_TEST_SIZE_MB status=none | sha256sum >/dev/null 2>&1; then
    end_cpu=$(get_time)
    dur_cpu=$(calc_duration "$start_cpu" "$end_cpu")
    echo "Done (Time taken: ${dur_cpu}s)"
    CPU_RESULT="Processed ${CPU_TEST_SIZE_MB}MB in ${dur_cpu}s"
else
    echo "FAILED"
    ALL_OK=false
    CPU_RESULT="Failed"
fi
echo

# ====== SUMMARY REPORT ======
FINAL_STATUS="Failed"
[[ "$ALL_OK" = true ]] && FINAL_STATUS="Successful"
REPORT_FILENAME="${SCRIPT_DIR}/benchmark_report_${REPORT_TIMESTAMP}_${FINAL_STATUS}.txt"

{
echo "#############################################"
echo "           Benchmark Summary Report          "
echo "#############################################"
echo "Time: $(TZ="$TIMEZONE" date)"
echo
echo "--- [ Network Latency ] ---"
for res in "${NET_RESULTS[@]}"; do echo "  • $res"; done
echo
echo "--- [ Disk Performance ] ---"
for res in "${DISK_RESULTS[@]}"; do echo "  • $res"; done
echo
echo "--- [ CPU Performance ] ---"
echo "  • $CPU_RESULT"
echo
if [ "$ALL_OK" = true ]; then
  echo "Overall Status: ✔ SUCCESS"
else
  echo "Overall Status: ✘ FAILED"
fi
echo "#############################################"
} | tee "$REPORT_FILENAME"

# ====== 4. STRESS TEST (BURN-IN) ======
if [ "$ALL_OK" = true ] && [ "$ENABLE_BURN_IN" = true ]; then
    echo
    echo "========================================="
    echo "      Starting Burn-in Stress Test       "
    echo "========================================="
    
    check_install_tool "wget"
    check_install_tool "stress-ng"
    
    # Background Network Download Stress
    if [ ${#NIC_IP_PAIRS[@]} -gt 0 ] && command -v wget &> /dev/null; then
        DL_RATE_BPS=$(convert_rate_to_bytes_per_second "$DL_RATE_LIMIT")
        DOWNLOAD_BYTES=$((DL_RATE_BPS * BURN_DURATION_SEC))
        DL_URL="https://speed.cloudflare.com/__down?bytes=$((DOWNLOAD_BYTES > 0 ? DOWNLOAD_BYTES : 1))"
        
        echo "[Network] Starting background download stress ($DL_RATE_LIMIT)..."
        wget --limit-rate="${DL_RATE_LIMIT}" -O /dev/null "$DL_URL" -q &
        BG_PIDS="$BG_PIDS $!"
    fi

    BURN_START_TIME=$(TZ="$TIMEZONE" date +"%Y-%m-%d %H:%M:%S")
    echo "[Time] Burn-in Start: ${BURN_START_TIME}"
    echo "[Time] Target Duration: ${BURN_DURATION_SEC} seconds"
    
    echo "[System] Initiating CPU/RAM/IO load via stress-ng..."
    if command -v stress-ng &> /dev/null; then
        BURN_IN_DIR="/tmp/burnin_$(date +%s)"
        mkdir -p "${BURN_IN_DIR}"
        
        # stress-ng configuration
        # --hdd 4: 4 workers for Disk I/O
        # --cpu 0: Load all available CPUs
        # --vm 1: 1 worker for Virtual Memory
        stress-ng \
            --hdd 4 \
            --hdd-opts direct,wr-seq \
            --temp-path "${BURN_IN_DIR}" \
            --cpu 0 \
            --vm 1 \
            --vm-bytes "${BURN_IN_MEM_MAX}" \
            --timeout "${BURN_DURATION_SEC}s" \
            --metrics-brief &
        
        BG_PIDS="$BG_PIDS $!"
        wait $! 2>/dev/null
        rm -rf "${BURN_IN_DIR}"
    else
        echo "stress-ng not found. Falling back to simple Bash loop (CPU only)..."
        for i in $(seq 1 $(nproc)); do ( while :; do sha256sum /dev/zero >/dev/null 2>&1; done ) & BG_PIDS="$BG_PIDS $!"; done
        sleep "${BURN_DURATION_SEC}"
    fi
    echo "Burn-in stress test completed."
    echo "========================================="
    echo "Full report saved to: $REPORT_FILENAME"
fi

# Exit handled by trap handle_exit
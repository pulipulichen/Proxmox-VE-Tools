#!/usr/bin/env bash

# ====== User Configuration ======
# Declare NIC and IP pairs (each element is "nic,ip")
NIC_IP_PAIRS=(
  "eth0,8.8.8.8"
#   "eth1,172.22.61.31"
)

# Test Targets: Can be Mount Points (Directories) OR Raw Devices (Block Devices)
# Examples: "/mnt/vol1" (Safe, file-based) OR "/dev/sda" (Raw, read-only by default)
TEST_TARGETS=("/mnt/vol1" "/mnt/vol2")
# TEST_TARGETS=("/dev/sda" "/dev/sdb") # Example for raw devices

# Safety Switch for Raw Devices (/dev/sdX)
# true = Allow destructive write tests on raw devices (WARNING: WIPES DATA)
# false = Read-only tests for raw devices, full RW for mount points
ALLOW_RAW_WRITE=true

# Enable/Disable Burn-in Stress Test (true/false)
ENABLE_BURN_IN=true

# Burn-in Configuration
BURN_DURATION_SEC=300       # 5 Minutes
# BURN_DURATION_SEC=30      # Uncomment for short testing
DL_RATE_LIMIT="100m"        # 100MB/s

#BURN_IN_MEM_MAX="20G"
BURN_IN_MEM_MAX="80%"       # Max is 80%

# Thresholds
LATENCY_THRESHOLD_MS=20
DISK_TEST_SIZE_MB=1024
LATENCY_TEST_COUNT=100      # Number of iterations for latency averaging

# Timezone Configuration
TIMEZONE="Asia/Taipei"

# ====== Status Flags & Data Storage ======
CPU_TEST_SIZE_MB=512

# Helper to calc bytes
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
        "") multiplier=1 ;;
    esac
    awk -v n="$num_part" -v m="$multiplier" 'BEGIN {printf "%.0f", n * m}'
}

DL_RATE_BPS=$(convert_rate_to_bytes_per_second "$DL_RATE_LIMIT")
DOWNLOAD_BYTES=$((DL_RATE_BPS * BURN_DURATION_SEC))
DL_URL="https://speed.cloudflare.com/__down?bytes=$((DOWNLOAD_BYTES > 0 ? DOWNLOAD_BYTES : 1))"

ALL_OK=true
declare -a NET_RESULTS
declare -a DISK_RESULTS
CPU_RESULT=""

REPORT_TIMESTAMP=$(TZ="$TIMEZONE" date +"%Y%m%d_%H%M%S")
FINAL_STATUS_TEXT="Failed"
REPORT_FILENAME="benchmark_report_${REPORT_TIMESTAMP}_${FINAL_STATUS_TEXT}.txt"

# ====== Helper Functions ======
get_time() { TZ="$TIMEZONE" date +%s.%N; }

calc_duration() {
    start=$1; end=$2
    awk -v s="$start" -v e="$end" 'BEGIN {printf "%.3f", e-s}'
}

check_install_tool() {
    local tool=$1
    if ! command -v "$tool" &> /dev/null; then
        echo "   -> Installing $tool..."
        if command -v apt &> /dev/null; then
            export DEBIAN_FRONTEND=noninteractive
            apt update -qq && apt install -y -qq "$tool" >/dev/null 2>&1
        elif command -v yum &> /dev/null; then
            yum install -y -q "$tool" >/dev/null 2>&1
        fi
    fi
}

cleanup() {
    if [ -n "$BG_PIDS" ]; then
        echo; echo "Stopping background processes..."; kill $BG_PIDS 2>/dev/null
    fi
    rm -f /tmp/test_rw_*.tmp
    # Only clean up files in directories, not raw devices
    for target in "${TEST_TARGETS[@]}"; do
        if [ -d "$target" ]; then
            rm -f "$target"/test_rw_*.tmp "$target"/test_lat_*.tmp
        fi
    done
}
trap cleanup EXIT INT TERM

echo "========================================="
echo "      System Benchmark (Hybrid Mode)     "
echo "========================================="
echo

# ====== SAFETY CHECK: RAW WRITE CONFIRMATION ======
if [ "$ALLOW_RAW_WRITE" = true ]; then
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo " WARNING: ALLOW_RAW_WRITE is set to TRUE"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo " You are about to run DESTRUCTIVE WRITE tests on raw devices."
    echo " Any data on the specified raw block devices WILL BE WIPED."
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo
    echo -n "Type 'YES' to confirm and continue, or anything else to abort: "
    read -r confirm
    if [ "$confirm" != "YES" ]; then
        echo "Aborted by user."
        exit 1
    fi
    echo "Confirmed. Proceeding with destructive tests..."
    echo
fi

# ====== 1. Network Test ======
echo "[1/3] Running Network Latency Test..."
for pair in "${NIC_IP_PAIRS[@]}"; do
  nic="${pair%,*}"
  ip="${pair#*,}"
  
  # Check if interface exists
  if ! ip link show "$nic" >/dev/null 2>&1; then
      echo "   -> Interface $nic not found. Skipping."
      NET_RESULTS+=("$nic -> $ip: SKIPPED (Interface missing)")
      continue
  fi

  echo -n "   -> Pinging $ip via $nic ... "
  ping_output=$(ping -I "$nic" -c 3 "$ip" 2>&1)
  
  if [ $? -eq 0 ]; then
    avg_latency=$(echo "$ping_output" | tail -1 | awk -F '/' '{print $5}')
    avg_latency_float=$(awk -v val="$avg_latency" 'BEGIN {printf "%.2f", val}')
    if (( $(awk -v lat="$avg_latency_float" -v thresh="$LATENCY_THRESHOLD_MS" 'BEGIN {print (lat > thresh)}') )); then
      echo "FAILED (Latency ${avg_latency}ms)"
      ALL_OK=false
      NET_RESULTS+=("$nic -> $ip: FAILED | Latency: ${avg_latency} ms")
    else
      echo "OK (${avg_latency} ms)"
      NET_RESULTS+=("$nic -> $ip: SUCCESS | Latency: ${avg_latency} ms")
    fi
  else
    echo "FAILED"
    ALL_OK=false
    NET_RESULTS+=("$nic -> $ip: FAILED (Packet Loss)")
  fi
done
echo

# ====== 2. Hybrid Disk Test (Dir vs Raw) ======
echo "[2/3] Running Disk I/O Test..."

for target in "${TEST_TARGETS[@]}"; do
  echo "   -> Testing $target ..."
  
  # Determine Mode
  IS_DIR=false
  IS_BLOCK=false
  CAN_WRITE=false
  
  TARGET_READ_SRC=""
  TARGET_WRITE_DST=""
  LATENCY_FILE=""
  
  if [ -d "$target" ]; then
      IS_DIR=true
      CAN_WRITE=true
      TARGET_WRITE_DST="$target/test_rw_$$.tmp"
      TARGET_READ_SRC="$target/test_rw_$$.tmp"
      LATENCY_FILE="$target/test_lat_$$.tmp"
      echo "      [Type] Directory (File-level test)"
  elif [ -b "$target" ]; then
      IS_BLOCK=true
      if [ "$ALLOW_RAW_WRITE" = true ]; then
          CAN_WRITE=true
          echo "      [Type] Block Device (DESTRUCTIVE WRITE ENABLED)"
      else
          CAN_WRITE=false
          echo "      [Type] Block Device (Read-Only Mode)"
      fi
      TARGET_WRITE_DST="$target"
      TARGET_READ_SRC="$target"
      LATENCY_FILE="$target"
  else
      echo "      ERROR: Target not found or invalid type."
      ALL_OK=false
      DISK_RESULTS+=("$target: Not found/Invalid")
      continue
  fi

  # --- A. THROUGHPUT TEST ---
  
  # 1. Write Test
  speed_w="N/A"
  if [ "$CAN_WRITE" = true ]; then
      echo -n "      [Speed] Writing 1GB... "
      start_w=$(get_time)
      # For raw devices, this overwrites start of disk
      if ! dd if=/dev/zero of="$TARGET_WRITE_DST" bs=1M count=$DISK_TEST_SIZE_MB oflag=direct status=none 2>/dev/null; then
          echo "FAILED"
          ALL_OK=false
          DISK_RESULTS+=("$target: Write Failed")
          continue
      fi
      end_w=$(get_time)
      dur_w=$(calc_duration "$start_w" "$end_w")
      speed_w=$(awk -v size="$DISK_TEST_SIZE_MB" -v time="$dur_w" 'BEGIN {printf "%.2f", size/time}')
      echo "Done (${speed_w} MB/s)."
  else
      echo "      [Speed] Writing skipped (Safety or N/A)"
  fi
  
  # 2. Read Test
  # If directory mode, we can only read if write succeeded (file exists).
  # If block mode, we can always read.
  DO_READ=false
  if [ "$IS_BLOCK" = true ]; then
      DO_READ=true
  elif [ "$IS_DIR" = true ] && [ "$CAN_WRITE" = true ]; then
      # Check if file exists
      if [ -f "$TARGET_READ_SRC" ]; then DO_READ=true; fi
  fi

  speed_r="N/A"
  if [ "$DO_READ" = true ]; then
      echo -n "      [Speed] Reading 1GB... "
      start_r=$(get_time)
      if ! dd if="$TARGET_READ_SRC" of=/dev/null bs=1M count=$DISK_TEST_SIZE_MB iflag=direct status=none 2>/dev/null; then
          echo "FAILED"
          ALL_OK=false
          DISK_RESULTS+=("$target: Read Failed")
      else
          end_r=$(get_time)
          dur_r=$(calc_duration "$start_r" "$end_r")
          speed_r=$(awk -v size="$DISK_TEST_SIZE_MB" -v time="$dur_r" 'BEGIN {printf "%.2f", size/time}')
          echo "Done (${speed_r} MB/s)."
      fi
  else
       echo "      [Speed] Reading skipped (No source file)"
  fi
  
  # Cleanup temp file if directory
  if [ "$IS_DIR" = true ]; then rm -f "$TARGET_WRITE_DST"; fi

  # --- B. LATENCY TEST (Avg) ---
  # Strategy: If CAN_WRITE, test Write Latency. If Read-Only, test Read Latency.
  LAT_TYPE="Write"
  if [ "$CAN_WRITE" = false ]; then LAT_TYPE="Read"; fi
  
  echo -n "      [Latency] Checking $LAT_TYPE IOPS latency (Avg of $LATENCY_TEST_COUNT)... "
  
  TOTAL_LAT_SEC=0
  
  # Warmup
  if [ "$LAT_TYPE" = "Write" ]; then
      dd if=/dev/zero of="$LATENCY_FILE" bs=4k count=1 oflag=direct,dsync status=none 2>/dev/null
  else
      # Read warmup
      dd if="$LATENCY_FILE" of=/dev/null bs=4k count=1 iflag=direct,dsync status=none 2>/dev/null
  fi
  
  for ((i=1; i<=LATENCY_TEST_COUNT; i++)); do
      start_l=$(get_time)
      if [ "$LAT_TYPE" = "Write" ]; then
          dd if=/dev/zero of="$LATENCY_FILE" bs=4k count=1 oflag=direct,dsync status=none 2>/dev/null
      else
          dd if="$LATENCY_FILE" of=/dev/null bs=4k count=1 iflag=direct,dsync status=none 2>/dev/null
      fi
      end_l=$(get_time)
      
      run_dur=$(calc_duration "$start_l" "$end_l")
      TOTAL_LAT_SEC=$(awk -v tot="$TOTAL_LAT_SEC" -v val="$run_dur" 'BEGIN {print tot + val}')
  done
  
  if [ "$IS_DIR" = true ]; then rm -f "$LATENCY_FILE"; fi
  
  LATENCY_MS=$(awk -v tot="$TOTAL_LAT_SEC" -v count="$LATENCY_TEST_COUNT" 'BEGIN {printf "%.2f", (tot / count) * 1000}')

  if (( $(awk -v lat="$LATENCY_MS" -v thresh="$LATENCY_THRESHOLD_MS" 'BEGIN {print (lat > thresh)}') )); then
      echo "FAILED (${LATENCY_MS}ms)"
      ALL_OK=false
      DISK_RESULTS+=("$target: W:${speed_w} R:${speed_r} | Lat: ${LATENCY_MS}ms ($LAT_TYPE) (High)")
  else
      echo "OK (${LATENCY_MS}ms)"
      DISK_RESULTS+=("$target: W:${speed_w} R:${speed_r} | Lat: ${LATENCY_MS}ms ($LAT_TYPE)")
  fi

done
echo

# ====== 3. CPU Benchmark ======
echo "[3/3] Running CPU SHA256 Benchmark..."
echo -n "   -> Hashing $CPU_TEST_SIZE_MB MB of zeros ... "
start_cpu=$(get_time)
if dd if=/dev/zero bs=1M count=$CPU_TEST_SIZE_MB status=none | sha256sum >/dev/null 2>&1; then
    end_cpu=$(get_time)
    dur_cpu=$(calc_duration "$start_cpu" "$end_cpu")
    echo "DONE in ${dur_cpu}s"
    CPU_RESULT="Processed ${CPU_TEST_SIZE_MB}MB in ${dur_cpu}s"
else
    echo "FAILED"
    ALL_OK=false
    CPU_RESULT="FAILED"
fi
echo

# ====== Final Summary ======
if [ "$ALL_OK" = true ]; then FINAL_STATUS_TEXT="Successful"; fi
REPORT_FILENAME="benchmark_report_${REPORT_TIMESTAMP}_${FINAL_STATUS_TEXT}.txt"

(
echo "#############################################"
echo "           BENCHMARK SUMMARY REPORT          "
echo "#############################################"
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
  echo "OVERALL STATUS: ✔ SUCCESS"
else
  echo "OVERALL STATUS: ✘ FAILED"
fi
echo "#############################################"
) | tee "$REPORT_FILENAME"

# ====== 4. Stress Test ======
if [ "$ALL_OK" = true ] && [ "$ENABLE_BURN_IN" = true ]; then
    echo "========================================="
    echo "      Starting Burn-in Test              "
    echo "========================================="
    BG_PIDS=""
    
    check_install_tool "wget"
    check_install_tool "stress-ng"
    
    if [ ${#NIC_IP_PAIRS[@]} -gt 0 ] && command -v wget &> /dev/null; then
        echo "[Network] Starting background download..."
        wget --limit-rate="${DL_RATE_LIMIT}" -O /dev/null "$DL_URL" -q &
        BG_PIDS="$BG_PIDS $!"
    fi
    
    echo "[System]  Starting Stress Load..."
    if command -v stress-ng &> /dev/null; then
        BURN_IN_DIR="/tmp/burnin_$(date +%s)"
        mkdir -p "${BURN_IN_DIR}"
        
        # stress-ng HDD stress logic: 
        # If we have mount points, use temp dir. If only raw devices, use generic /tmp stress.
        stress-ng \
            --hdd 8 \
            --hdd-opts direct,wr-seq \
            --temp-path "${BURN_IN_DIR}" \
            --cpu 0 --vm 1 --vm-bytes "${BURN_IN_MEM_MAX}" --timeout "${BURN_DURATION_SEC}s" --metrics-brief &
        
        BG_PIDS="$BG_PIDS $!"
        wait $! 2>/dev/null
        rm -rf "${BURN_IN_DIR}"
    else
        echo "Fallback: Using raw bash loops"
        for i in {1..2}; do ( while :; do sha256sum /dev/zero >/dev/null 2>&1; done ) & BG_PIDS="$BG_PIDS $!"; done
        sleep "${BURN_DURATION_SEC}"
    fi
    echo "Burn-in Completed."
fi
#!/usr/bin/env bash

# ====== User Configuration ======
# Declare NIC and IP pairs (each element is "nic,ip")
NIC_IP_PAIRS=(
  "eth0,8.8.8.8"
#   "eth1,172.22.61.31"
)

# Mount points to test (read/write operations will be performed here)
MOUNT_POINTS=("/mnt/vol1" "/mnt/vol2")

# Enable/Disable Burn-in Stress Test (true/false)
ENABLE_BURN_IN=true

# Burn-in Configuration
BURN_DURATION_SEC=300       # 5 Minutes
BURN_DURATION_SEC=10      # Uncomment for short testing
DL_RATE_LIMIT="100m"        # 100MB/s
BURN_IN_MEM_MAX="20G"

# Thresholds
LATENCY_THRESHOLD_MS=20
DISK_TEST_SIZE_MB=1024
LATENCY_TEST_COUNT=100        # <--- NEW: Number of iterations for latency averaging

# Timezone Configuration
TIMEZONE="Asia/Taipei" # Default timezone for reports and timestamps

# ====== Status Flags & Data Storage ======
CPU_TEST_SIZE_MB=512

# Calculate download bytes dynamically
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

# Report file variables
REPORT_TIMESTAMP=$(TZ="$TIMEZONE" date +"%Y%m%d_%H%M%S")
FINAL_STATUS_TEXT="Failed" # Default to FAILED
REPORT_FILENAME="benchmark_report_${REPORT_TIMESTAMP}_${FINAL_STATUS_TEXT}.txt"

# ====== Helper Functions ======
get_time() {
    TZ="$TIMEZONE" date +%s.%N
}

calc_duration() {
    start=$1
    end=$2
    awk -v s="$start" -v e="$end" 'BEGIN {printf "%.3f", e-s}'
}

check_install_tool() {
    local tool=$1
    if ! command -v "$tool" &> /dev/null; then
        echo "   -> Installing $tool for accurate testing..."
        # Quietly try to install common tools
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
        echo
        echo "Stopping background stress/download processes..."
        # shellcheck disable=SC2086
        kill $BG_PIDS 2>/dev/null
    fi
    # Cleanup any temp files
    rm -f /tmp/test_rw_*.tmp
    for mount in "${MOUNT_POINTS[@]}"; do
        rm -f "$mount"/test_rw_*.tmp "$mount"/test_lat_*.tmp
    done
}
trap cleanup EXIT INT TERM

echo "========================================="
echo "      System Benchmark & Health Check    "
echo "========================================="
echo

# ====== 1. Network Test ======
echo "[1/3] Running Network Latency Test..."
for pair in "${NIC_IP_PAIRS[@]}"; do
  nic="${pair%,*}"
  ip="${pair#*,}"
  
  echo -n "   -> Pinging $ip via $nic ... "
  
  ping_output=$(ping -I "$nic" -c 3 "$ip" 2>&1)
  
  if [ $? -eq 0 ]; then
    avg_latency=$(echo "$ping_output" | tail -1 | awk -F '/' '{print $5}')
    avg_latency_float=$(awk -v val="$avg_latency" 'BEGIN {printf "%.2f", val}')
    
    if (( $(awk -v lat="$avg_latency_float" -v thresh="$LATENCY_THRESHOLD_MS" 'BEGIN {print (lat > thresh)}') )); then
      echo "FAILED (Latency ${avg_latency}ms > ${LATENCY_THRESHOLD_MS}ms)"
      ALL_OK=false
      NET_RESULTS+=("$nic -> $ip: FAILED | Latency: ${avg_latency} ms (High)")
    else
      echo "OK (${avg_latency} ms)"
      NET_RESULTS+=("$nic -> $ip: SUCCESS | Latency: ${avg_latency} ms")
    fi
  else
    echo "FAILED"
    ALL_OK=false
    NET_RESULTS+=("$nic -> $ip: FAILED (Packet Loss/Unreachable)")
  fi
done
echo

# ====== 2. Disk I/O Test (Fixed Latency Logic) ======
echo "[2/3] Running Disk I/O Test..."

# Use DD fallback loop for consistent averaging
# check_install_tool "ioping" # Not needed as we use manual DD averaging now

for mount in "${MOUNT_POINTS[@]}"; do
  echo "   -> Testing $mount ..."
  
  if [ ! -d "$mount" ]; then
     echo "      ERROR: Directory not found"
     ALL_OK=false
     DISK_RESULTS+=("$mount: Directory not found")
     continue
  fi

  TEST_FILE="$mount/test_rw_$$.tmp"
  LAT_FILE="$mount/test_lat_$$.tmp"
  
  # --- A. THROUGHPUT TEST (Bandwidth) ---
  echo -n "      [Speed] Writing 1GB... "
  
  start_w=$(get_time)
  if ! dd if=/dev/zero of="$TEST_FILE" bs=1M count=$DISK_TEST_SIZE_MB oflag=direct status=none 2>/dev/null; then
      echo "FAILED"
      ALL_OK=false
      DISK_RESULTS+=("$mount: Write Speed FAILED")
      continue
  fi
  end_w=$(get_time)
  dur_w=$(calc_duration "$start_w" "$end_w")
  speed_w=$(awk -v size="$DISK_TEST_SIZE_MB" -v time="$dur_w" 'BEGIN {printf "%.2f", size/time}')
  
  echo -n "Done (${speed_w} MB/s). Reading... "
  
  start_r=$(get_time)
  if ! dd if="$TEST_FILE" of=/dev/null bs=1M count=$DISK_TEST_SIZE_MB iflag=direct status=none 2>/dev/null; then
      echo "FAILED"
      ALL_OK=false
      DISK_RESULTS+=("$mount: Read Speed FAILED")
      rm -f "$TEST_FILE"
      continue
  fi
  end_r=$(get_time)
  dur_r=$(calc_duration "$start_r" "$end_r")
  speed_r=$(awk -v size="$DISK_TEST_SIZE_MB" -v time="$dur_r" 'BEGIN {printf "%.2f", size/time}')
  
  echo "Done (${speed_r} MB/s)."
  rm -f "$TEST_FILE"

  # --- B. LATENCY TEST (Response Time - Averaged) ---
  echo -n "      [Latency] Checking IOPS latency (Avg of $LATENCY_TEST_COUNT runs)... "
  
  TOTAL_LAT_SEC=0
  
  # 1. Warmup (do one run without counting time to wake up disks)
  dd if=/dev/zero of="$LAT_FILE" bs=4k count=1 oflag=direct,dsync status=none 2>/dev/null
  
  # 2. Measurement Loop
  for ((i=1; i<=LATENCY_TEST_COUNT; i++)); do
      start_l=$(get_time)
      # Perform a single 4k sync write
      dd if=/dev/zero of="$LAT_FILE" bs=4k count=1 oflag=direct,dsync status=none 2>/dev/null
      end_l=$(get_time)
      
      # Calc duration for this iteration
      run_dur=$(calc_duration "$start_l" "$end_l")
      
      # Add to total
      TOTAL_LAT_SEC=$(awk -v tot="$TOTAL_LAT_SEC" -v val="$run_dur" 'BEGIN {print tot + val}')
  done
  
  rm -f "$LAT_FILE"
  
  # 3. Calculate Average
  # (Total Sec / Count) * 1000 = Avg ms
  LATENCY_MS=$(awk -v tot="$TOTAL_LAT_SEC" -v count="$LATENCY_TEST_COUNT" 'BEGIN {printf "%.2f", (tot / count) * 1000}')

  # Check Threshold
  if (( $(awk -v lat="$LATENCY_MS" -v thresh="$LATENCY_THRESHOLD_MS" 'BEGIN {print (lat > thresh)}') )); then
      echo "FAILED (${LATENCY_MS}ms > ${LATENCY_THRESHOLD_MS}ms)"
      ALL_OK=false
      DISK_RESULTS+=("$mount: R/W Speed OK | Latency: ${LATENCY_MS}ms (Avg) (FAILED > ${LATENCY_THRESHOLD_MS}ms)")
  else
      echo "OK (${LATENCY_MS}ms)"
      DISK_RESULTS+=("$mount: Speed: W:${speed_w}MB/s R:${speed_r}MB/s | Latency: ${LATENCY_MS}ms (Avg)")
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

# ====== Final Summary Report ======
if [ "$ALL_OK" = true ]; then
  FINAL_STATUS_TEXT="Successful"
fi
REPORT_FILENAME="benchmark_report_${REPORT_TIMESTAMP}_${FINAL_STATUS_TEXT}.txt"

(
echo "#############################################"
echo "           BENCHMARK SUMMARY REPORT          "
echo "#############################################"
echo
echo "--- [ Network Latency ] ---"
for res in "${NET_RESULTS[@]}"; do
  echo "  • $res"
done
echo
echo "--- [ Disk Performance ] ---"
for res in "${DISK_RESULTS[@]}"; do
  echo "  • $res"
done
echo
echo "--- [ CPU Performance ] ---"
echo "  • $CPU_RESULT"
echo
if [ "$ALL_OK" = true ]; then
  echo "OVERALL STATUS: ✔ SUCCESS"
else
  echo "OVERALL STATUS: ✘ FAILED (Check errors above)"
fi
echo "#############################################"
echo
) | tee "$REPORT_FILENAME"

# ====== 4. Stress Test (Burn-in) ======
if [ "$ALL_OK" = true ] && [ "$ENABLE_BURN_IN" = true ]; then
    echo "========================================="
    echo "      Starting ${BURN_DURATION_SEC/60}-Minute Burn-in Test     "
    echo "========================================="
    echo "Duration: ${BURN_DURATION_SEC} seconds"
    echo "Target:   CPU, Memory, IO Stress + Download"
    
    BG_PIDS=""
    
    # 4.1 Install Tools
    check_install_tool "wget"
    check_install_tool "stress-ng"
    
    # 4.2 Network Stress
    if [ ${#NIC_IP_PAIRS[@]} -eq 0 ]; then
        echo "[Network] Skipping background download: NIC_IP_PAIRS is empty."
    elif command -v wget &> /dev/null; then
        echo "[Network] Starting background download..."
        wget --limit-rate="${DL_RATE_LIMIT}" -O /dev/null "$DL_URL" -q &
        BG_PIDS="$BG_PIDS $!"
    else
        echo "[Network] Skipping background download: wget not found."
    fi
    
    # 4.3 System Stress
    echo "[System]  Starting Stress Load (stress-ng)..."
    if command -v stress-ng &> /dev/null; then
        BURN_IN_DIR="/tmp/burnin_$(date +%s)"
        mkdir -p "${BURN_IN_DIR}"
        
        stress-ng \
            --hdd 4 \
            --hdd-opts direct,wr-seq \
            --hdd-write-size 4M \
            --hdd-bytes 80% \
            --temp-path "${BURN_IN_DIR}" \
            --cpu 0 --vm 1 --vm-bytes "${BURN_IN_MEM_MAX}" --timeout "${BURN_DURATION_SEC}s" --metrics-brief &
        
        BG_PIDS="$BG_PIDS $!"
        wait $! 2>/dev/null
        rm -rf "${BURN_IN_DIR}"
    else
        echo "Fallback: Using raw bash loops (stress-ng install failed)"
        # Simple fallback
        for i in {1..2}; do ( while :; do sha256sum /dev/zero >/dev/null 2>&1; done ) & BG_PIDS="$BG_PIDS $!"; done
        sleep "${BURN_DURATION_SEC}"
    fi
    
    echo "Burn-in Completed."
fi

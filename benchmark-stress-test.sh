#!/usr/bin/env bash

# ====== User Configuration ======

# Declare NIC and IP pairs (each element is "nic,ip")
NIC_IP_PAIRS=(
  "eth0,8.8.8.8"
  "eth1,172.22.61.31"
)

# Mount points to test (read/write operations will be performed here)
MOUNT_POINTS=("/mnt/vol1" "/mnt/vol2")

# Enable/Disable Burn-in Stress Test (true/false)
ENABLE_BURN_IN=true

# ====== Status Flags & Data Storage ======

# CPU Test Configuration (Size in MB)
CPU_TEST_SIZE_MB=512

# Burn-in Configuration
BURN_DURATION_SEC=300       # 5 Minutes
DL_RATE_LIMIT="10m"         # 10MB/s
# Note: Increased bytes to 4GB so the download lasts at least 5 mins (4000MB / 10MBps = 400s)
DL_URL="https://speed.cloudflare.com/__down?bytes=4000000000" 

ALL_OK=true
declare -a NET_RESULTS
declare -a DISK_RESULTS
CPU_RESULT=""

# ====== Helper Functions ======

get_time() {
    date +%s.%N
}

calc_duration() {
    start=$1
    end=$2
    awk -v s="$start" -v e="$end" 'BEGIN {printf "%.3f", e-s}'
}

cleanup() {
    # This function kills background processes on exit
    if [ -n "$BG_PIDS" ]; then
        echo
        echo "Stopping background stress/download processes..."
        # shellcheck disable=SC2086
        kill $BG_PIDS 2>/dev/null
    fi
}
# Trap interrupts to ensure cleanup
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
  
  # Run ping, capture output
  ping_output=$(ping -I "$nic" -c 3 "$ip" 2>&1)
  
  if [ $? -eq 0 ]; then
    # Extract avg latency (standard format: rtt min/avg/max/mdev = ... ms)
    avg_latency=$(echo "$ping_output" | tail -1 | awk -F '/' '{print $5}')
    echo "OK (${avg_latency} ms)"
    NET_RESULTS+=("$nic -> $ip: SUCCESS | Avg Latency: ${avg_latency} ms")
  else
    echo "FAILED"
    ALL_OK=false
    NET_RESULTS+=("$nic -> $ip: FAILED")
  fi
done
echo

# ====== 2. Disk I/O Test ======
echo "[2/3] Running Disk Read/Write Speed Test..."
# 1GB Test File
DISK_TEST_SIZE_MB=1024

for mount in "${MOUNT_POINTS[@]}"; do
  TEST_FILE="$mount/test_rw_$$.tmp"
  echo -n "   -> Testing $mount ... "

  # Check if mount point exists/writable first roughly
  if [ ! -d "$mount" ]; then
     echo "FAILED (Dir not found)"
     ALL_OK=false
     DISK_RESULTS+=("$mount: Directory not found")
     continue
  fi

  # --- WRITE TEST ---
  start_w=$(get_time)
  # sync ensures data is actually written to disk, output suppressed
  if ! dd if=/dev/zero of="$TEST_FILE" bs=1M count=$DISK_TEST_SIZE_MB oflag=direct status=none 2>/dev/null; then
      echo "WRITE FAILED"
      ALL_OK=false
      DISK_RESULTS+=("$mount: WRITE FAILED")
      continue
  fi
  end_w=$(get_time)
  dur_w=$(calc_duration "$start_w" "$end_w")
  
  # Calculate Write Speed (MB/s)
  speed_w=$(awk -v size="$DISK_TEST_SIZE_MB" -v time="$dur_w" 'BEGIN {printf "%.2f", size/time}')

  # --- READ TEST ---
  start_r=$(get_time)
  if ! dd if="$TEST_FILE" of=/dev/null bs=1M count=$DISK_TEST_SIZE_MB iflag=direct status=none 2>/dev/null; then
      echo "READ FAILED"
      ALL_OK=false
      rm -f "$TEST_FILE"
      DISK_RESULTS+=("$mount: WRITE OK, READ FAILED")
      continue
  fi
  end_r=$(get_time)
  dur_r=$(calc_duration "$start_r" "$end_r")

  # Calculate Read Speed (MB/s)
  speed_r=$(awk -v size="$DISK_TEST_SIZE_MB" -v time="$dur_r" 'BEGIN {printf "%.2f", size/time}')

  echo "OK (W: ${dur_w}s, R: ${dur_r}s)"
  DISK_RESULTS+=("$mount: Write: ${dur_w}s (${speed_w} MB/s) | Read: ${dur_r}s (${speed_r} MB/s)")

  # Cleanup
  rm -f "$TEST_FILE"
done
echo

# ====== 3. CPU SHA256 Benchmark ======
echo "[3/3] Running CPU SHA256 Benchmark..."
echo -n "   -> Hashing $CPU_TEST_SIZE_MB MB of zeros ... "

start_cpu=$(get_time)
# Pipe /dev/zero to sha256sum. 
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
echo "#############################################"
echo "           BENCHMARK SUMMARY REPORT          "
echo "#############################################"

echo
echo "--- [ Network Latency ] ---"
for res in "${NET_RESULTS[@]}"; do
  echo "  • $res"
done

echo
echo "--- [ Disk I/O Performance (1GB File) ] ---"
for res in "${DISK_RESULTS[@]}"; do
  echo "  • $res"
done

echo
echo "--- [ CPU Performance (SHA256) ] ---"
echo "  • $CPU_RESULT"

echo
if [ "$ALL_OK" = true ]; then
  echo "OVERALL STATUS: ✔ SUCCESS"
else
  echo "OVERALL STATUS: ✘ FAILED (Check errors above)"
fi
echo "#############################################"
echo

# ====== 4. Stress Test (Burn-in) ======
# Only run if all previous checks passed
if [ "$ALL_OK" = true ]; then
    if [ "$ENABLE_BURN_IN" = true ]; then
        echo "========================================="
        echo "      Starting 5-Minute Burn-in Test     "
        echo "========================================="
        echo "Duration: ${BURN_DURATION_SEC} seconds"
        echo "Target:   CPU, Memory, IO Stress + 10MB/s Download"
        echo

        BG_PIDS=""

        # 4.1 Start Network Download (Rate Limited)
        # Check if wget is available, if not, attempt to install
        if ! command -v wget &> /dev/null; then
            echo "[Network] 'wget' not found. Attempting to install via apt..."
            apt update; apt install wget -y
        fi

        # Re-check and run
        if command -v wget &> /dev/null; then
            echo "[Network] Starting background download (Limit: ${DL_RATE_LIMIT})..."
            # -O /dev/null: discard data, -q: quiet, --limit-rate: throttle speed
            wget --limit-rate="${DL_RATE_LIMIT}" -O /dev/null "$DL_URL" -q &
            wget_pid=$!
            BG_PIDS="$BG_PIDS $wget_pid"
            echo "   -> wget PID: $wget_pid"
        else
            echo "[Network] Warning: 'wget' still not found (Installation failed?). Skipping download test."
        fi

        # 4.2 Start System Stress (CPU/Mem/IO)
        echo "[System]  Starting Stress Load..."
        
        # Check if stress-ng is available, if not, attempt to install
        if ! command -v stress-ng &> /dev/null; then
            echo "[System] 'stress-ng' not found. Attempting to install via apt..."
            apt update; apt install stress-ng -y
        fi

        # Re-check and run
        if command -v stress-ng &> /dev/null; then
            # Preferred method: stress-ng (Available via 'apt install stress-ng' or 'yum install stress-ng')
            # --cpu 0: use all cores
            # --vm 2: 2 memory stressors (default 256MB per stressor)
            # --io 2: 2 i/o stressors
            # --timeout: stop after duration
            echo "   -> Using 'stress-ng' (Professional Tool)"
            stress-ng --cpu 0 --io 2 --vm 2 --vm-bytes 512M --timeout "${BURN_DURATION_SEC}s" --metrics-brief &
            stress_pid=$!
            BG_PIDS="$BG_PIDS $stress_pid"
            
            # Wait for stress-ng to finish (it handles the timeout itself)
            wait $stress_pid

        elif command -v stress &> /dev/null; then
            # Fallback method: classic stress
            echo "   -> Using 'stress' (Classic Tool)"
            stress --cpu 4 --io 2 --vm 2 --vm-bytes 512M --timeout "${BURN_DURATION_SEC}s" &
            stress_pid=$!
            BG_PIDS="$BG_PIDS $stress_pid"
            wait $stress_pid

        else
            # "Poor Man's" Fallback if no tools installed
            echo "   -> WARNING: 'stress-ng' not found. Using raw Bash/DD fallback."
            echo "   -> (Install stress-ng for better results: apt/yum install stress-ng)"
            
            # CPU Load: Parallel SHA256 loops (4 threads)
            for i in {1..4}; do
                ( while :; do sha256sum /dev/zero >/dev/null 2>&1; done ) &
                BG_PIDS="$BG_PIDS $!"
            done

            # IO Load: Constant writing to tmp
            ( while :; do dd if=/dev/zero of=/tmp/stress_test_$$ bs=1M count=100 oflag=direct >/dev/null 2>&1; done ) &
            BG_PIDS="$BG_PIDS $!"

            echo "   -> Fallback stress running. Waiting ${BURN_DURATION_SEC} seconds..."
            sleep "${BURN_DURATION_SEC}"
            
            # Kill manual loops
            rm -f /tmp/stress_test_$$
        fi

        echo
        echo "========================================="
        echo "        Burn-in Test Completed           "
        echo "========================================="
    else
        echo
        echo "Burn-in Test Skipped (Disabled in config)."
    fi
else
    echo "Skipping Burn-in Test because health checks failed."
fi

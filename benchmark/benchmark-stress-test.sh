#!/usr/bin/env bash

# ==============================================================================
# SCRIPT: hardware-benchmark.sh
# DESCRIPTION: Hardware performance benchmarking and stress testing for Ubuntu 24.04
# AUTHOR: Bash Master (Optimized for Physical Disks)
# ==============================================================================

# ====== USER CONFIGURATION ======
# Define Network Interface and Target IP pairs (Format: "NIC,TargetIP")
NIC_IP_PAIRS=(
  "eth0,8.8.8.8"
)

# Test Targets: If empty, the script automatically detects PHYSICAL disks
# Explicitly excludes 'nbd', 'loop', 'ram', and 'zram' devices.
TEST_TARGETS=()

# Safety switch for raw block devices (/dev/sdX)
# true  = Allow destructive write tests on raw devices (WARNING: WIPES DATA)
# false = Read-only tests for raw devices
ALLOW_RAW_WRITE=false

# Enable Burn-in Stress Test (true/false)
ENABLE_BURN_IN=true

# Burn-in Settings
BURN_DURATION_SEC=300       # Duration: 5 minutes
DL_RATE_LIMIT="50m"         # Network download rate limit
BURN_IN_MEM_MAX="70%"       # Maximum memory pressure

# Threshold and Sizing
LATENCY_THRESHOLD_MS=20     # Latency warning threshold (ms)
DISK_TEST_SIZE_MB=512       # Disk throughput test size
LATENCY_TEST_COUNT=30       # Number of samples for latency testing
CPU_TEST_SIZE_MB=512        # CPU SHA256 test data size

# Environment Settings
TIMEZONE="UTC"

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

get_time() { TZ="$TIMEZONE" date +%s.%N; }

calc_duration() {
    local start=$1; local end=$2
    awk -v s="$start" -v e="$end" 'BEGIN {printf "%.3f", e-s}'
}

convert_rate_to_bytes() {
    local rate_str="$1"
    local num_part=$(echo "$rate_str" | sed 's/[^0-9.]//g')
    local unit_part=$(echo "$rate_str" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')
    local multiplier=1
    case "$unit_part" in
        "K") multiplier=$((1024)) ;;
        "M") multiplier=$((1024 * 1024)) ;;
        "G") multiplier=$((1024 * 1024 * 1024)) ;;
    esac
    awk -v n="$num_part" -v m="$multiplier" 'BEGIN {printf "%.0f", n * m}'
}

check_install_tool() {
    local tool=$1
    if ! command -v "$tool" &> /dev/null; then
        echo "   -> Tool '$tool' not found. Installing..."
        export DEBIAN_FRONTEND=noninteractive
        sudo apt update -qq && sudo apt install -y -qq "$tool" >/dev/null 2>&1
    fi
}

cleanup() {
    [ -n "$BG_PIDS" ] && kill $BG_PIDS 2>/dev/null
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
        echo -e "\n[!] Some tests failed or warnings were issued."
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

# 1. DISK DETECTION (Filter out nbd, loop, ram)
if [ ${#TEST_TARGETS[@]} -eq 0 ]; then
    echo "[Detecting] Scanning for physical block devices..."
    # lsblk filters:
    # -d: device only (no partitions)
    # -p: full path
    # -n: no header
    # -o: name, type
    # grep -v: exclude nbd, loop, ram, zram
    mapfile -t DETECTED < <(lsblk -dpno NAME,TYPE | grep -vE "nbd|loop|ram|zram" | awk '$2=="disk" {print $1}')
    
    if [ ${#DETECTED[@]} -gt 0 ]; then
        TEST_TARGETS=("${DETECTED[@]}")
        echo "      Physical Disks Found: ${TEST_TARGETS[*]}"
    else
        echo "      Error: No physical disk devices found."
        ALL_OK=false
        exit 1
    fi
    echo
fi

# 2. PRIVILEGE & SAFETY CHECK
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root (sudo)."
   exit 1
fi

if [ "$ALLOW_RAW_WRITE" = true ]; then
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo " WARNING: ALLOW_RAW_WRITE is TRUE. Physical disks will be WIPED."
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    read -p "Type 'YES' to confirm data destruction: " confirm
    [[ "$confirm" != "YES" ]] && { echo "Aborted."; exit 1; }
fi

# ====== SECTION 1: NETWORK ======
echo "[1/3] Network Latency Benchmark"
for pair in "${NIC_IP_PAIRS[@]}"; do
  nic="${pair%,*}"
  ip="${pair#*,}"
  
  if ! ip link show "$nic" >/dev/null 2>&1; then
      echo "   -> $nic: Interface not found."
      NET_RESULTS+=("$nic: Not Found")
      continue
  fi

  echo -n "   -> Ping $ip via $nic: "
  if ping_output=$(ping -I "$nic" -c 5 "$ip" 2>&1); then
    avg=$(echo "$ping_output" | tail -1 | awk -F '/' '{print $5}')
    if (( $(awk -v a="$avg" -v t="$LATENCY_THRESHOLD_MS" 'BEGIN {print (a > t)}') )); then
      echo "WARNING (${avg}ms > ${LATENCY_THRESHOLD_MS}ms)"
      NET_RESULTS+=("$nic: ${avg}ms (High)")
    else
      echo "OK (${avg}ms)"
      NET_RESULTS+=("$nic: ${avg}ms")
    fi
  else
    echo "FAILED"
    ALL_OK=false
    NET_RESULTS+=("$nic: Failed")
  fi
done
echo

# ====== SECTION 2: DISK I/O ======
echo "[2/3] Disk Performance Benchmark"
for target in "${TEST_TARGETS[@]}"; do
  echo "   -> Device: $target"
  
  # Determine if block device or directory
  CAN_WRITE=false
  [[ -b "$target" ]] && CAN_WRITE=$ALLOW_RAW_WRITE
  [[ -d "$target" ]] && CAN_WRITE=true

  # Throughput
  speed_w="N/A"; speed_r="N/A"
  if [ "$CAN_WRITE" = true ]; then
      echo -n "      Write: "
      start=$(get_time)
      dd if=/dev/zero of="$target" bs=1M count=$DISK_TEST_SIZE_MB oflag=direct status=none conv=notrunc 2>/dev/null
      dur=$(calc_duration "$start" "$(get_time)")
      speed_w=$(awk -v s="$DISK_TEST_SIZE_MB" -v d="$dur" 'BEGIN {printf "%.2f", s/d}')
      echo "${speed_w} MB/s"
  fi
  
  echo -n "      Read : "
  start=$(get_time)
  dd if="$target" of=/dev/null bs=1M count=$DISK_TEST_SIZE_MB iflag=direct status=none 2>/dev/null
  dur=$(calc_duration "$start" "$(get_time)")
  speed_r=$(awk -v s="$DISK_TEST_SIZE_MB" -v d="$dur" 'BEGIN {printf "%.2f", s/d}')
  echo "${speed_r} MB/s"

  # Latency
  echo -n "      Latency (Random 4K): "
  TOTAL_L=0
  for ((i=1; i<=LATENCY_TEST_COUNT; i++)); do
      s=$(get_time)
      dd if="$target" of=/dev/null bs=4k count=1 iflag=direct status=none 2>/dev/null
      TOTAL_L=$(awk -v t="$TOTAL_L" -v v="$(calc_duration "$s" "$(get_time)")" 'BEGIN {print t + v}')
  done
  avg_l=$(awk -v t="$TOTAL_L" -c="$LATENCY_TEST_COUNT" 'BEGIN {printf "%.2f", (t/c)*1000}')
  echo "${avg_l} ms"
  
  DISK_RESULTS+=("$target: W:${speed_w} R:${speed_r} L:${avg_l}ms")
done
echo

# ====== SECTION 3: CPU ======
echo "[3/3] CPU SHA256 Benchmark"
echo -n "   -> Processing $CPU_TEST_SIZE_MB MB: "
start=$(get_time)
dd if=/dev/zero bs=1M count=$CPU_TEST_SIZE_MB status=none | sha256sum >/dev/null
dur=$(calc_duration "$start" "$(get_time)")
CPU_RESULT="${CPU_TEST_SIZE_MB}MB in ${dur}s"
echo "Done (${dur}s)"
echo

# ====== REPORT ======
REPORT_FILE="${SCRIPT_DIR}/benchmark_${REPORT_TIMESTAMP}.txt"
{
    echo "Hardware Benchmark Report - $(date)"
    echo "-------------------------------------"
    echo "Network:"
    for r in "${NET_RESULTS[@]}"; do echo "  - $r"; done
    echo "Storage:"
    for r in "${DISK_RESULTS[@]}"; do echo "  - $r"; done
    echo "CPU Result: $CPU_RESULT"
    echo "-------------------------------------"
} | tee "$REPORT_FILE"

# ====== STRESS TEST ======
if [ "$ENABLE_BURN_IN" = true ]; then
    echo -e "\nStarting Burn-in Stress Test (${BURN_DURATION_SEC}s)..."
    check_install_tool "stress-ng"
    check_install_tool "wget"

    # Network Stress
    DL_BYTES=$(convert_rate_to_bytes "$DL_RATE_LIMIT")
    TOTAL_DL_BYTES=$(( DL_BYTES * BURN_DURATION_SEC ))
    URL="https://speed.cloudflare.com/__down?bytes=$TOTAL_DL_BYTES"
    wget --limit-rate="$DL_RATE_LIMIT" -O /dev/null "$URL" -q &
    BG_PIDS="$!"

    # System Stress (CPU, RAM, IO)
    stress-ng --cpu 0 --vm 1 --vm-bytes "$BURN_IN_MEM_MAX" --hdd 2 --timeout "${BURN_DURATION_SEC}s" --metrics-brief
    
    wait $BG_PIDS 2>/dev/null
    echo "Burn-in completed."
fi

echo "Summary saved to: $REPORT_FILE"

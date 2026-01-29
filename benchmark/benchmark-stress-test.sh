#!/usr/bin/env bash

# ====== 使用者設定區 ======
# 定義網卡與 IP 對（格式為 "網卡名稱,目標IP"）
NIC_IP_PAIRS=(
  "eth0,8.8.8.8"
# "eth1,1.1.1.1"
)

# 測試目標：可以是掛載點（目錄）或原始設備（區塊設備）
# 如果為空 ()，腳本會自動偵測系統中的硬碟裝置 (/dev/sdX, /dev/nvmeX)
TEST_TARGETS=()

# 原始設備 (/dev/sdX) 的安全開關
# true  = 允許在原始設備上進行破壞性寫入測試 (警告：會抹除數據)
# false = 對原始設備僅進行讀取測試，掛載點則維持讀寫測試
ALLOW_RAW_WRITE=true

# 是否啟用燒機壓力測試 (true/false)
ENABLE_BURN_IN=true

# 燒機設定
BURN_DURATION_SEC=300       # 持續時間：300 秒 (5 分鐘)
DL_RATE_LIMIT="100m"        # 網路下載限速：100MB/s
BURN_IN_MEM_MAX="80%"       # 記憶體最大壓力：80%

# 閥值設定
LATENCY_THRESHOLD_MS=20     # 延遲警告閥值 (毫秒)
DISK_TEST_SIZE_MB=1024      # 磁碟吞吐量測試大小 (1GB)
LATENCY_TEST_COUNT=50       # 延遲測試平均次數

# 時區設定
TIMEZONE="Asia/Taipei"

# ====== 狀態旗標與資料儲存 ======
CPU_TEST_SIZE_MB=512
ALL_OK=true
declare -a NET_RESULTS
declare -a DISK_RESULTS
CPU_RESULT=""

# 獲取腳本目錄
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
REPORT_TIMESTAMP=$(TZ="$TIMEZONE" date +"%Y%m%d_%H%M%S")

# ====== 輔助函式 ======

# 獲取高精度時間
get_time() { TZ="$TIMEZONE" date +%s.%N; }

# 計算耗時
calc_duration() {
    start=$1; end=$2
    awk -v s="$start" -v e="$end" 'BEGIN {printf "%.3f", e-s}'
}

# 轉換單位為 Byte/s
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

# 檢查並安裝必要工具
check_install_tool() {
    local tool=$1
    if ! command -v "$tool" &> /dev/null; then
        echo "   -> 正在安裝 $tool..."
        if command -v apt &> /dev/null; then
            export DEBIAN_FRONTEND=noninteractive
            apt update -qq && apt install -y -qq "$tool" >/dev/null 2>&1
        elif command -v yum &> /dev/null; then
            yum install -y -q "$tool" >/dev/null 2>&1
        fi
    fi
}

# 錯誤停頓處理：如果發生錯誤，等待使用者確認才退出
handle_exit() {
    local exit_code=$?
    cleanup
    if [ "$ALL_OK" = false ]; then
        echo
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo " 測試過程中發生錯誤，請檢查上方輸出訊息。"
        echo " 請按下 [Enter] 鍵以關閉視窗..."
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        read -r
    fi
    exit $exit_code
}

cleanup() {
    if [ -n "$BG_PIDS" ]; then
        echo; echo "正在停止背景程序..."; kill $BG_PIDS 2>/dev/null
    fi
    rm -f /tmp/test_rw_*.tmp
    for target in "${TEST_TARGETS[@]}"; do
        if [ -d "$target" ]; then
            rm -f "$target"/test_rw_*.tmp "$target"/test_lat_*.tmp
        fi
    done
}

trap handle_exit EXIT INT TERM

# ====== 腳本開始 ======

echo "========================================="
echo "      硬體基準與壓力測試 (Ubuntu 24.04)   "
echo "========================================="
echo

# 自動偵測磁碟裝置
if [ ${#TEST_TARGETS[@]} -eq 0 ]; then
    echo "[偵測] 未指定測試目標，正在自動偵測實體磁碟..."
    # 使用 lsblk 尋找類型為 disk 的裝置，排除唯讀與 loop
    mapfile -t DETECTED_DISKS < <(lsblk -dpno NAME,TYPE,RO | awk '$2=="disk" && $3=="0" {print $1}')
    if [ ${#DETECTED_DISKS[@]} -gt 0 ]; then
        TEST_TARGETS=("${DETECTED_DISKS[@]}")
        echo "      偵測到設備: ${TEST_TARGETS[*]}"
    else
        echo "      錯誤: 找不到可用的磁碟裝置。"
        ALL_OK=false
        exit 1
    fi
    echo
fi

# 原始寫入安全檢查
if [ "$ALLOW_RAW_WRITE" = true ]; then
    HAS_RAW=false
    for t in "${TEST_TARGETS[@]}"; do [[ -b "$t" ]] && HAS_RAW=true; done
    
    if [ "$HAS_RAW" = true ]; then
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo " 警告: ALLOW_RAW_WRITE 已設定為 TRUE (寫入模式)"
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo " 這將會對實體磁碟進行寫入測試，硬碟上的所有資料將會被抹除。"
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo
        echo -n "請輸入大寫 'YES' 確認繼續，輸入其他任何鍵取消: "
        read -r confirm
        if [ "$confirm" != "YES" ]; then
            echo "使用者已取消測試。"
            ALL_OK=false
            exit 1
        fi
        echo "已確認。開始進行破壞性測試..."
        echo
    fi
fi

# ====== 1. 網路測試 ======
echo "[1/3] 正在執行網路延遲測試..."
for pair in "${NIC_IP_PAIRS[@]}"; do
  nic="${pair%,*}"
  ip="${pair#*,}"
  
  if ! ip link show "$nic" >/dev/null 2>&1; then
      echo "   -> 找不到介面 $nic。跳過。"
      NET_RESULTS+=("$nic -> $ip: 跳過 (找不到介面)")
      continue
  fi

  echo -n "   -> 經由 $nic Ping $ip ... "
  ping_output=$(ping -I "$nic" -c 5 "$ip" 2>&1)
  
  if [ $? -eq 0 ]; then
    avg_latency=$(echo "$ping_output" | tail -1 | awk -F '/' '{print $5}')
    avg_latency_float=$(awk -v val="$avg_latency" 'BEGIN {printf "%.2f", val}')
    if (( $(awk -v lat="$avg_latency_float" -v thresh="$LATENCY_THRESHOLD_MS" 'BEGIN {print (lat > thresh)}') )); then
      echo "失敗 (延遲 ${avg_latency}ms 過高)"
      ALL_OK=false
      NET_RESULTS+=("$nic -> $ip: 失敗 | 延遲: ${avg_latency} ms")
    else
      echo "通過 (${avg_latency} ms)"
      NET_RESULTS+=("$nic -> $ip: 成功 | 延遲: ${avg_latency} ms")
    fi
  else
    echo "失敗 (連線異常/掉封包)"
    ALL_OK=false
    NET_RESULTS+=("$nic -> $ip: 失敗 (連線超時)")
  fi
done
echo

# ====== 2. 磁碟測試 ======
echo "[2/3] 正在執行磁碟 I/O 效能測試..."

for target in "${TEST_TARGETS[@]}"; do
  echo "   -> 測試目標: $target ..."
  
  IS_DIR=false
  IS_BLOCK=false
  CAN_WRITE=false
  
  if [ -d "$target" ]; then
      IS_DIR=true; CAN_WRITE=true
      TARGET_WRITE_DST="$target/test_rw_$$.tmp"
      TARGET_READ_SRC="$target/test_rw_$$.tmp"
      LATENCY_FILE="$target/test_lat_$$.tmp"
      echo "      [類型] 目錄 (檔案層級測試)"
  elif [ -b "$target" ]; then
      IS_BLOCK=true
      CAN_WRITE=$ALLOW_RAW_WRITE
      echo "      [類型] 區塊設備 (原始裝置測試 - 寫入開關: $CAN_WRITE)"
      TARGET_WRITE_DST="$target"
      TARGET_READ_SRC="$target"
      LATENCY_FILE="$target"
  else
      echo "      錯誤: 無效的測試目標類型。"
      ALL_OK=false
      DISK_RESULTS+=("$target: 找不到或無效")
      continue
  fi

  # --- A. 吞吐量測試 ---
  speed_w="N/A"
  if [ "$CAN_WRITE" = true ]; then
      echo -n "      [速度] 寫入測試 (${DISK_TEST_SIZE_MB}MB)... "
      start_w=$(get_time)
      if ! dd if=/dev/zero of="$TARGET_WRITE_DST" bs=1M count=$DISK_TEST_SIZE_MB oflag=direct status=none 2>/dev/null; then
          echo "失敗"
          ALL_OK=false
          DISK_RESULTS+=("$target: 寫入失敗")
          continue
      fi
      end_w=$(get_time)
      dur_w=$(calc_duration "$start_w" "$end_w")
      speed_w=$(awk -v size="$DISK_TEST_SIZE_MB" -v time="$dur_w" 'BEGIN {printf "%.2f", size/time}')
      echo "完成 (${speed_w} MB/s)"
  fi
  
  speed_r="N/A"
  echo -n "      [速度] 讀取測試 (${DISK_TEST_SIZE_MB}MB)... "
  start_r=$(get_time)
  if ! dd if="$TARGET_READ_SRC" of=/dev/null bs=1M count=$DISK_TEST_SIZE_MB iflag=direct status=none 2>/dev/null; then
      echo "失敗"
      ALL_OK=false
      DISK_RESULTS+=("$target: 讀取失敗")
  else
      end_r=$(get_time)
      dur_r=$(calc_duration "$start_r" "$end_r")
      speed_r=$(awk -v size="$DISK_TEST_SIZE_MB" -v time="$dur_r" 'BEGIN {printf "%.2f", size/time}')
      echo "完成 (${speed_r} MB/s)"
  fi
  
  [[ "$IS_DIR" = true ]] && rm -f "$TARGET_WRITE_DST"

  # --- B. 平均延遲測試 ---
  LAT_TYPE="寫入"; [[ "$CAN_WRITE" = false ]] && LAT_TYPE="讀取"
  echo -n "      [延遲] 測試平均 $LAT_TYPE 延遲 ($LATENCY_TEST_COUNT 次)... "
  
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
      echo "超標 (${LATENCY_MS}ms)"
      ALL_OK=false
      DISK_RESULTS+=("$target: 寫:${speed_w} 讀:${speed_r} | 延遲: ${LATENCY_MS}ms (偏高)")
  else
      echo "通過 (${LATENCY_MS}ms)"
      DISK_RESULTS+=("$target: 寫:${speed_w} 讀:${speed_r} | 延遲: ${LATENCY_MS}ms")
  fi
done
echo

# ====== 3. CPU 基準測試 ======
echo "[3/3] 正在執行 CPU SHA256 運算測試..."
echo -n "   -> 處理 $CPU_TEST_SIZE_MB MB 數據 ... "
start_cpu=$(get_time)
if dd if=/dev/zero bs=1M count=$CPU_TEST_SIZE_MB status=none | sha256sum >/dev/null 2>&1; then
    end_cpu=$(get_time)
    dur_cpu=$(calc_duration "$start_cpu" "$end_cpu")
    echo "完成 (耗時 ${dur_cpu}s)"
    CPU_RESULT="在 ${dur_cpu}s 內處理完 ${CPU_TEST_SIZE_MB}MB"
else
    echo "失敗"
    ALL_OK=false
    CPU_RESULT="失敗"
fi
echo

# ====== 總結報告 ======
FINAL_STATUS="Failed"
[[ "$ALL_OK" = true ]] && FINAL_STATUS="Successful"
REPORT_FILENAME="${SCRIPT_DIR}/benchmark_report_${REPORT_TIMESTAMP}_${FINAL_STATUS}.txt"

{
echo "#############################################"
echo "           基準測試 總結報告                 "
echo "#############################################"
echo "測試時間: $(TZ="$TIMEZONE" date)"
echo
echo "--- [ 網路延遲 ] ---"
for res in "${NET_RESULTS[@]}"; do echo "  • $res"; done
echo
echo "--- [ 磁碟效能 ] ---"
for res in "${DISK_RESULTS[@]}"; do echo "  • $res"; done
echo
echo "--- [ CPU 效能 ] ---"
echo "  • $CPU_RESULT"
echo
if [ "$ALL_OK" = true ]; then
  echo "總體狀態: ✔ 成功 (SUCCESS)"
else
  echo "總體狀態: ✘ 失敗 (FAILED)"
fi
echo "#############################################"
} | tee "$REPORT_FILENAME"

# ====== 4. 壓力測試 (燒機) ======
if [ "$ALL_OK" = true ] && [ "$ENABLE_BURN_IN" = true ]; then
    echo
    echo "========================================="
    echo "      開始燒機壓力測試 (Burn-in)         "
    echo "========================================="
    BG_PIDS=""
    
    check_install_tool "wget"
    check_install_tool "stress-ng"
    
    # 背景網路下載測試
    if [ ${#NIC_IP_PAIRS[@]} -gt 0 ] && command -v wget &> /dev/null; then
        DL_RATE_BPS=$(convert_rate_to_bytes_per_second "$DL_RATE_LIMIT")
        DOWNLOAD_BYTES=$((DL_RATE_BPS * BURN_DURATION_SEC))
        DL_URL="https://speed.cloudflare.com/__down?bytes=$((DOWNLOAD_BYTES > 0 ? DOWNLOAD_BYTES : 1))"
        
        echo "[網路] 啟動背景下載限速測試 ($DL_RATE_LIMIT)..."
        wget --limit-rate="${DL_RATE_LIMIT}" -O /dev/null "$DL_URL" -q &
        BG_PIDS="$BG_PIDS $!"
    fi

    BURN_START_TIME=$(TZ="$TIMEZONE" date +"%Y-%m-%d %H:%M:%S")
    echo "[時間] 燒機開始: ${BURN_START_TIME}"
    echo "[時間] 預計時長: ${BURN_DURATION_SEC} 秒"
    
    echo "[系統] 啟動 CPU/RAM/IO 負載..."
    if command -v stress-ng &> /dev/null; then
        BURN_IN_DIR="/tmp/burnin_$(date +%s)"
        mkdir -p "${BURN_IN_DIR}"
        
        # stress-ng 壓力設定
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
        echo "找不到 stress-ng，改用簡易 Bash 迴圈 (僅 CPU)..."
        for i in {1..2}; do ( while :; do sha256sum /dev/zero >/dev/null 2>&1; done ) & BG_PIDS="$BG_PIDS $!"; done
        sleep "${BURN_DURATION_SEC}"
    fi
    echo "燒機測試完成。"
    echo "========================================="
    echo "完整報告已存檔至: $REPORT_FILENAME"
fi

# 腳本結束，handle_exit 將會處理是否停頓
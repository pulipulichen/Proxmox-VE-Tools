#!/usr/bin/env bash

# ==============================================================================
# Script Name: fio_auto_detect.sh
# Description: Auto-detect physical disks on Ubuntu 24.04 and run FIO stress tests.
# Author: Bash Master
# ==============================================================================

# Check for root privileges (accessing /dev/sdX usually requires root)
if [[ $EUID -ne 0 ]]; then
   echo "Please run this script with sudo."
   exit 1
fi

# Check if fio is installed
if ! command -v fio &> /dev/null; then
    echo "fio is not installed, attempting to install..."
    apt update && apt install -y fio
fi

echo "Scanning system disks..."

# 1. Identify the system disk (device mounted at /) to avoid interference or damage
ROOT_DISK=$(lsblk -no PKNAME $(findmnt -nvo SOURCE /) | head -n 1)
if [ -z "$ROOT_DISK" ]; then
    # Fallback method if findmnt fails to identify the parent device
    ROOT_DISK=$(lsblk -dpno NAME,MOUNTPOINT | grep -E ' /$' | awk '{print $1}' | sed 's/[0-9]*$//')
fi

echo "System disk detected: /dev/$ROOT_DISK (will be excluded from testing)"

# 2. Detect all physical disks (Type: disk) and exclude the system disk
# Use lsblk to get paths, filtering out loop devices and the system disk
mapfile -t DISK_LIST < <(lsblk -dpno NAME,TYPE | grep 'disk' | awk '{print $1}' | grep -v "$ROOT_DISK")

# Check if any usable disks were found
if [ ${#DISK_LIST[@]} -eq 0 ]; then
    echo "Error: No available disks found besides the system disk!"
    exit 1
fi

# 3. Construct the disk path string (Format: /dev/sda:/dev/sdb)
DISK_STRING=$(IFS=:; echo "${DISK_LIST[*]}")
DISK_COUNT=${#DISK_LIST[@]}

echo "------------------------------------------------"
echo "Detection Complete!"
echo "Number of disks found: $DISK_COUNT"
echo "Test device list: $DISK_STRING"
echo "------------------------------------------------"

# Set test parameters (modify these values as needed)
IO_DEPTH=128
NUM_JOBS=128
RUNTIME=600
OUTPUT_FILE="fiotest_$(date +%Y%m%d_%H%M%S).txt"

echo "Starting FIO test... Report will be saved to: $OUTPUT_FILE"

# 4. Execute FIO command
# Note: --filename uses the dynamically generated $DISK_STRING
fio --direct=1 \
    --rw=randrw \
    --ioengine=libaio \
    --bs=4k \
    --rwmixread=100 \
    --filename="$DISK_STRING" \
    --iodepth=$IO_DEPTH \
    --numjobs=$NUM_JOBS \
    --runtime=$RUNTIME \
    --time_based \
    --group_reporting \
    --name=fiotest \
    --output="$OUTPUT_FILE"

echo "------------------------------------------------"
echo "Test Finished!"
echo "Results have been output to $OUTPUT_FILE"
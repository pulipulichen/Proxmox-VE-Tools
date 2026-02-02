#!/bin/bash

# =================================================================
# Script Name: setup_proxmox_tools.sh
# Description: Downloads Proxmox VE benchmark tools to specific paths.
# Target OS: Ubuntu 24.04
# Author: Bash Master
# =================================================================

# Ensure the script is running with root privileges
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root (using sudo) to write to /root and /home/ubuntu/Desktop."
   exit 1
fi

# Define target directories
DESKTOP_DIR="/home/ubuntu/Desktop"
ROOT_DIR="/root"

# Create directories if they don't exist (Desktop might not exist on minimal installs)
mkdir -p "$DESKTOP_DIR"
mkdir -p "$ROOT_DIR"

# List of files for the Desktop directory
DESKTOP_FILES=(
    "https://github.com/pulipulichen/Proxmox-VE-Tools/raw/refs/heads/main/benchmark/benchmark-stress-test.sh"
    "https://github.com/pulipulichen/Proxmox-VE-Tools/raw/refs/heads/main/benchmark/burnin.sh"
    "https://github.com/pulipulichen/Proxmox-VE-Tools/raw/refs/heads/main/benchmark/fio-example.sh"
    "https://github.com/pulipulichen/Proxmox-VE-Tools/raw/refs/heads/main/benchmark/fio.sh"
)

# List of files for the Root directory
ROOT_FILES=(
    "https://github.com/pulipulichen/Proxmox-VE-Tools/raw/refs/heads/main/benchmark/cubic-update.sh"
)

echo "Starting download process..."

# Download files to Desktop
echo "----------------------------------------------------"
echo "Target Directory: $DESKTOP_DIR"
for url in "${DESKTOP_FILES[@]}"; do
    filename=$(basename "$url")
    echo "Downloading $filename..."
    # -L follows redirects, -o specifies output path (overwrites existing)
    curl -L -o "$DESKTOP_DIR/$filename" "$url"
    chmod +x "$DESKTOP_DIR/$filename"
done

# Download files to Root
echo "----------------------------------------------------"
echo "Target Directory: $ROOT_DIR"
for url in "${ROOT_FILES[@]}"; do
    filename=$(basename "$url")
    echo "Downloading $filename..."
    curl -L -o "$ROOT_DIR/$filename" "$url"
    chmod +x "$ROOT_DIR/$filename"
done

echo "----------------------------------------------------"
echo "All downloads completed successfully."
echo "Scripts have been marked as executable."
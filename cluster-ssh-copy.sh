#!/usr/bin/env bash

# 輸入兩個參數

# 第一個參數是指定 host.txt ，內容列出每個主機，每行一個

# 第二個參數是檔案的路徑。 例如 /etc/multipath.conf
# 要複製到 host.txt 裡面列出的每個主機，對應到指定的路徑

# Check if the correct number of arguments is provided
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <host_list_file> <source_file_path>"
  echo "  <host_list_file>: Path to the file containing a list of hostnames (one per line)."
  echo "  <source_file_path>: Path to the file to be copied (e.g., /etc/multipath.conf)."
  exit 1
fi

HOST_LIST_FILE="$1"
SOURCE_FILE_PATH="$2"
DESTINATION_PATH=$(dirname "$SOURCE_FILE_PATH") # Extract directory from source path

# Check if the host list file exists
if [ ! -f "$HOST_LIST_FILE" ]; then
  echo "Error: Host list file '$HOST_LIST_FILE' not found."
  exit 1
fi

# Check if the source file exists
if [ ! -f "$SOURCE_FILE_PATH" ]; then
  echo "Error: Source file '$SOURCE_FILE_PATH' not found."
  exit 1
fi

echo "Copying '$SOURCE_FILE_PATH' to hosts listed in '$HOST_LIST_FILE' at '$DESTINATION_PATH'..."

while IFS= read -r host; do
  if [ -n "$host" ]; then # Ensure host is not empty
    echo "  -> Copying to $host..."
    # Use ssh to create the directory on the remote host if it doesn't exist
    ssh "$host" "sudo mkdir -p $DESTINATION_PATH"
    # Use scp to copy the file to the remote host
    # -p preserves modification times, access times, and modes
    # -q suppresses the progress meter
    if scp -p "$SOURCE_FILE_PATH" "$host:$DESTINATION_PATH"; then
      echo "     Successfully copied to $host."
    else
      echo "     Error: Failed to copy to $host."
    fi
  fi
done < "$HOST_LIST_FILE"

echo "Copying process completed."

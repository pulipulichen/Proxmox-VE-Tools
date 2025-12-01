#!/usr/bin/env bash

# 輸入兩個參數

# 第一個參數是指定 host.txt ，內容列出每個主機，每行一個

# 第二個參數是包含要執行指令的檔案路徑。
# 裡面列出的每個指令會依序在 host.txt 裡面列出的每個主機執行

# Check if the correct number of arguments is provided
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <host_list_file> <commands_file_path>"
  echo "  <host_list_file>: Path to the file containing a list of hostnames (one per line)."
  echo "  <commands_file_path>: Path to the file containing commands to be executed on each host."
  exit 1
fi

HOST_LIST_FILE="$1"
COMMANDS_FILE_PATH="$2"

# Check if the host list file exists
if [ ! -f "$HOST_LIST_FILE" ]; then
  echo "Error: Host list file '$HOST_LIST_FILE' not found."
  exit 1
fi

# Check if the commands file exists
if [ ! -f "$COMMANDS_FILE_PATH" ]; then
  echo "Error: Commands file '$COMMANDS_FILE_PATH' not found."
  exit 1
fi

echo "Executing commands from '$COMMANDS_FILE_PATH' on hosts listed in '$HOST_LIST_FILE'..."

while IFS= read -r host; do
  if [ -n "$host" ]; then # Ensure host is not empty
    echo "  -> Executing on $host..."
    # Use ssh to execute commands from the file on the remote host
    if ssh "$host" "bash -s" < "$COMMANDS_FILE_PATH"; then
      echo "     Successfully executed on $host."
    else
      echo "     Error: Failed to execute on $host."
    fi
  fi
done < "$HOST_LIST_FILE"

echo "Execution process completed."

#!/usr/bin/env bash

# 檢查參數
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <vmid_list_file> <action_or_setting>"
    echo "Example: $0 vms.txt 'start'"
    echo "Example: $0 vms.txt 'set --cpu host --cores 4'"
    exit 1
fi

VMID_LIST_FILE="$1"
ACTION_STRING="$2"

# 檢查檔案是否存在
if [ ! -f "$VMID_LIST_FILE" ]; then
    echo "Error: VMID list file '$VMID_LIST_FILE' not found."
    exit 1
fi

# 預先獲取叢集資源列表，避免每次循環都查詢 API (提升效能)
echo "Fetching cluster resources..."
CLUSTER_RESOURCES=$(pvesh get /cluster/resources --type vm --output-format json)

# 讀取 VMID 列表
while IFS= read -r VMID; do
    # 跳過空行和註釋
    if [[ -z "$VMID" || "$VMID" =~ ^# ]]; then
        continue
    fi

    # 1. 查找 VM 所在的節點 (Node)
    # 使用 python 來解析 JSON 是因為大多數 PVE 預裝了 python3 但不一定有 jq
    # 這裡從 CLUSTER_RESOURCES 中篩選出對應 VMID 的 node 欄位
    NODE=$(echo "$CLUSTER_RESOURCES" | python3 -c "import sys, json; 
data = json.load(sys.stdin); 
match = next((item for item in data if item['vmid'] == $VMID), None); 
print(match['node']) if match else print('')")

    if [ -z "$NODE" ]; then
        echo "Error: VMID $VMID not found in cluster resources. Skipping."
        continue
    fi

    echo "Processing VMID: $VMID on Node: $NODE -> Action: $ACTION_STRING"

    # 2. 根據操作類型構建 pvesh 命令
    # pvesh 的語法是: pvesh <HTTP_METHOD> <API_PATH> [OPTIONS]
    
    case "$ACTION_STRING" in
        "set "*)
            # 配置修改 (Config)
            # API 路徑: /nodes/{node}/qemu/{vmid}/config
            # 方法: set (對應 HTTP PUT)
            # 去掉 "set " 前綴，保留參數
            ARGS="${ACTION_STRING#set }"
            
            # 這裡不加引號 $ARGS 以允許參數展開
            pvesh set "/nodes/$NODE/qemu/$VMID/config" $ARGS
            ;;
            
        "start"|"stop"|"reset"|"shutdown"|"suspend"|"resume")
            # 電源管理 (Status)
            # API 路徑: /nodes/{node}/qemu/{vmid}/status/{command}
            # 方法: create (對應 HTTP POST)
            pvesh create "/nodes/$NODE/qemu/$VMID/status/$ACTION_STRING"
            ;;
            
        "migrate "*)
            # 遷移 (Migrate)
            # API 路徑: /nodes/{node}/qemu/{vmid}/migrate
            # 語法通常是: migrate <target_node>
            TARGET_NODE="${ACTION_STRING#migrate }"
            pvesh create "/nodes/$NODE/qemu/$VMID/migrate" --target "$TARGET_NODE"
            ;;

        *)
            echo "Warning: Unrecognized simple action '$ACTION_STRING'. trying raw mapping."
            echo "Please ensure this maps to a valid API endpoint."
            # 嘗試作為直接命令 (風險較高，建議擴充 case)
            pvesh create "/nodes/$NODE/qemu/$VMID/$ACTION_STRING"
            ;;
    esac

    if [ $? -eq 0 ]; then
        echo "Success: $VMID"
    else
        echo "Failed: $VMID"
    fi

done < "$VMID_LIST_FILE"

echo "Batch operation completed."
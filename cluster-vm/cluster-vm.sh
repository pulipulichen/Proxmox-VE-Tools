#!/usr/bin/env bash

# 檢查參數
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <vmid_list_file> <action_or_setting>"
    echo "Example: $0 vms.txt 'start'"
    echo "Example: $0 vms.txt 'set --cpu host --cores 4' (For VMs)"
    echo "Example: $0 vms.txt 'set --cores 2' (For CTs)"
    exit 1
fi

VMID_LIST_FILE="$1"
ACTION_STRING="$2"

# 檢查檔案是否存在
if [ ! -f "$VMID_LIST_FILE" ]; then
    echo "Error: VMID list file '$VMID_LIST_FILE' not found."
    exit 1
fi

# 預先獲取叢集資源列表
# 移除 --type vm 以獲取所有資源 (包含 qemu 和 lxc)
echo "Fetching cluster resources..."
CLUSTER_RESOURCES=$(pvesh get /cluster/resources --output-format json)

# 讀取 VMID 列表
while IFS= read -r VMID; do
    # 跳過空行和註釋
    if [[ -z "$VMID" || "$VMID" =~ ^# ]]; then
        continue
    fi

    # 1. 查找 ID 所在的節點 (Node) 與 類型 (Type)
    # 使用 Python 解析 JSON，同時回傳 node 和 type (例如: "pve1 qemu" 或 "pve2 lxc")
    RESOURCE_INFO=$(echo "$CLUSTER_RESOURCES" | python3 -c "import sys, json; 
data = json.load(sys.stdin); 
# 查找 vmid 匹配的項目 (注意 vmid 在 json 中通常是數字，這裡做寬鬆比對)
match = next((item for item in data if str(item.get('vmid')) == '$VMID'), None); 
if match: print(f\"{match['node']} {match['type']}\")")

    if [ -z "$RESOURCE_INFO" ]; then
        echo "Error: ID $VMID not found in cluster resources. Skipping."
        continue
    fi

    # 讀取節點和類型
    read -r NODE TYPE <<< "$RESOURCE_INFO"

    # 驗證類型是否支援
    if [[ "$TYPE" != "qemu" && "$TYPE" != "lxc" ]]; then
        echo "Warning: ID $VMID has type '$TYPE' which is not supported by this script (only qemu or lxc). Skipping."
        continue
    fi

    echo "Processing $TYPE ID: $VMID on Node: $NODE -> Action: $ACTION_STRING"

    # 2. 根據操作類型構建 pvesh 命令
    # 路徑結構: /nodes/{node}/{type}/{vmid}/...
    # TYPE 變數會是 'qemu' 或 'lxc'，剛好對應 API 路徑
    
    case "$ACTION_STRING" in
        "set "*)
            # 配置修改 (Config)
            # API 路徑: /nodes/{node}/{qemu|lxc}/{vmid}/config
            ARGS="${ACTION_STRING#set }"
            pvesh set "/nodes/$NODE/$TYPE/$VMID/config" $ARGS
            ;;
            
        "start"|"stop"|"reset"|"shutdown"|"suspend"|"resume")
            # 電源管理 (Status)
            # CT 不支援 suspend/reset (視具體版本而定，但通常只支援 start/stop/shutdown/reboot)
            # 不過 API 路徑通常是一致的，如果不支援 API 會回傳錯誤
            pvesh create "/nodes/$NODE/$TYPE/$VMID/status/$ACTION_STRING"
            ;;
            
        "reboot")
            # CT 的重啟通常用 reboot (對應 shutdown + start)
            # VM 通常也支援，但有時會用 reset
            pvesh create "/nodes/$NODE/$TYPE/$VMID/status/reboot"
            ;;

        "migrate "*)
            # 遷移 (Migrate)
            TARGET_NODE="${ACTION_STRING#migrate }"
            pvesh create "/nodes/$NODE/$TYPE/$VMID/migrate" --target "$TARGET_NODE"
            ;;

        *)
            echo "Warning: Unrecognized simple action '$ACTION_STRING'. trying raw mapping."
            # 嘗試作為直接命令
            pvesh create "/nodes/$NODE/$TYPE/$VMID/$ACTION_STRING"
            ;;
    esac

    if [ $? -eq 0 ]; then
        echo "Success: $VMID"
    else
        echo "Failed: $VMID"
    fi

done < "$VMID_LIST_FILE"

echo "Batch operation completed."